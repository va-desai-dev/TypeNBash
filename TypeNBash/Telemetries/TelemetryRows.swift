//
//  ContentView.swift
//  SysCOM
//
//  Created by Vedant A. Desai on 9/7/26.
//
import SwiftUI
import Charts

enum TelemetryGeometry {
    static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    static func segmentWidth(value: Double, total: Double, availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0,
              total.isFinite, total > 0 else { return 0 }
        return availableWidth * CGFloat(min(nonnegative(value) / total, 1))
    }
}

struct TelemetryInspector: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var showProcesses: Bool = false

    var body: some View {
        LazyVStack(spacing: 12) {
            HStack {
                Button(action: {
                    showProcesses.toggle()
                }, label: {
                    if showProcesses {
                        Text("SHOW PROCESSES")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                    } else {
                        Text("SHOW TELEMETRY")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                    }
                })
            }
            Divider()
            // Visual Metrics using crisp geometry tracking
            VStack(spacing: 12) {
                if showProcesses {
                    CPUMonitorView(monitor: monitor)
                    GPUMonitorView(monitor: monitor)
                    RAMBreakdownView(monitor: monitor)
                    StorageMonitorView(monitor: monitor)
                    NetworkMonitorView(monitor: monitor)
                } else {
                    TopProcessesView(monitor: monitor)
                }
            }
        }
    }
}
struct TopProcessesView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("TOP PROCESSES", systemImage: "list.bullet.rectangle.fill")
                .font(.subheadline)
                .bold()
            LazyVStack(spacing: 4) {
                ForEach(monitor.topProcesses) { process in
                    HStack {
                        Text(process.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formattedFootprint(process.footprintMB))
                            .font(.caption.monospacedDigit())
                            .bold()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedFootprint(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

struct NetworkMonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("NETWORK", systemImage: monitor.isConnected ? "network" : "network.slash")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(monitor.isConnected ? .green : .red)
            }
            HStack(alignment: .center) {
                NetworkSpeedPill(
                    symbolName: "arrow.down",
                    value: monitor.downloadSpeedString,
                    color: .blue
                )
                Spacer()
                NetworkSpeedPill(
                    symbolName: "arrow.up",
                    value: monitor.uploadSpeedString,
                    color: .orange
                )
            }
        }
    }

    private var statusText: String {
        guard monitor.isConnected else { return "OFFLINE" }
        return monitor.isWifi ? "WI-FI" : "ONLINE"
    }
}

struct NetworkSpeedPill: View {
    let symbolName: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

struct StorageMonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    private var usedPercentageText: String {
        String(format: "%.0f%%", monitor.storageUsedPercentage * 100)
    }

    private var tintColor: Color {
        switch monitor.storageUsedPercentage {
        case ..<0.75:
            return .green
        case ..<0.9:
            return .yellow
        default:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("STORAGE", systemImage: "internaldrive.fill")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text("\(monitor.storageFreeString) FREE")
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(tintColor)
            }

            ProgressView(value: monitor.storageUsedPercentage)
                .tint(tintColor)
        }
    }

    private var formattedTotalStorage: String {
        if monitor.storageTotalGB >= 1024 {
            return String(format: "%.1f TB", monitor.storageTotalGB / 1024)
        }

        return String(format: "%.0f GB", monitor.storageTotalGB)
    }
}



struct CPUMonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    func cpuColor(for percentage: Int) -> Color {
        let percentage = monitor.cpuUsage
        if percentage < 30 {
            return .green
        } else if percentage < 70 {
            return .yellow
        } else {
            return .red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("PROCESSOR", systemImage: "cpu")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(String(format: "%.1f%%", monitor.history.first?.usage ?? 0.0))
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(cpuColor(for: monitor.cpuUsage))
            }
            Chart(monitor.history) { sample in
                AreaMark(
                    x: .value("Seconds Ago", -sample.secondsAgo),
                    y: .value("CPU Load", sample.usage)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Seconds Ago", -sample.secondsAgo),
                    y: .value("CPU Load", sample.usage)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(.blue)
            }
            .frame(maxHeight: .infinity)
            .chartXAxis {
                AxisMarks(values: [-9, -6, -3, 0]) { value in
                    AxisGridLine()
                    if let seconds = value.as(Int.self) {
                        AxisValueLabel("\(abs(seconds))s ago")
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .animation(.linear(duration: 0.2), value: monitor.history.map { $0.id })
        }
    }
}



struct RAMBreakdownView: View {
    @ObservedObject var monitor: SystemMonitor

    private func freeMemory(monitor: SystemMonitor) -> Double {
        let total = monitor.totalMemoryGB
        let used = monitor.ramUsage
        return TelemetryGeometry.nonnegative(total - used)
    }

    /// Segment colors keyed by platform-neutral role, so both the macOS and Linux
    /// breakdowns stay visually consistent without the view knowing the taxonomy.
    private func color(for role: MemoryRole) -> Color {
        switch role {
        case .app, .used: return .blue
        case .wired: return .purple
        case .compressed: return .orange
        case .cached, .buffers: return .green
            case .free: return .gray
        }
    }

    var segments: [MemorySegment] { monitor.memorySegments }

    var total: Double { segments.reduce(0) { $0 + TelemetryGeometry.nonnegative($1.value) } }

    var body: some View {
        let freeMemoryGBRounded = Int(exactly: freeMemory(monitor: monitor).rounded()) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("MEMORY", systemImage: "memorychip.fill")
                    .font(.subheadline)
                    .bold()
                Spacer()
                if freeMemoryGBRounded > 10 {
                    Text("\(freeMemoryGBRounded) GB FREE")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.green)
                }
                else if freeMemoryGBRounded > 5 {
                    Text("\(freeMemoryGBRounded) GB FREE")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.orange)
                }
                else {
                    Text("\(freeMemoryGBRounded) GB FREE")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.red)
                }
            }

            // The Consolidated Bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(color(for: segment.role))
                            .frame(width: TelemetryGeometry.segmentWidth(
                                value: segment.value, total: total, availableWidth: geo.size.width
                            ))
                            .frame(height: 8)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
            }

            Grid(alignment: .leading) {
                ForEach(segments) { segment in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: segment.role)).frame(width: 8, height: 8)
                            Text(segment.name).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f GB", segment.value))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct GPUMonitorView: View {
    @ObservedObject var monitor: SystemMonitor

    func gpuUsageColor(for percentage: Double) -> Color {
        if percentage < 20 {
            return .green
        } else if percentage < 40 {
            return .yellow
        } else {
            return .red
        }
    }

    private func vramColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }

    private func vramText(usedMB: Double, totalMB: Double) -> String {
        func format(_ mb: Double) -> String {
            mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
        }
        return "\(format(usedMB)) / \(format(totalMB))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("CORE GRAPHICS", systemImage: "display")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text("\(monitor.gpuDevices.count)")
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.secondary)
            }

            if monitor.gpuDevices.isEmpty {
                Text("No GPU devices reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.gpuDevices) { gpu in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(gpu.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", gpu.usagePercentage))
                                .font(.caption.monospacedDigit())
                                .bold()
                                .foregroundStyle(gpuUsageColor(for: gpu.usagePercentage))
                        }

                        ProgressView(value: gpu.usagePercentage, total: 100)
                            .tint(gpuUsageColor(for: gpu.usagePercentage))

                        // Discrete GPUs report VRAM — the figure that actually
                        // matters on a remote box. Unified-memory Macs report nil.
                        if let usedMB = gpu.vramUsedMB,
                           let totalMB = gpu.vramTotalMB,
                           let fraction = gpu.vramUsedFraction,
                           totalMB > 0 {
                            HStack(spacing: 8) {
                                Text("VRAM")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(vramText(usedMB: usedMB, totalMB: totalMB))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: fraction)
                                .tint(vramColor(for: fraction))
                        }
                    }
                }
            }
        }
    }
}
