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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var checkTimer: Timer?
    private var hideTimer: Timer?

    @MainActor private var state: AppState = .unconfigured

    private static let hideDelay: TimeInterval = 30

    private lazy var infoPopover = makePopover()
    private lazy var settingsPopover = makePopover()

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
            cancelHideTimer()
            statusItem.isVisible = true
            tooltip = "SynoWatch: Not configured — right-click for settings"
        case .checking:
            cancelHideTimer()
            statusItem.isVisible = true
            tooltip = "SynoWatch: Checking for updates…"
        case .upToDate(let date):
            let t = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            statusItem.isVisible = true
            tooltip = "SynoWatch: Up to date (checked \(t))"
            scheduleHideTimer()
        case .updatesAvailable:
            cancelHideTimer()
            statusItem.isVisible = true
            tooltip = "SynoWatch: Updates available — click for details"
        case .otpRequired:
            cancelHideTimer()
            statusItem.isVisible = true
            tooltip = "SynoWatch: 2FA registration required — click for details"
        case .error:
            cancelHideTimer()
            statusItem.isVisible = true
            tooltip = "SynoWatch: Check failed — click for details"
        }

        button.image = IconRenderer.image(for: state)
        button.contentTintColor = nil
        button.toolTip = tooltip
    }

    private func scheduleHideTimer() {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.hideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.statusItem.isVisible = false }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
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

    // MARK: - Helper

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        return p
    }
}
