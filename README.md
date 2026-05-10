# SynoWatch

A lightweight macOS menu bar app that monitors a Synology NAS for available DSM firmware and package updates.

## Features

- Periodically polls the Synology DSM 7 API for firmware and package updates
- Menu bar icon changes appearance based on the current state
- Supports local network access (HTTP or HTTPS)
- Supports two-factor authentication (2FA/OTP) via trusted device registration
- Credentials stored securely in the macOS Keychain
- No background services, no Dock icon, no installer

## Requirements

- macOS 13 (Ventura) or later
- Synology NAS running DSM 7.x
- Swift 5.9 or later (for building from source)

## Installation

### Build and install as a macOS app

```bash
git clone <repository-url>
cd synoWatch
make install
```

This compiles the binary in release mode, assembles `SynoWatch.app`, and copies it to `~/Applications/`. Double-clicking the app in Finder starts it directly as a menu bar app — no Terminal window appears.

**First launch:** macOS may show a Gatekeeper warning because the app is not signed. Choose **Right-click → Open → Open** to proceed. You will only need to do this once.

**To add SynoWatch to Login Items** so it starts automatically:
> System Settings → General → Login Items → add `SynoWatch.app`

### Available make targets

| Target | Description |
|---|---|
| `make` / `make app` | Build `SynoWatch.app` in the project directory |
| `make install` | Build and copy to `~/Applications/` |
| `make clean` | Remove the build output and app bundle |

### Run without installing (development)

```bash
swift run
```

This opens a Terminal window alongside the app and is intended for development only.

## Configuration

On first launch, the Settings popover opens automatically. All settings are accessible at any time via right-click → **Settings…**.

| Field | Description | Default |
|---|---|---|
| Host / IP | IP address or hostname of the Synology NAS | — |
| Port | DSM web port | 5000 (HTTP) / 5001 (HTTPS) |
| HTTPS | Enable encrypted connection | off |
| Username | DSM account with access to system info | — |
| Password | Stored in macOS Keychain, not in plain text | — |
| Check interval | How often SynoWatch polls for updates | Every hour |

The port switches automatically between 5000 and 5001 when toggling HTTPS, as long as you have not changed it manually.

### Required DSM permissions

The configured user account needs no special permissions beyond basic login access. SynoWatch only reads system update status and the package list — it does not install, modify, or delete anything.

For a minimal setup, create a dedicated DSM user in a group without access to any shared folders or applications.

## Two-factor authentication (2FA)

If the DSM account has 2FA enabled, SynoWatch needs to register itself as a trusted device. This is a one-time step.

**Setup:**

1. Open Settings (right-click the menu bar icon → **Settings…**)
2. Fill in Host, Port, Username, and Password
3. Open your authenticator app and copy the current 6-digit code
4. Enter the code in the **Two-Factor Authentication** section
5. Click **Register Device**

SynoWatch will log in with the OTP code and store the returned device token in the Keychain. Subsequent background checks use this token instead of the OTP, so no manual interaction is required.

**If the registration expires or is revoked** (e.g. after resetting trusted devices in DSM), the menu bar icon changes to a yellow lock. Open Settings and repeat the registration with a fresh OTP code.

**To clear the registration** without re-registering, click **Clear Registration** in the Settings popover. The next check will attempt login without a device token.

## Menu bar icon states

| Icon | Color | Meaning |
|---|---|---|
| Gear | Default | Not configured — open Settings |
| Refresh arrow | Default | Actively checking for updates |
| Checkmark circle | Default | Up to date |
| Arrow down circle | Orange | Updates available — click for details |
| Lock with warning | Yellow | 2FA registration required |
| Exclamation triangle | Red | Check failed — click for details |

Left-click opens a popover with details (what is available, when the last check ran).
Right-click opens a context menu with **Check Now**, **Settings…**, and **Quit SynoWatch**.

## How it works

SynoWatch uses the Synology DSM 7 REST API (`/webapi/`):

1. **Login** — `SYNO.API.Auth` version 6, returns a session ID (`sid`)
2. **Firmware check** — `SYNO.Core.System.Update` version 1, method `check`
3. **Package check** — `SYNO.Core.Package` version 2, method `list`
4. **Logout** — session is always terminated after each check

Firmware and package checks run concurrently. The session is short-lived and closed immediately after the check completes.

### Trusted device flow (2FA)

When registering a trusted device, the login request includes the OTP code plus `device_name=SynoWatch` and `enable_device_token=yes`. DSM returns a device token (`did`) which is stored in the Keychain under the service name `SynoWatch-DeviceID`. This token is included in every subsequent login request.

If DSM rejects the stored token (error code 403/404/406), SynoWatch clears the stale token and transitions to the `.otpRequired` state.

## Data storage

| Data | Storage location |
|---|---|
| Host, port, username, check interval | `UserDefaults` (`SynoWatchConfig`) |
| Password | macOS Keychain (service: `SynoWatch`) |
| Device token (2FA) | macOS Keychain (service: `SynoWatch-DeviceID`) |

No data is sent to any third party. All communication is directly between SynoWatch and the configured Synology host.

## Project structure

```
synoWatch/
├── Makefile                   Build and install targets
├── Package.swift              Swift Package Manager manifest
└── Sources/SynoWatch/
    ├── main.swift             Entry point
    ├── AppDelegate.swift      Menu bar item, state machine, timer
    ├── Config.swift           Configuration model, UserDefaults persistence
    ├── KeychainHelper.swift   Keychain read/write wrapper
    ├── SynologyClient.swift   DSM 7 API client
    ├── IconRenderer.swift     Programmatic NAS icon with status badge
    ├── InfoView.swift         SwiftUI popover — update status details
    └── SettingsView.swift     SwiftUI popover — settings and 2FA registration
```

## Known limitations

- **HTTP on local network**: The app bundle's `Info.plist` includes `NSAllowsLocalNetworking = true`, so plain HTTP connections to a local Synology host work out of the box. Running the raw binary via `swift run` also works because App Transport Security is only enforced for signed app bundles.
- **Self-signed certificates**: HTTPS connections to a Synology NAS using a self-signed certificate will fail because URLSession validates the certificate chain by default. Use a trusted certificate (e.g. via DSM's built-in Let's Encrypt integration) or connect over HTTP on the local network.
- **Package update detection**: The package update check reads the `status` field from `SYNO.Core.Package`. DSM sets this to `upgradable` for packages with available updates. The exact field name may vary between DSM minor versions.

## License

See [LICENSE](LICENSE).
