//
//  Item.swift
//  SysCOM
//
//  Created by Vedant A. Desai on 9/7/26.
//

import Foundation
import Combine
import Darwin
import IOKit
import Network
import SystemConfiguration

struct CPUSample: Identifiable {
    let id = UUID()
    let secondsAgo: Int // Lower numbers = more recent (0 to 9)
    let usage: Double   // Value from 0.0 to 100.0
}

/// A single process and its physical memory footprint — the same figure
/// Activity Monitor shows in its "Memory" column.
struct TopProcess: Identifiable {
    let id: pid_t       // the process id
    let name: String
    let footprintMB: Double
}

struct TelemetryGPUDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let usagePercentage: Double
    /// Discrete VRAM in megabytes. `nil` on unified-memory Macs, which have no
    /// separate video memory to report — on those, GPU load is the meaningful
    /// figure. On a remote NVIDIA box, VRAM is what people actually watch.
    var vramUsedMB: Double? = nil
    var vramTotalMB: Double? = nil

    var vramUsedFraction: Double? {
        guard let vramUsedMB, let vramTotalMB, vramTotalMB > 0 else { return nil }
        return min(max(vramUsedMB / vramTotalMB, 0), 1)
    }
}

/// A named slice of physical memory for the breakdown bar. The categories differ
/// per platform — macOS reports App/Wired/Compressed/Cached, Linux reports the
/// `free(1)` model of Used/Buff+Cache — so the model owns the taxonomy and the
/// view just renders whatever slices it is handed.
struct MemorySegment: Identifiable {
    let id = UUID()
    let name: String
    let value: Double   // in GB
    let role: MemoryRole
}

/// Platform-neutral role for a `MemorySegment`, used only to pick a display color.
enum MemoryRole {
    case app, wired, compressed, cached, buffers, used, free
}

/// Reads live CPU and memory usage straight from the kernel via the Mach
/// `host_statistics` APIs. Values are refreshed on a background-friendly async
/// loop and published back to SwiftUI on the main actor.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Int = 0        // whole-system busy percentage
    @Published var ramUsage: Double = 0      // used memory, in GB
    @Published var totalMemoryGB: Double = 0 // installed physical memory, in GB
    @Published var history: [CPUSample] = []
    @Published var gpuUsagePercentage: Double = 0.0
    @Published var gpuDevices: [TelemetryGPUDevice] = []
    @Published var isConnected: Bool = true
    @Published var isWifi: Bool = false

    // Live memory breakdown, in GB. Approximates Activity Monitor's categories
    // from public Mach stats (exact figures use a private framework).
    @Published var appMemoryGB: Double = 0
    @Published var wiredMemoryGB: Double = 0
    @Published var compressedMemoryGB: Double = 0
    @Published var cachedFilesGB: Double = 0
    @Published var freeMemoryGB: Double = 0

    // Platform-correct memory breakdown for the segmented bar. Populated by the
    // macOS Mach sampler and the Linux telemetry applier with different slices.
    @Published var memorySegments: [MemorySegment] = []

    @Published var downloadSpeedString: String = "0 KB/s"
    @Published var uploadSpeedString: String = "0 KB/s"
    @Published var storageTotalGB: Double = 0
    @Published var storageFreeGB: Double = 0
    @Published var storageUsedGB: Double = 0
    @Published var storageFreeString: String = "0 GB"
    @Published var storageUsedPercentage: Double = 0

    private var isRemoteTelemetry = false
    private var lastInBytes: UInt64 = 0
    private var lastOutBytes: UInt64 = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkTelemetryQueue")

    // Top memory-consuming processes readable by the current user.
    @Published var topProcesses: [TopProcess] = []

    private var cpuTimer: AnyCancellable?
    private var gpuTimer: Timer?

    /// The kernel reports CPU time as counters that only ever climb since boot,
    /// so a single reading is meaningless — we diff against the previous sample.
    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var monitorTask: Task<Void, Never>?

    init() {
        totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        start()
        self.history = (0..<300).map { CPUSample(secondsAgo: $0, usage: 0.0) }
        startCPUTimer()
        startGPUTimer()
        monitor.pathUpdateHandler = { [weak self] (path: NWPath) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard !self.isRemoteTelemetry else { return }
                self.isConnected = path.status == .satisfied
                // Only track actual desktop connection types
                self.isWifi = path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        monitorTask?.cancel()
        cpuTimer?.cancel()
        gpuTimer?.invalidate()
    }

    private func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func useLocalTelemetry() {
        let wasRemote = isRemoteTelemetry
        isRemoteTelemetry = false
        if wasRemote { resetTelemetryBaseline() }
        totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        isConnected = monitor.currentPath.status == .satisfied
        isWifi = monitor.currentPath.usesInterfaceType(.wifi)
        if wasRemote { sample() }
        start()
        if cpuTimer == nil {
            startCPUTimer()
        }
        if gpuTimer == nil {
            startGPUTimer()
        }
    }

    func useRemoteTelemetry(reset: Bool = false) {
        if !isRemoteTelemetry || reset { resetTelemetryBaseline() }
        isRemoteTelemetry = true
        monitorTask?.cancel()
        monitorTask = nil
        cpuTimer?.cancel()
        cpuTimer = nil
        gpuTimer?.invalidate()
        gpuTimer = nil
        isWifi = false
    }

    private func resetTelemetryBaseline() {
        lastInBytes = 0
        lastOutBytes = 0
        previousCPUTicks = nil
        downloadSpeedString = "0 KB/s"
        uploadSpeedString = "0 KB/s"
        history = []
        gpuUsagePercentage = 0
        gpuDevices = []
    }

    func applyLinuxTelemetry(_ snapshot: LinuxTelemetrySnapshot, interval: TimeInterval = 2.0) {
        useRemoteTelemetry()

        let clampedCPU = min(max(snapshot.cpuUsage, 0), 100)
        cpuUsage = Int(clampedCPU.rounded())
        appendCPUSample(clampedCPU)

        // Linux uses the `free(1)` model, not macOS's App/Wired/Compressed. Show
        // the three categories Linux actually reports and don't invent the rest.
        totalMemoryGB = snapshot.totalMemoryGB
        ramUsage = snapshot.usedMemoryGB
        appMemoryGB = snapshot.usedMemoryGB
        wiredMemoryGB = 0
        compressedMemoryGB = 0
        cachedFilesGB = snapshot.cachedMemoryGB
        freeMemoryGB = snapshot.freeMemoryGB
        memorySegments = [
            MemorySegment(name: "Used", value: snapshot.usedMemoryGB, role: .used),
            MemorySegment(name: "Buffers / Cache", value: snapshot.cachedMemoryGB, role: .buffers),
            MemorySegment(name: "Free", value: snapshot.freeMemoryGB, role: .free)
        ]

        storageTotalGB = snapshot.storageTotalGB
        storageUsedGB = snapshot.storageUsedGB
        storageFreeGB = snapshot.storageFreeGB
        storageFreeString = Self.formattedStorage(snapshot.storageFreeGB)
        storageUsedPercentage = snapshot.storageTotalGB > 0
            ? min(max(snapshot.storageUsedGB / snapshot.storageTotalGB, 0), 1)
            : 0

        updateRemoteNetworkTelemetry(
            receivedBytes: snapshot.networkReceivedBytes,
            transmittedBytes: snapshot.networkTransmittedBytes,
            interval: interval
        )

        gpuUsagePercentage = min(max(snapshot.gpuUsagePercentage, 0), 100)
        gpuDevices = snapshot.gpuDevices
        topProcesses = snapshot.topProcesses
        isConnected = true
    }

    private func startCPUTimer() {
        cpuTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isRemoteTelemetry,
                      let usage = self.currentCPUUsage() else { return }
                self.cpuUsage = usage
                self.appendCPUSample(Double(usage))
            }
    }

    private func startGPUTimer() {
        gpuTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so it fires on the
            // main thread — safe to hop straight to the main actor synchronously.
            MainActor.assumeIsolated {
                self?.sampleGPU()
            }
        }
    }

    private func appendCPUSample(_ usage: Double) {
        var currentSamples = history.map { CPUSample(secondsAgo: $0.secondsAgo + 1, usage: $0.usage) }
        currentSamples.insert(CPUSample(secondsAgo: 0, usage: usage), at: 0)
        history = Array(currentSamples.prefix(10))
    }

    private func updateRemoteNetworkTelemetry(
        receivedBytes: UInt64,
        transmittedBytes: UInt64,
        interval: TimeInterval
    ) {
        defer {
            lastInBytes = receivedBytes
            lastOutBytes = transmittedBytes
        }

        guard lastInBytes > 0 || lastOutBytes > 0 else { return }

        let downloadBytesPerSecond = Double(receivedBytes >= lastInBytes ? receivedBytes - lastInBytes : 0) / max(interval, 0.1)
        let uploadBytesPerSecond = Double(transmittedBytes >= lastOutBytes ? transmittedBytes - lastOutBytes : 0) / max(interval, 0.1)
        downloadSpeedString = Self.formattedBytesPerSecond(downloadBytesPerSecond)
        uploadSpeedString = Self.formattedBytesPerSecond(uploadBytesPerSecond)
    }

    private func sample() {
        guard !isRemoteTelemetry else { return }
        if let mem = currentMemory() {
            ramUsage = mem.usedGB
            appMemoryGB = mem.appGB
            wiredMemoryGB = mem.wiredGB
            compressedMemoryGB = mem.compressedGB
            cachedFilesGB = mem.cachedGB
            freeMemoryGB = mem.freeGB
            memorySegments = [
                MemorySegment(name: "App Memory", value: mem.appGB, role: .app),
                MemorySegment(name: "Wired", value: mem.wiredGB, role: .wired),
                MemorySegment(name: "Compressed", value: mem.compressedGB, role: .compressed),
                MemorySegment(name: "Cached Files", value: mem.cachedGB, role: .cached),
                MemorySegment(name: "Free", value: max(totalMemoryGB - mem.usedGB, 0), role: .free)
            ]
        }
        sampleNetworkThroughput()
        getStorageTelemetry()
        topProcesses = currentTopProcesses()
    }

    // MARK: - Mach reads

    /// Overall CPU busy percentage across all cores, computed from the delta
    /// between this reading and the previous one. Returns `nil` on the very
    /// first call (no baseline yet) or if the kernel call fails.
    private func currentCPUUsage() -> Int? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }

        // `&-` guards against the rare tick-counter wraparound.
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let busy = (user + system + nice) / total * 100
        return Int(busy.rounded())
    }

    private struct MemoryBreakdown {
        let usedGB: Double        // App + Wired + Compressed ("Memory Used")
        let appGB: Double         // internal - purgeable
        let wiredGB: Double
        let compressedGB: Double
        let cachedGB: Double      // external + purgeable ("Cached Files")
        let freeGB: Double        // free + speculative
    }

    /// One `host_statistics64` read, split into the exact categories Activity
    /// Monitor uses. `internal`/`external`/`purgeable` are the right fields —
    /// `active`/`inactive` do not map to AM's labels. Page size comes from the
    /// kernel because it is 16 KB on Apple Silicon and 4 KB on Intel.
    private func currentMemory() -> MemoryBreakdown? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let bytesPerGB = 1_073_741_824.0
        let pageSize = Double(vm_kernel_page_size)
        func gb(_ pages: Double) -> Double { pages * pageSize / bytesPerGB }

        let internalPages = Double(stats.internal_page_count)
        let externalPages = Double(stats.external_page_count)
        let purgeable = Double(stats.purgeable_count)
        let wired = Double(stats.wire_count)
        let compressed = Double(stats.compressor_page_count)
        let free = Double(stats.free_count)
        let speculative = Double(stats.speculative_count)

        let app = max(internalPages - purgeable, 0)

        return MemoryBreakdown(
            usedGB: gb(app + wired + compressed),
            appGB: gb(app),
            wiredGB: gb(wired),
            compressedGB: gb(compressed),
            cachedGB: gb(externalPages + purgeable),
            freeGB: gb(free + speculative)
        )
    }


    private func sampleGPU() {
        guard !isRemoteTelemetry else { return }
        // 1. Create a matching dictionary for iOS/macOS Accelerator Services
        guard let matchingDict = IOServiceMatching("IOAccelerator") else { return }

        // 2. Obtain an iterator for the matching IO services
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)

        guard result == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var totalDeviceUsage: Double = 0.0
        var countedDevices = 0

        // 3. Loop through all detected GPU/Accelerator entries in the registry
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?

            // Extract the core performance dictionary properties from the service
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let propDict = properties?.takeRetainedValue() as? [String: Any] {

                // 4. Target the Performance Statistics dictionary
                if let stats = propDict["PerformanceStatistics"] as? [String: Any] {
                    // "Device Utilization %" tracks the general processing engine saturation level
                    if let utilization = stats["Device Utilization %"] as? Int64 {
                        totalDeviceUsage += Double(utilization)
                        countedDevices += 1
                    } else if let utilization = stats["Device Utilization"] as? Int64 {
                        // Fallback naming schema handling depending on the hardware generation variant
                        totalDeviceUsage += Double(utilization)
                        countedDevices += 1
                    }
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // 5. Update your published metric state bound securely to the Main thread
        DispatchQueue.main.async {
            guard !self.isRemoteTelemetry else { return }
            if countedDevices > 0 {
                // Return average usage across core configurations bounded realistically between 0-100%
                let averageUsage = min(max(totalDeviceUsage / Double(countedDevices), 0.0), 100.0)
                self.gpuUsagePercentage = averageUsage
                self.gpuDevices = [
                    TelemetryGPUDevice(
                        id: "local",
                        name: "Local GPU",
                        usagePercentage: averageUsage
                    )
                ]
            } else {
                self.gpuUsagePercentage = 0.0
                self.gpuDevices = []
            }
        }
    }

    private func sampleNetworkThroughput() {
        guard let counters = currentNetworkByteCounters() else { return }

        defer {
            lastInBytes = counters.inBytes
            lastOutBytes = counters.outBytes
        }

        guard lastInBytes > 0 || lastOutBytes > 0 else { return }

        let interval = 2.0
        let downloadBytesPerSecond = Double(counters.inBytes >= lastInBytes ? counters.inBytes - lastInBytes : 0) / interval
        let uploadBytesPerSecond = Double(counters.outBytes >= lastOutBytes ? counters.outBytes - lastOutBytes : 0) / interval

        downloadSpeedString = Self.formattedBytesPerSecond(downloadBytesPerSecond)
        uploadSpeedString = Self.formattedBytesPerSecond(uploadBytesPerSecond)
    }

    private func currentNetworkByteCounters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var interface = firstInterface

        while true {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = flags & IFF_UP == IFF_UP
            let isRunning = flags & IFF_RUNNING == IFF_RUNNING
            let isLoopback = flags & IFF_LOOPBACK == IFF_LOOPBACK

            if isUp,
               isRunning,
               !isLoopback,
               interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                inBytes += UInt64(networkData.ifi_ibytes)
                outBytes += UInt64(networkData.ifi_obytes)
            }

            guard let next = interface.pointee.ifa_next else { break }
            interface = next
        }

        return (inBytes, outBytes)
    }

    private static func formattedBytesPerSecond(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return String(format: "%.0f %@", value, units[unitIndex])
        }

        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Enumerates every PID and returns the `limit` heaviest by physical
    /// footprint. Processes owned by other users (root system daemons) return
    /// `EPERM` and are silently skipped — the same limit any unprivileged
    /// monitor has. Requires the App Sandbox to be off.
    private func currentTopProcesses(limit: Int = 20) -> [TopProcess] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let byteCount = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * capacity))
        guard byteCount > 0 else { return [] }
        let pidCount = Int(byteCount) / MemoryLayout<pid_t>.size

        var processes: [TopProcess] = []
        processes.reserveCapacity(pidCount)
        for index in 0..<pidCount {
            let pid = pids[index]
            if pid <= 0 { continue }

            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)

            processes.append(TopProcess(
                id: pid,
                name: name.isEmpty ? "pid \(pid)" : name,
                footprintMB: Double(usage.ri_phys_footprint) / 1_048_576.0
            ))
        }

        return Array(processes.sorted { $0.footprintMB > $1.footprintMB }.prefix(limit))
    }

    private func getStorageTelemetry() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try fileURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            guard let totalCapacity = values.volumeTotalCapacity,
                  let freeCapacity = values.volumeAvailableCapacityForImportantUsage else { return }

            let bytesPerGB = 1_073_741_824.0
            let totalGB = Double(totalCapacity) / bytesPerGB
            let freeGB = Double(freeCapacity) / bytesPerGB
            let usedGB = max(totalGB - freeGB, 0)

            storageTotalGB = totalGB
            storageFreeGB = freeGB
            storageUsedGB = usedGB
            storageFreeString = Self.formattedStorage(freeGB)
            storageUsedPercentage = totalGB > 0 ? min(max(usedGB / totalGB, 0), 1) : 0
        } catch {
            print("Error getting storage capacity: \(error.localizedDescription)")
        }
    }

    private static func formattedStorage(_ gigabytes: Double) -> String {
        if gigabytes >= 1024 {
            return String(format: "%.1f TB", gigabytes / 1024)
        }

        return String(format: "%.0f GB", gigabytes)
    }

}
