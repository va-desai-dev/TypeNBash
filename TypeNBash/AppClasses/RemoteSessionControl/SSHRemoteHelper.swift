import Foundation
import Synchronization

/// One long-lived `python3` on the host that runs the filesystem scripts
/// in-process, so an operation costs a line of JSON instead of an ssh client and
/// a Python start. It also polls watched folders and pushes their changes.
///
/// Requests and replies are newline-delimited JSON carrying an `id`; replies
/// may arrive out of order because each request runs on its own thread.
nonisolated final class SSHRemoteHelper: @unchecked Sendable {
    static let version = 1

    private let process: Process
    private let input: Mutex<FileHandle>
    private let state = Mutex(State())
    /// Yields each watched folder that changes. Owned by the filesystem, so it
    /// outlives this helper and carries on into a restarted one.
    private let changes: AsyncStream<URL>.Continuation

    private struct State {
        var nextID = 0
        var pending: [Int: CheckedContinuation<Reply, any Error>] = [:]
        var buffer = Data()
        var isRunning = true
        var watched: [String] = []
    }

    private struct Request: Encodable {
        var id = 0
        let op: String
        var args: [String] = []
        var input: Data?
        var version: Int?
        var scripts: [String: String]?
    }

    private struct Reply: Decodable {
        let id: Int?
        let data: Data?
        let error: String?
        let version: Int?
        let event: String?
        let path: String?
    }

    var isRunning: Bool { state.withLock { $0.isRunning } }

    private init(process: Process, input: FileHandle, output: FileHandle, changes: AsyncStream<URL>.Continuation) {
        self.process = process
        self.input = Mutex(input)
        self.changes = changes
        output.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self?.stop()
                return
            }
            self.consume(chunk)
        }
    }

    deinit {
        stop()
    }

    /// Starts the helper and completes the version handshake, or returns nil so
    /// the caller keeps running each operation as its own script.
    @MainActor
    static func start(
        connection: OpenSSHConnection, scripts: [String: String], changes: AsyncStream<URL>.Continuation
    ) async -> SSHRemoteHelper? {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        guard let process = try? connection.remoteProcess(program: "python3", arguments: ["-c", script]) else { return nil }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        // A write after the helper exits fails instead of raising SIGPIPE.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let helper = SSHRemoteHelper(
            process: process, input: inputPipe.fileHandleForWriting, output: outputPipe.fileHandleForReading,
            changes: changes
        )
        do { try process.run() } catch {
            helper.stop()
            return nil
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            helper.stop()
        }
        defer { timeout.cancel() }
        let reply = try? await helper.send(Request(op: "hello", version: version, scripts: scripts))
        guard reply?.version == version else {
            helper.stop()
            return nil
        }
        return helper
    }

    /// Runs the script registered as `op` with `arguments` as its `sys.argv` and
    /// `input` as its stdin, returning its stdout. A script error throws like a
    /// failed remote command.
    func run(_ op: String, _ arguments: [String], input: Data? = nil) async throws -> Data {
        let reply = try await send(Request(op: op, args: arguments, input: input))
        if let error = reply.error { throw SSHConnectionError.commandFailed(status: 1, message: error) }
        return reply.data ?? Data()
    }

    /// Replaces the set of folders polled for changes. Off the caller's thread,
    /// since a large write may hold the pipe; each write sends the newest set,
    /// so the helper ends up with it whatever order they run in.
    func watch(_ paths: [String]) {
        state.withLock { $0.watched = paths }
        Task.detached { [self] in
            try? input.withLock { handle in
                let request = Request(id: nextID(), op: "watch", args: state.withLock { $0.watched })
                try handle.write(contentsOf: JSONEncoder().encode(request) + [0x0A])
            }
        }
    }

    private func nextID() -> Int {
        state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
    }

    private func send(_ request: Request) async throws -> Reply {
        var request = request
        let id = nextID()
        request.id = id
        let line = try JSONEncoder().encode(request) + [0x0A]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let isRunning = state.withLock { state in
                    if state.isRunning { state.pending[id] = continuation }
                    return state.isRunning
                }
                guard isRunning else { return continuation.resume(throwing: SSHConnectionError.disconnected) }
                do {
                    try input.withLock { try $0.write(contentsOf: line) }
                } catch {
                    stop()
                }
            }
        } onCancel: {
            state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    private func consume(_ chunk: Data) {
        var remainder = chunk[...]
        var lines: [Data] = []
        state.withLock { state in
            while let newline = remainder.firstIndex(of: 0x0A) {
                state.buffer.append(remainder[..<newline])
                lines.append(state.buffer)
                state.buffer.removeAll(keepingCapacity: true)
                remainder = remainder[(newline + 1)...]
            }
            state.buffer.append(remainder)
        }
        for line in lines {
            // Anything that isn't a reply, such as a login banner, is skipped.
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { continue }
            if reply.event == "changed", let path = reply.path {
                changes.yield(URL(fileURLWithPath: path, isDirectory: true))
            } else if let id = reply.id {
                state.withLock { $0.pending.removeValue(forKey: id) }?.resume(returning: reply)
            }
        }
    }

    /// Closing stdin makes the helper exit; requests still waiting fail.
    private func stop() {
        let pending = state.withLock { state in
            state.isRunning = false
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: SSHConnectionError.disconnected) }
        input.withLock { try? $0.close() }
        if process.isRunning { process.terminate() }
    }

    /// Exits when stdin closes, so a dropped connection leaves nothing behind.
    /// `os._exit` skips waiting on request threads still running.
    static let script = #"""
    import base64, io, json, os, sys, threading, time, traceback
    VERSION = 1
    requests, replies = sys.stdin.buffer, sys.stdout.buffer
    lock, local = threading.Lock(), threading.local()
    scripts, watched = {}, {}

    class Stream:
        def __init__(self, name):
            self.name = name
        def __getattr__(self, attribute):
            return getattr(getattr(local, self.name), attribute)

    class Arguments(list):
        def __getitem__(self, index):
            return local.argv[index]
        def __len__(self):
            return len(local.argv)
        def __iter__(self):
            return iter(local.argv)

    # Each script sees its own argv, stdin and stdout, as if run with `python3 -c`.
    sys.stdin, sys.stdout, sys.argv = Stream("stdin"), Stream("stdout"), Arguments()

    def send(message):
        line = json.dumps(message).encode() + b"\n"
        with lock:
            try:
                replies.write(line)
                replies.flush()
            except OSError:
                os._exit(0)

    def snapshot(path):
        try:
            info = os.stat(path)
            return info.st_mtime_ns, info.st_ino
        except OSError:
            return None

    def poll():
        while True:
            time.sleep(1.5)
            current = watched
            for path, seen in list(current.items()):
                now = snapshot(path)
                if now != seen:
                    current[path] = now
                    send({"event": "changed", "path": path})

    def handle(request):
        global watched
        reply = {"id": request["id"]}
        try:
            op, arguments = request["op"], request.get("args", [])
            if op == "hello":
                scripts.update((name, compile(source, name, "exec")) for name, source in request["scripts"].items())
                reply["version"] = VERSION
            elif op == "watch":
                watched = {path: watched[path] if path in watched else snapshot(path) for path in arguments}
            else:
                local.argv = ["-c"] + arguments
                local.stdin = io.TextIOWrapper(io.BytesIO(base64.b64decode(request.get("input") or "")), encoding="utf-8")
                local.stdout = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
                exec(scripts[op], {"__name__": "__main__"})
                local.stdout.flush()
                reply["data"] = base64.b64encode(local.stdout.buffer.getvalue()).decode()
        except (Exception, SystemExit) as error:
            reply["error"] = "".join(traceback.format_exception_only(type(error), error)).strip()
        send(reply)

    threading.Thread(target=poll, daemon=True).start()
    for line in requests:
        request = json.loads(line)
        if request["op"] == "hello":
            handle(request)
        else:
            threading.Thread(target=handle, args=(request,), daemon=True).start()
    os._exit(0)
    """#
}
