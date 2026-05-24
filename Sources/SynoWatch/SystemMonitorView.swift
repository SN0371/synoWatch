import Charts
import SwiftUI

// MARK: - Chart data models

private struct CPUSample: Identifiable {
    let id: Int
    let pct: Double
}

private struct MemSample: Identifiable {
    let id: Int
    let pct: Double
}

private struct FanSample: Identifiable {
    let id: Int
    let fanId: String
    let rpm: Double
}

// MARK: - Main view

/// Window content showing live NAS system health data as trend charts.
struct SystemMonitorView: View {
    @ObservedObject var store: SystemMonitorStore

    private var latest: SystemSnapshot? { store.snapshots.last }

    private var cpuSamples: [CPUSample] {
        store.snapshots.enumerated().map { CPUSample(id: $0.offset, pct: $0.element.cpuUsage) }
    }

    private var memSamples: [MemSample] {
        store.snapshots.enumerated().map { i, snap in
            let pct = snap.memoryTotal > 0
                ? Double(snap.memoryUsed) / Double(snap.memoryTotal) * 100
                : 0.0
            return MemSample(id: i, pct: pct)
        }
    }

    private var fanSamples: [FanSample] {
        store.snapshots.enumerated().flatMap { i, snap in
            snap.fans.compactMap { fan in
                guard let rpm = fan.rpm else { return nil }
                return FanSample(id: i, fanId: fan.id, rpm: Double(rpm))
            }
        }
    }

    private var hasRPMData: Bool {
        store.snapshots.first?.fans.contains(where: { $0.rpm != nil }) == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if store.snapshots.isEmpty && store.isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if store.snapshots.isEmpty {
                    Text("No data available.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    cpuSection
                    memorySection
                    if let snap = latest, !snap.volumes.isEmpty {
                        volumeSection
                    }
                    if let snap = latest, !snap.fans.isEmpty || snap.systemTemp != nil {
                        fanSection(snap)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("System Monitor")
                .font(.headline)
            Spacer()
            if let ts = latest?.timestamp {
                Text("Updated \(ts.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - CPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                if let pct = latest?.cpuUsage {
                    Text(String(format: "%.0f%%", pct))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Chart(cpuSamples) {
                AreaMark(x: .value("", $0.id), y: .value("", $0.pct))
                    .opacity(0.15)
                LineMark(x: .value("", $0.id), y: .value("", $0.pct))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 70)
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Memory", systemImage: "memorychip")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                if let snap = latest, snap.memoryTotal > 0 {
                    let usedGB = Double(snap.memoryUsed) / 1_073_741_824
                    let totalGB = Double(snap.memoryTotal) / 1_073_741_824
                    let pct = Double(snap.memoryUsed) / Double(snap.memoryTotal) * 100
                    Text(String(format: "%.1f / %.1f GB (%.0f%%)", usedGB, totalGB, pct))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Chart(memSamples) {
                AreaMark(x: .value("", $0.id), y: .value("", $0.pct))
                    .opacity(0.15)
                LineMark(x: .value("", $0.id), y: .value("", $0.pct))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 70)
        }
    }

    // MARK: - Storage

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Storage", systemImage: "externaldrive")
                .font(.subheadline).fontWeight(.semibold)
            if let snap = latest {
                ForEach(snap.volumes, id: \.name) { vol in
                    VolumeRow(volume: vol)
                }
            }
        }
    }

    // MARK: - Fans & Temperature

    @ViewBuilder
    private func fanSection(_ snap: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fans & Temperature", systemImage: "thermometer.medium")
                .font(.subheadline).fontWeight(.semibold)

            if let temp = snap.systemTemp {
                HStack {
                    Text("System temperature")
                        .font(.caption)
                    Spacer()
                    Text("\(temp) °C")
                        .font(.caption)
                        .foregroundColor(snap.tempWarning ? .red : .secondary)
                }
            }

            if !snap.fans.isEmpty {
                if hasRPMData {
                    Chart(fanSamples) {
                        LineMark(x: .value("", $0.id), y: .value("", $0.rpm))
                            .foregroundStyle(by: .value("Fan", $0.fanId))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 70)
                } else {
                    ForEach(snap.fans, id: \.id) { fan in
                        HStack {
                            Text(fan.id)
                                .font(.caption)
                            Spacer()
                            Text(fan.status)
                                .font(.caption)
                                .foregroundColor(fan.status == "normal" ? .green : .red)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Volume row

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        let usedGB = Double(volume.used) / 1_073_741_824
        let totalGB = Double(volume.total) / 1_073_741_824
        let fraction = volume.total > 0
            ? Double(volume.used) / Double(volume.total)
            : 0.0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(volume.name)
                    .font(.caption).fontWeight(.medium)
                Spacer()
                Text(String(format: "%.1f / %.1f GB (%.0f%%)", usedGB, totalGB, fraction * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ProgressView(value: fraction)
        }
    }
}
