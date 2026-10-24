import Foundation

struct LinuxTelemetrySnapshot {
    var cpuUsage: Double = 0
    var totalMemoryGB: Double = 0
    var usedMemoryGB: Double = 0
    var cachedMemoryGB: Double = 0
    var freeMemoryGB: Double = 0
    var availableMemoryGB: Double = 0
    var storageTotalGB: Double = 0
    var storageUsedGB: Double = 0
    var storageFreeGB: Double = 0
    var networkReceivedBytes: UInt64 = 0
    var networkTransmittedBytes: UInt64 = 0
    var gpuUsagePercentage: Double = 0
    var gpuDevices: [TelemetryGPUDevice] = []
    var topProcesses: [TopProcess] = []
}

enum LinuxTelemetryParser {
    static func parse(_ output: String) -> LinuxTelemetrySnapshot {
        var snapshot = LinuxTelemetrySnapshot()

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let value = String(parts[1])

            switch key {
            case "cpu_percent":
                snapshot.cpuUsage = Double(value) ?? 0
            case "mem_total_kb":
                snapshot.totalMemoryGB = gigabytes(fromKilobytes: value)
            case "mem_free_kb":
                snapshot.freeMemoryGB = gigabytes(fromKilobytes: value)
            case "mem_available_kb":
                snapshot.availableMemoryGB = gigabytes(fromKilobytes: value)
            case "mem_cached_kb":
                snapshot.cachedMemoryGB = gigabytes(fromKilobytes: value)
            case "storage_total_kb":
                snapshot.storageTotalGB = gigabytes(fromKilobytes: value)
            case "storage_used_kb":
                snapshot.storageUsedGB = gigabytes(fromKilobytes: value)
            case "storage_free_kb":
                snapshot.storageFreeGB = gigabytes(fromKilobytes: value)
            case "net_rx_bytes":
                snapshot.networkReceivedBytes = UInt64(value) ?? 0
            case "net_tx_bytes":
                snapshot.networkTransmittedBytes = UInt64(value) ?? 0
            case "gpu_percent":
                snapshot.gpuUsagePercentage = Double(value) ?? 0
            case "gpu":
                if let device = parseGPU(value) {
                    snapshot.gpuDevices.append(device)
                }
            case "process":
                if let process = parseProcess(value) {
                    snapshot.topProcesses.append(process)
                }
            default:
                continue
            }
        }

        // `free(1)` definition: used = total − free − buffers/cache. This keeps the
        // three-segment bar summing to the total.
        if snapshot.usedMemoryGB == 0, snapshot.totalMemoryGB > 0 {
            snapshot.usedMemoryGB = max(
                snapshot.totalMemoryGB - snapshot.freeMemoryGB - snapshot.cachedMemoryGB,
                0
            )
        }
        if snapshot.gpuUsagePercentage == 0, !snapshot.gpuDevices.isEmpty {
            let totalUsage = snapshot.gpuDevices.reduce(0) { $0 + $1.usagePercentage }
            snapshot.gpuUsagePercentage = totalUsage / Double(snapshot.gpuDevices.count)
        }

        return snapshot
    }

    private static func gigabytes(fromKilobytes value: String) -> Double {
        (Double(value) ?? 0) / 1_048_576.0
    }

    private static func parseProcess(_ value: String) -> TopProcess? {
        let fields = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let pidValue = Int32(fields[0]),
              let rssKilobytes = Double(fields[2]) else {
            return nil
        }

        return TopProcess(
            id: pid_t(pidValue),
            name: String(fields[1]).isEmpty ? "pid \(pidValue)" : String(fields[1]),
            footprintMB: rssKilobytes / 1024.0
        )
    }

    private static func parseGPU(_ value: String) -> TelemetryGPUDevice? {
        // nvidia-smi rows carry VRAM: index|name|util|memUsedMB|memTotalMB. The
        // lspci/procfs fallbacks emit only the first three, so VRAM stays nil.
        let fields = value.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let usage = Double(fields[2]) else {
            return nil
        }
        let rawID = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)

        var vramUsedMB: Double?
        var vramTotalMB: Double?
        if fields.count >= 5 {
            vramUsedMB = Double(fields[3].trimmingCharacters(in: .whitespaces))
            vramTotalMB = Double(fields[4].trimmingCharacters(in: .whitespaces))
        }

        return TelemetryGPUDevice(
            id: rawID.isEmpty ? name : rawID,
            name: name.isEmpty ? "GPU \(rawID)" : name,
            usagePercentage: min(max(usage, 0), 100),
            vramUsedMB: vramUsedMB,
            vramTotalMB: vramTotalMB
        )
    }
}
