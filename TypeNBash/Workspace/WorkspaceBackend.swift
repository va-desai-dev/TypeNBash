import Foundation

enum WorkspaceLocation: Equatable, Sendable {
    case local
    case ssh(SSHConnectionProfile)


}

@MainActor
protocol WorkspaceBackend: AnyObject {
    var location: WorkspaceLocation { get }
    var rootDirectory: URL { get }
    var fileSystem: any WorkspaceFileSystem { get }

    func connect() async throws
    func disconnect()
    /// Launch parameters for the SwiftTerm-backed terminal.
    func makeTerminalConfiguration() throws -> TerminalLaunchConfiguration
    func applyTelemetry(to monitor: SystemMonitor) async throws
}

@MainActor
final class LocalWorkspaceBackend: WorkspaceBackend {
    let location = WorkspaceLocation.local
    let rootDirectory: URL
    let fileSystem: any WorkspaceFileSystem

    init(rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rootDirectory = rootDirectory
        fileSystem = LocalWorkspaceFileSystem()
    }

    func connect() async throws {}
    func disconnect() {}

    func makeTerminalConfiguration() -> TerminalLaunchConfiguration {
        .localShell(workingDirectory: rootDirectory)
    }

    func applyTelemetry(to monitor: SystemMonitor) async throws {
        monitor.useLocalTelemetry()
    }
}

@MainActor
final class SSHWorkspaceBackend: WorkspaceBackend {
    let location: WorkspaceLocation
    private(set) var rootDirectory = URL(fileURLWithPath: "/")
    private(set) var fileSystem: any WorkspaceFileSystem = UnavailableWorkspaceFileSystem()

    private let profile: SSHConnectionProfile
    private let connection: OpenSSHConnection
    private var lastTelemetryDate: Date?

    init(
        profile: SSHConnectionProfile,
        authentication: SSHAuthentication = .keyOrAgent
    ) {
        self.profile = profile
        location = .ssh(profile)
        connection = OpenSSHConnection(
            profile: profile,
            authentication: authentication
        )
    }

    func connect() async throws {
        try await connection.connect()
        let discoveredHome = try await discoverHomeDirectory()
        let requestedRoot = profile.remoteRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedRoot, !requestedRoot.isEmpty {
            rootDirectory = try await resolveRemotePath(requestedRoot)
        } else {
            rootDirectory = discoveredHome
        }
        fileSystem = SSHWorkspaceFileSystem(
            connection: connection,
            homeDirectory: discoveredHome
        )
        // Validate the requested root before the window adopts this backend.
        _ = try await fileSystem.contentsOfDirectory(
            at: rootDirectory,
            includingHiddenFiles: false
        )
    }

    func setProjectRoot(_ root: URL) {
        rootDirectory = root
    }

    func disconnect() {
        connection.disconnect()
    }

    func makeTerminalConfiguration() throws -> TerminalLaunchConfiguration {
        try connection.makeTerminalConfiguration(workingDirectory: rootDirectory)
    }

    func applyTelemetry(to monitor: SystemMonitor) async throws {
        let result = try await connection.execute(
            program: "sh",
            arguments: ["-lc", Self.telemetryScript]
        )
        try Task.checkCancellation()
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let snapshot = LinuxTelemetryParser.parse(output)
        let now = Date()
        let interval = lastTelemetryDate.map { max(now.timeIntervalSince($0), 0.1) } ?? 2.0
        lastTelemetryDate = now
        monitor.applyLinuxTelemetry(snapshot, interval: interval)
    }

    private func discoverHomeDirectory() async throws -> URL {
        let result = try await connection.execute(
            program: "python3",
            arguments: ["-c", "import os; print(os.path.expanduser('~'))"]
        )
        let path = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw WorkspaceFileSystemError.invalidResponse("Remote home directory was not absolute.")
        }
        return URL(fileURLWithPath: path)
    }

    func resolveRemotePath(_ path: String) async throws -> URL {
        let result = try await connection.execute(
            program: "python3",
            arguments: [
                "-c",
                "import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))",
                path
            ]
        )
        let resolved = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.hasPrefix("/") else {
            throw WorkspaceFileSystemError.invalidResponse("Remote workspace root was not absolute.")
        }
        return URL(fileURLWithPath: resolved)
    }

    private static let telemetryScript = """
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    idle1=$((idle + iowait))
    total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
    sleep 0.2
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    idle2=$((idle + iowait))
    total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
    awk -v total1="$total1" -v total2="$total2" -v idle1="$idle1" -v idle2="$idle2" 'BEGIN {
        total = total2 - total1
        idle = idle2 - idle1
        printf "cpu_percent=%.1f\\n", (total > 0 ? (100 * (total - idle) / total) : 0)
    }'
    awk '
        /^MemTotal:/ { total=$2 }
        /^MemFree:/ { free=$2 }
        /^MemAvailable:/ { available=$2 }
        /^Buffers:/ { buffers=$2 }
        /^Cached:/ { cached=$2 }
        /^SReclaimable:/ { reclaimable=$2 }
        END {
            print "mem_total_kb=" total
            print "mem_free_kb=" free
            print "mem_available_kb=" available
            print "mem_cached_kb=" (buffers + cached + reclaimable)
        }
    ' /proc/meminfo
    df -Pk "$HOME" | awk 'NR == 2 {
        print "storage_total_kb=" $2
        print "storage_used_kb=" $3
        print "storage_free_kb=" $4
    }'
    awk -F '[: ]+' '$2 != "lo" {
        rx += $3
        tx += $11
    } END {
        print "net_rx_bytes=" rx
        print "net_tx_bytes=" tx
    }' /proc/net/dev
    gpu_count=0
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_rows=$(nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
        if [ -n "$gpu_rows" ]; then
            printf '%s\\n' "$gpu_rows" | awk -F ',' '{
                for (i = 1; i <= NF; i++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
                }
                print "gpu=" $1 "|" $2 "|" $3 "|" $4 "|" $5
                sum += $3
                count += 1
            } END {
                printf "gpu_percent=%.1f\\n", (count > 0 ? sum / count : 0)
            }'
            gpu_count=$(printf '%s\\n' "$gpu_rows" | awk 'NF { count += 1 } END { print count + 0 }')
        fi
    fi
    if [ "$gpu_count" -eq 0 ] && [ -d /proc/driver/nvidia/gpus ]; then
        for gpu_info in /proc/driver/nvidia/gpus/*/information; do
            [ -r "$gpu_info" ] || continue
            gpu_id=$(basename "$(dirname "$gpu_info")")
            gpu_name=$(awk -F ': *' '/^Model:/ { print $2; exit }' "$gpu_info")
            [ -n "$gpu_name" ] || gpu_name="NVIDIA GPU $gpu_id"
            printf 'gpu=%s|%s|0\\n' "$gpu_id" "$gpu_name"
            gpu_count=$((gpu_count + 1))
        done
        echo "gpu_percent=0"
    fi
    if [ "$gpu_count" -eq 0 ] && command -v lspci >/dev/null 2>&1; then
        pci_rows=$(lspci 2>/dev/null | awk '/VGA|3D|Display/')
        if [ -n "$pci_rows" ]; then
            printf '%s\\n' "$pci_rows" | awk '{
            name=$0
            sub(/^[^ ]+ /, "", name)
            print "gpu=" (count + 0) "|" name "|0"
            count += 1
            } END {
                printf "gpu_percent=%.1f\\n", 0
            }'
            gpu_count=$(printf '%s\\n' "$pci_rows" | awk 'NF { count += 1 } END { print count + 0 }')
        fi
    fi
    if [ "$gpu_count" -eq 0 ] && ls /sys/class/drm/card*/device/class >/dev/null 2>&1; then
        for class_file in /sys/class/drm/card*/device/class; do
            class_value=$(cat "$class_file" 2>/dev/null)
            case "$class_value" in
                0x03*)
                    card_name=$(basename "$(dirname "$(dirname "$class_file")")")
                    vendor=$(cat "$(dirname "$class_file")/vendor" 2>/dev/null)
                    device=$(cat "$(dirname "$class_file")/device" 2>/dev/null)
                    printf 'gpu=%s|%s %s %s|0\\n' "$card_name" "$card_name" "$vendor" "$device"
                    gpu_count=$((gpu_count + 1))
                    ;;
            esac
        done
        echo "gpu_percent=0"
    fi
    if [ "$gpu_count" -eq 0 ]; then
        echo "gpu_percent=0"
    fi
    ps -eo pid=,comm=,rss= --sort=-rss | head -n 3 | awk '{
        pid=$1
        rss=$NF
        name=$2
        print "process=" pid "|" name "|" rss
    }'
    """
}

private final class UnavailableWorkspaceFileSystem: WorkspaceFileSystem {
    let homeDirectory = URL(fileURLWithPath: "/")

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry] {
        throw WorkspaceFileSystemError.unsupported("The workspace is not connected.")
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        throw WorkspaceFileSystemError.unsupported("The workspace is not connected.")
    }

    func writeFile(_ data: Data, to url: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("The workspace is not connected.")
    }

    func createDirectory(at url: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("The workspace is not connected.")
    }
}
