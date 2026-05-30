import Foundation

/// A single point-in-time snapshot of NAS system health metrics.
struct SystemSnapshot {
    let timestamp: Date
    /// CPU user load as a percentage (0–100).
    let cpuUsage: Double
    /// RAM currently in use, in bytes.
    let memoryUsed: Int
    /// Total installed RAM, in bytes.
    let memoryTotal: Int
    let volumes: [VolumeInfo]
    let fans: [FanInfo]
    let disks: [DiskInfo]
    /// System board temperature in degrees Celsius, if reported by DSM.
    let systemTemp: Int?
    /// True if DSM has raised a temperature warning.
    let tempWarning: Bool
}

/// Disk volume usage information.
struct VolumeInfo {
    let name: String
    /// Bytes used.
    let used: Int64
    /// Total bytes.
    let total: Int64
}

/// Fan sensor reading.
struct FanInfo {
    let id: String
    /// DSM status string, e.g. "normal" or "failed".
    let status: String
    /// Rotational speed in RPM, if reported by DSM.
    let rpm: Int?
}

/// Physical disk health status.
struct DiskInfo {
    let id: String
    let name: String
    let status: String

    /// True only when DSM reports the disk as fully healthy.
    var isHealthy: Bool {
        let s = status.lowercased()
        return s == "normal" || s == "" || s == "not_installed"
    }
}

/// Observable store that AppDelegate populates and SystemMonitorView reads.
final class SystemMonitorStore: ObservableObject {
    /// Up to 100 most recent snapshots, newest last.
    @Published var snapshots: [SystemSnapshot] = []
    @Published var isLoading: Bool = false
}
