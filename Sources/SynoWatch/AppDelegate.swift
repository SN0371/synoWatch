import AppKit
import SwiftUI

// MARK: - State

enum AppState {
    case unconfigured
    case checking
    case upToDate(Date)
    case updatesAvailable(UpdateInfo)
    /// MFA is enabled on the Synology account but no trusted device is registered yet.
    /// The user must open Settings and complete the one-time OTP registration.
    case otpRequired
    case error(String)
}

struct UpdateInfo {
    let firmwareVersion: String?
    let packages: [String]
    let checkedAt: Date
}

// MARK: - AppDelegate

/// Main application delegate.
///
/// The entire class is isolated to the main actor. Network calls inside performCheck()
/// suspend the main actor during URLSession IO, so the UI stays responsive.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var checkTimer: Timer?

    @MainActor private var state: AppState = .unconfigured

    private lazy var infoPopover = makePopover()
    private lazy var settingsPopover = makePopover()

    private let monitorStore = SystemMonitorStore()
    private var systemMonitorWindow: NSWindow?
    private var backgroundMonitorTimer: Timer?
    private var windowRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusItem()

        if Config.load() != nil {
            triggerCheck()
            scheduleTimer()
            startBackgroundMonitorTimer()
        } else {
            // First launch: open settings after the run loop has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettings()
            }
        }
    }

    // MARK: - Timer

    private func scheduleTimer() {
        checkTimer?.invalidate()
        let interval = Config.load()?.checkInterval ?? Config.defaultInterval
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop thread; hop to MainActor explicitly
            // to satisfy Swift 6 concurrency isolation requirements.
            guard let self else { return }
            Task { @MainActor in self.triggerCheck() }
        }
    }

    /// Reschedules the periodic timer, e.g. after the check interval is changed in settings.
    func rescheduleTimer() {
        scheduleTimer()
    }

    // MARK: - Update check

    func triggerCheck() {
        Task { await performCheck() }
    }

    /// Fetches update information from the Synology API.
    ///
    /// This method runs on the main actor but suspends during network calls,
    /// releasing the main actor while requests are in flight.
    private func performCheck() async {
        guard let config = Config.load() else {
            state = .unconfigured
            updateStatusItem()
            return
        }
        guard let password = KeychainHelper.load(service: "SynoWatch", account: config.username) else {
            state = .unconfigured
            updateStatusItem()
            return
        }

        state = .checking
        updateStatusItem()

        // Suspend main actor here; network IO runs on the cooperative thread pool.
        let deviceId = KeychainHelper.load(service: "SynoWatch-DeviceID", account: config.username)
        let client = SynologyClient(host: config.host, port: config.port, useHTTPS: config.useHTTPS)
        let result = await client.checkForUpdates(username: config.username, password: password, deviceId: deviceId)

        // Resume on main actor to update state and UI.
        switch result {
        case .noUpdates:
            state = .upToDate(Date())
        case .updatesAvailable(let firmware, let packages):
            state = .updatesAvailable(UpdateInfo(
                firmwareVersion: firmware,
                packages: packages,
                checkedAt: Date()
            ))
        case .otpRequired:
            // Stored device_id is missing or expired; clear stale entry and prompt user.
            if let config = Config.load() {
                KeychainHelper.delete(service: "SynoWatch-DeviceID", account: config.username)
            }
            state = .otpRequired
        case .error(let message):
            state = .error(message)
        }

        updateStatusItem()
    }

    // MARK: - Status item icon

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let tooltip: String
        switch state {
        case .unconfigured:
            tooltip = "SynoWatch: Not configured — right-click for settings"
        case .checking:
            tooltip = "SynoWatch: Checking for updates…"
        case .upToDate(let date):
            let t = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            tooltip = "SynoWatch: Up to date (checked \(t))"
        case .updatesAvailable:
            tooltip = "SynoWatch: Updates available — click for details"
        case .otpRequired:
            tooltip = "SynoWatch: 2FA registration required — click for details"
        case .error:
            tooltip = "SynoWatch: Check failed — click for details"
        }

        button.image = IconRenderer.image(for: state)
        button.contentTintColor = nil
        button.toolTip = tooltip
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            toggleInfoPopover(from: sender)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let checkItem = NSMenuItem(title: "Check Now",
                                   action: #selector(triggerCheckFromMenu),
                                   keyEquivalent: "r")
        checkItem.target = self
        menu.addItem(checkItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SynoWatch",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        // Temporarily attach menu so NSStatusItem positions it correctly.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func toggleInfoPopover(from button: NSStatusBarButton) {
        if infoPopover.isShown {
            infoPopover.performClose(nil)
            return
        }
        settingsPopover.performClose(nil)

        let rootView = InfoView(
            state: state,
            onSettings: { [weak self] in
                self?.infoPopover.performClose(nil)
                self?.openSettings()
            },
            onSystemMonitor: { [weak self] in
                self?.infoPopover.performClose(nil)
                self?.openSystemMonitor()
            },
            onCheckNow: { [weak self] in
                self?.infoPopover.performClose(nil)
                self?.triggerCheck()
            }
        )
        infoPopover.contentViewController = NSHostingController(rootView: rootView)
        infoPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc func openSettings() {
        if settingsPopover.isShown {
            settingsPopover.performClose(nil)
            return
        }
        infoPopover.performClose(nil)
        guard let button = statusItem.button else { return }

        let rootView = SettingsView(onSave: { [weak self] in
            self?.settingsPopover.performClose(nil)
            self?.triggerCheck()
            self?.rescheduleTimer()
        })
        settingsPopover.contentViewController = NSHostingController(rootView: rootView)
        settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func triggerCheckFromMenu() {
        triggerCheck()
    }

    // MARK: - System monitor window

    /// Opens the system monitor window, or brings it to the front if already open.
    func openSystemMonitor() {
        if let win = systemMonitorWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Synology System Monitor"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: SystemMonitorView(store: monitorStore))
        win.center()
        win.makeKeyAndOrderFront(nil)
        systemMonitorWindow = win

        // While the window is open, refresh every 10 s instead of every 5 min.
        backgroundMonitorTimer?.invalidate()
        backgroundMonitorTimer = nil
        startWindowRefreshTimer()
        Task { await fetchSystemMonitor() }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === systemMonitorWindow else { return }
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil
        systemMonitorWindow = nil
        startBackgroundMonitorTimer()
    }

    // MARK: - Monitor timers

    private func startBackgroundMonitorTimer() {
        backgroundMonitorTimer?.invalidate()
        backgroundMonitorTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchSystemMonitor() }
        }
    }

    private func startWindowRefreshTimer() {
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchSystemMonitor() }
        }
    }

    private func fetchSystemMonitor() async {
        guard let config = Config.load(),
              let password = KeychainHelper.load(service: "SynoWatch", account: config.username) else { return }
        monitorStore.isLoading = true
        let deviceId = KeychainHelper.load(service: "SynoWatch-DeviceID", account: config.username)
        let client = SynologyClient(host: config.host, port: config.port, useHTTPS: config.useHTTPS)
        let result = await client.fetchSystemInfo(username: config.username, password: password, deviceId: deviceId)
        if case .success(let snapshot) = result {
            monitorStore.snapshots = Array((monitorStore.snapshots + [snapshot]).suffix(100))
        }
        monitorStore.isLoading = false
    }

    // MARK: - Helper

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        return p
    }
}
