import SwiftUI

/// Popover content for configuring the Synology host, credentials, and check interval.
struct SettingsView: View {
    let onSave: () -> Void

    @State private var host: String = ""
    @State private var port: String = "\(Config.defaultHTTPPort)"
    @State private var useHTTPS: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var intervalIndex: Int = 2

    @State private var otpCode: String = ""
    @State private var isRegistering: Bool = false
    @State private var registrationMessage: RegistrationMessage? = nil
    @State private var isDeviceRegistered: Bool = false

    private let intervals: [(label: String, seconds: TimeInterval)] = [
        ("Every 15 minutes", 900),
        ("Every 30 minutes", 1800),
        ("Every hour",       3600),
        ("Every 2 hours",    7200),
        ("Every 6 hours",    21600),
        ("Every 12 hours",   43200),
        ("Every 24 hours",   86400),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SynoWatch Settings")
                .font(.headline)

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Host / IP")
                        .gridColumnAlignment(.trailing)
                    TextField("192.168.1.100", text: $host)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Port")
                        .gridColumnAlignment(.trailing)
                    HStack {
                        TextField("5000", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Toggle("HTTPS", isOn: $useHTTPS)
                            .onChange(of: useHTTPS) { newValue in
                                autoSwitchPort(https: newValue)
                            }
                        Spacer()
                    }
                }

                GridRow {
                    Text("Username")
                        .gridColumnAlignment(.trailing)
                    TextField("admin", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Password")
                        .gridColumnAlignment(.trailing)
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Check interval")
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $intervalIndex) {
                        ForEach(intervals.indices, id: \.self) { i in
                            Text(intervals[i].label).tag(i)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            mfaSection

            Divider()

            HStack {
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: loadExisting)
    }

    // MARK: - MFA section

    private var mfaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Two-Factor Authentication")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                deviceStatusBadge
            }

            if isDeviceRegistered {
                Text("This device is registered as a trusted device. No OTP code is required for background checks.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Clear Registration", role: .destructive) {
                    clearDeviceRegistration()
                }
                .font(.caption)
            } else {
                Text("If your account has 2FA enabled, enter your current authenticator code and register this device. This is a one-time step.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField("000000", text: $otpCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()

                    Button(action: registerDevice) {
                        if isRegistering {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Register Device")
                        }
                    }
                    .disabled(!canRegister)

                    Spacer()
                }

                if let msg = registrationMessage {
                    Label(msg.text, systemImage: msg.isError ? "xmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(msg.isError ? .red : .green)
                }
            }
        }
    }

    private var deviceStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isDeviceRegistered ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(isDeviceRegistered ? "Registered" : "Not registered")
                .font(.caption)
                .foregroundColor(isDeviceRegistered ? .green : .secondary)
        }
    }

    // MARK: - Logic

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && Int(port) != nil
    }

    private var canRegister: Bool {
        !isRegistering
            && otpCode.count >= 6
            && isValid
    }

    private func loadExisting() {
        guard let config = Config.load() else { return }
        host = config.host
        port = "\(config.port)"
        useHTTPS = config.useHTTPS
        username = config.username
        password = KeychainHelper.load(service: "SynoWatch", account: config.username) ?? ""
        intervalIndex = intervals.firstIndex(where: { $0.seconds == config.checkInterval }) ?? 2
        isDeviceRegistered = KeychainHelper.load(service: "SynoWatch-DeviceID", account: config.username) != nil
    }

    private func save() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)

        // Remove stale keychain entries when the username changes.
        if let existing = Config.load(), existing.username != trimmedUsername {
            KeychainHelper.delete(service: "SynoWatch", account: existing.username)
            KeychainHelper.delete(service: "SynoWatch-DeviceID", account: existing.username)
        }

        let config = Config(
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? (useHTTPS ? Config.defaultHTTPSPort : Config.defaultHTTPPort),
            useHTTPS: useHTTPS,
            username: trimmedUsername,
            checkInterval: intervals[intervalIndex].seconds
        )
        config.save()
        KeychainHelper.save(service: "SynoWatch", account: config.username, password: password)
        onSave()
    }

    private func registerDevice() {
        guard canRegister else { return }
        isRegistering = true
        registrationMessage = nil

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let portInt = Int(port) ?? (useHTTPS ? Config.defaultHTTPSPort : Config.defaultHTTPPort)
        let client = SynologyClient(host: trimmedHost, port: portInt, useHTTPS: useHTTPS)

        Task {
            let result = await client.registerTrustedDevice(
                username: trimmedUser,
                password: password,
                otpCode: otpCode
            )
            await MainActor.run {
                isRegistering = false
                switch result {
                case .success(let deviceId):
                    KeychainHelper.save(service: "SynoWatch-DeviceID", account: trimmedUser, password: deviceId)
                    isDeviceRegistered = true
                    otpCode = ""
                    registrationMessage = RegistrationMessage(text: "Device registered successfully.", isError: false)
                case .failure(let message):
                    registrationMessage = RegistrationMessage(text: message, isError: true)
                }
            }
        }
    }

    private func clearDeviceRegistration() {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        KeychainHelper.delete(service: "SynoWatch-DeviceID", account: trimmedUser)
        isDeviceRegistered = false
        registrationMessage = nil
    }

    /// Automatically switches to the DSM default port when toggling the HTTPS flag,
    /// but only if the current port is still the other protocol's default.
    private func autoSwitchPort(https: Bool) {
        let currentPort = Int(port)
        if https && currentPort == Config.defaultHTTPPort {
            port = "\(Config.defaultHTTPSPort)"
        } else if !https && currentPort == Config.defaultHTTPSPort {
            port = "\(Config.defaultHTTPPort)"
        }
    }
}

// MARK: - Helper types

private struct RegistrationMessage {
    let text: String
    let isError: Bool
}
