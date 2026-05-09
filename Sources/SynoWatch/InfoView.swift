import SwiftUI

/// Popover content shown when the user left-clicks the status item.
/// Displays the current update state and quick-action buttons.
struct InfoView: View {
    let state: AppState
    let onSettings: () -> Void
    let onCheckNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerSymbol)
                .foregroundColor(headerColor)
                .font(.title2)
            Text("SynoWatch")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .unconfigured:
            Text("Not configured.")
                .foregroundColor(.secondary)
            Text("Open settings to enter your Synology host and credentials.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking for updates…")
                    .foregroundColor(.secondary)
            }

        case .upToDate(let date):
            Text("Everything is up to date.")
            Text("Last checked: \(date.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)

        case .updatesAvailable(let info):
            VStack(alignment: .leading, spacing: 6) {
                if let firmware = info.firmwareVersion {
                    Label("DSM Firmware \(firmware) available", systemImage: "cpu")
                        .font(.callout)
                }
                if !info.packages.isEmpty {
                    Label("Package updates:", systemImage: "shippingbox")
                        .font(.callout)
                    ForEach(info.packages, id: \.self) { pkg in
                        Text("• \(pkg)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 18)
                    }
                }
                Text("Checked: \(info.checkedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

        case .otpRequired:
            Text("Two-factor authentication is enabled.")
                .foregroundColor(.primary)
            Text("Open Settings and enter your authenticator code once to register this device.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .error(let message):
            Text(message)
                .foregroundColor(.red)
                .font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: onSettings)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            Spacer()
            Button("Check Now", action: onCheckNow)
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private var headerSymbol: String {
        switch state {
        case .unconfigured:      return "gearshape"
        case .checking:          return "arrow.clockwise"
        case .upToDate:          return "checkmark.circle.fill"
        case .updatesAvailable:  return "arrow.down.circle.fill"
        case .otpRequired:       return "lock.trianglebadge.exclamationmark"
        case .error:             return "exclamationmark.triangle.fill"
        }
    }

    private var headerColor: Color {
        switch state {
        case .upToDate:         return .green
        case .updatesAvailable: return .orange
        case .otpRequired:      return .yellow
        case .error:            return .red
        default:                return .secondary
        }
    }
}
