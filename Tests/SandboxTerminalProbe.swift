import AppKit
import SwiftUI
@testable import TypeNBash

/// Signed, independently launched test app. Uses the production SwiftTerm host,
/// launch preparation, and folder grant; no injected sandbox grants or shell mocks.
@main
struct SandboxTerminalProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = TerminalController()
    private var grant: WorkspaceFolderGrant?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.beginProbe() }
    }

    private func beginProbe() {
        NSApp.activate(ignoringOtherApps: true)
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeWorkspacePath") as? String else { return }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.message = "Authorize the temporary terminal test workspace. Commands touch only generated fixtures."
        panel.prompt = "Run Terminal Tests"
        guard panel.runModal() == .OK, panel.url?.standardizedFileURL == root else {
            NSApp.terminate(nil)
            return
        }
        do {
            let grant = try WorkspaceFolderGrant(url: panel.url!)
            self.grant = grant
            var configuration = TerminalLaunchConfiguration.localShell(workingDirectory: root)
            precondition(!AgentBuildCapabilities.localCommands, "The prototype must not enable agent shell execution")
            do {
                _ = try SandboxTerminalLaunch.prepare(configuration)
                preconditionFailure("Console accepted an absent workspace grant")
            } catch {}
            configuration.workspaceGrant = grant
            var outside = TerminalLaunchConfiguration.localShell(workingDirectory: root.deletingLastPathComponent())
            outside.workspaceGrant = grant
            do {
                _ = try SandboxTerminalLaunch.prepare(outside)
                preconditionFailure("Console accepted a directory outside its grant")
            } catch {}
            let terminal = TerminalHostView(configuration: configuration, controller: controller, onExit: { code in
                let control = root.deletingLastPathComponent().appendingPathComponent("outside/control.txt")
                let denied = (try? Data(contentsOf: control)) == nil
                // SwiftTerm currently reports the raw waitpid status (7 << 8).
                let report = "shellWaitStatus=\(code.map(String.init) ?? "nil")\nparentOutsideReadDenied=\(denied)\ncontainerHome=\(FileManager.default.homeDirectoryForCurrentUser.path)\n"
                try? report.write(to: root.appendingPathComponent("probe-process.txt"), atomically: true, encoding: .utf8)
            })
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "TypeNBash Signed Sandbox Terminal Probe"
            window.contentView = NSHostingView(rootView: terminal)
            self.window = window
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            func terminalHost(in view: NSView) -> TerminalHostNSView? {
                if let host = view as? TerminalHostNSView { return host }
                return view.subviews.lazy.compactMap { terminalHost(in: $0) }.first
            }
            let host = terminalHost(in: window.contentView!)!
            let logs = root.appendingPathComponent("pty-output")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            host.terminal.setHostLogging(directory: logs.path)
            let script = Bundle.main.resourceURL!.appendingPathComponent("commands.zsh")
            controller.send("source " + TerminalShellIntegration.posixQuote(script.path) + "\n")
            Task {
                for _ in 0..<100 {
                    let log = try? String(contentsOf: root.appendingPathComponent("terminal-probe.log"), encoding: .utf8)
                    if log?.contains("PROBE_COMPLETE") == true {
                        var before = winsize()
                        let beforeResult = ioctl(host.terminal.process.childfd, TIOCGWINSZ, &before)
                        let beforeError = beforeResult == -1 ? errno : 0
                        window.setContentSize(NSSize(width: 720, height: 420))
                        try? await Task.sleep(for: .milliseconds(300))
                        var after = winsize()
                        let afterResult = ioctl(host.terminal.process.childfd, TIOCGWINSZ, &after)
                        let afterError = afterResult == -1 ? errno : 0
                        try? "before=\(beforeResult) errno=\(beforeError) size=\(before.ws_row)x\(before.ws_col)\nafter=\(afterResult) errno=\(afterError) size=\(after.ws_row)x\(after.ws_col)\n".write(
                            to: root.appendingPathComponent("probe-resize.txt"), atomically: true, encoding: .utf8)
                        controller.send("/bin/stty size > resized-pty.txt\n/bin/sleep 30\n")
                        try? await Task.sleep(for: .milliseconds(500))
                        controller.send("\u{3}")
                        controller.send("printf 'interrupt survived\\n' > interrupt.txt\nexit 7\n")
                        try? await Task.sleep(for: .seconds(2))
                        let interrupted = FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupt.txt").path)
                        try? "interruptWithinTwoSeconds=\(interrupted)\nrunning=\(controller.isRunning) processRunning=\(host.terminal.process.running) pid=\(host.terminal.process.shellPid)".write(
                            to: root.appendingPathComponent("probe-lifecycle.txt"), atomically: true, encoding: .utf8)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                try? "Timed out waiting for command probes".write(to: root.appendingPathComponent("probe-timeout.txt"),
                                                                atomically: true, encoding: .utf8)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = error.localizedDescription
            alert.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
