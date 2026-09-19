//
//  TerminalHostView.swift
//  TypeNBash
//

import SwiftUI
import SwiftTerm

/// Container for a `LocalProcessTerminalView`.
///
/// The container exists for two reasons, both of which were causing visible
/// problems when the terminal was hosted by SwiftUI directly:
///
/// 1. It rounds its own corners in Core Animation. Doing that with a SwiftUI
///    `.clipShape` instead pushes the terminal onto SwiftUI's offscreen mask
///    path, so every frame the layer-backed terminal draws has to be composited
///    through a mask. That is what turned the window black for several seconds
///    when macOS rebuilt window backing stores after a full-screen Space swipe.
/// 2. It defers `startProcess` until the view actually has a size. A terminal
///    created at `.zero` reports a 0x0 `winsize` to the shell, so the shell
///    starts with a degenerate geometry and everything has to reflow once
///    SwiftUI finally lays the view out.
final class TerminalHostNSView: NSView {
    let terminal = LocalProcessTerminalView(frame: .zero)

    /// Invoked once, the first time this view has a usable size.
    var onReady: ((LocalProcessTerminalView) -> Void)?

    private var hasStarted = false

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        terminal.nativeForegroundColor = .white
        terminal.selectedTextBackgroundColor = NSColor(Color.accentColor)

        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if terminal.frame != bounds { terminal.frame = bounds }

        guard !hasStarted, bounds.width > 1, bounds.height > 1 else { return }
        hasStarted = true
        let start = onReady
        onReady = nil
        start?(terminal)
    }
}

/// Handle for driving the live terminal from outside the view tree.
///
/// The terminal is an AppKit view owned by SwiftUI, so callers such as "Open in
/// Terminal" have no direct reference to it. The controller bridges that gap and
/// queues anything sent before the shell is up, since the view is created and
/// the process started a layout pass later.
@MainActor
@Observable
final class TerminalController {
    fileprivate weak var terminal: LocalProcessTerminalView?

    private var pendingInput: [String] = []
    private var isReady = false
    private var hasAttached = false


    /// Whether a shell is currently attached and accepting input.
    var isRunning: Bool { terminal != nil && isReady }

    func send(_ text: String) {
        guard isReady, let terminal else {
            pendingInput.append(text)
            return
        }
        terminal.send(source: terminal, data: ArraySlice(Array(text.utf8)))
    }

    /// Changes the shell's working directory. This works the same for a local
    /// shell and an SSH session, because the terminal *is* whichever shell is
    /// connected — the path is simply interpreted on that machine.
    func changeDirectory(to path: String) {
        send("cd \(TerminalShellIntegration.posixQuote(path))\n")
    }

    fileprivate func attach(_ terminal: LocalProcessTerminalView) {
        if hasAttached { pendingInput.removeAll() }
        hasAttached = true
        self.terminal = terminal
        isReady = false
    }

    fileprivate func markReady(_ terminal: LocalProcessTerminalView) {
        guard self.terminal === terminal else { return }
        isReady = true
        let queued = pendingInput
        pendingInput.removeAll()
        for text in queued { send(text) }
    }

    /// Only the terminal that is currently attached may clear the controller.
    ///
    /// Changing workspaces changes the view's identity, and SwiftUI builds the
    /// replacement *before* dismantling the outgoing one. An unconditional clear
    /// here would therefore wipe out the incoming terminal moments after it
    /// registered, leaving the controller pointing at nil for the rest of the
    /// session — the terminal still accepts typing, but every programmatic send
    /// silently piles up in `pendingInput` instead.
    fileprivate func detach(_ terminal: LocalProcessTerminalView) {
        guard self.terminal === terminal else { return }
        self.terminal = nil
        isReady = false
    }
}

/// SwiftUI host for a real terminal, backed by SwiftTerm.
///
/// The process it runs comes entirely from `configuration`, so the same view
/// hosts a local login shell and an SSH session without knowing the difference —
/// `WorkspaceBackend` decides which.
struct TerminalHostView: NSViewRepresentable {
    var cornerRadius: CGFloat = 8
    var configuration: TerminalLaunchConfiguration
    var controller: TerminalController
    var onDirectoryChange: (_ host: String?, _ directory: URL) -> Void = { _, _ in }
    var onTitleChange: (String) -> Void = { _ in }
    var onExit: (Int32?) -> Void = { _ in }

    func makeNSView(context: Context) -> TerminalHostNSView {
        let host = TerminalHostNSView(cornerRadius: cornerRadius)

        // Attach the delegate before the process starts: `startProcess` reports
        // the initial size, title and directory straight away, and those
        // callbacks are dropped on the floor if the delegate isn't set yet.
        host.terminal.processDelegate = context.coordinator

        let configuration = configuration
        let integrationDirectory = configuration.installsLocalShellIntegration
            ? TerminalShellIntegration.makeZDOTDIR() : nil
        context.coordinator.integrationDirectory = integrationDirectory
        let environment = Self.environment(for: configuration, integrationDirectory: integrationDirectory)
        let controller = controller
        controller.attach(host.terminal)

        host.onReady = { terminal in
            // `arguments` carries argv in full, so element 0 is argv[0] — "-zsh"
            // for a login shell, "ssh" for a remote session — and SwiftTerm takes
            // that separately as `execName`.
            terminal.startProcess(
                executable: configuration.executablePath,
                args: Array(configuration.arguments.dropFirst()),
                environment: environment,
                execName: configuration.arguments.first,
                currentDirectory: configuration.workingDirectory.path(percentEncoded: false)
            )
            // Anything queued while the view was still being laid out — an
            // "Open in Terminal" that triggered the switch to this pane, say —
            // is replayed now. The pty buffers it until the shell finishes
            // sourcing its rc files.
            controller.markReady(terminal)
        }

        return host
    }

    func updateNSView(_ nsView: TerminalHostNSView, context: Context) {
        // Keep the coordinator's callbacks pointing at the current view value;
        // the terminal itself is deliberately left alone so a SwiftUI update
        // never disturbs the running shell. A genuinely different session
        // arrives as a new view identity, not as an update.
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: TerminalHostNSView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.parent.controller.detach(nsView.terminal)
        if let directory = coordinator.integrationDirectory {
            try? FileManager.default.removeItem(at: directory)
            coordinator.integrationDirectory = nil
        }

        // Drop the delegate before terminating. `terminate()` kills the child,
        // which would otherwise report back through `processTerminated` and be
        // indistinguishable from the user typing `exit` — and since that handler
        // relaunches the terminal, a deliberate teardown would relaunch itself
        // forever. Only a process that dies on its own should reach the delegate.
        nsView.terminal.processDelegate = nil

        // Without the terminate, every SwiftUI teardown leaks its shell: the view
        // goes away, `startProcess` runs again on the replacement, and the old
        // zsh lingers as an orphan holding its side of the pty.
        nsView.terminal.terminate()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Builds the child environment as SwiftTerm wants it: a `KEY=VALUE` array.
    private static func environment(
        for configuration: TerminalLaunchConfiguration,
        integrationDirectory: URL?
    ) -> [String] {
        var values = ProcessInfo.processInfo.environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "TypeNBash"

        if let integrationDirectory {
            values["ZDOTDIR"] = integrationDirectory.path
        }

        values.merge(configuration.environmentOverrides) { _, configured in configured }
        return values.map { "\($0.key)=\($0.value)" }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var parent: TerminalHostView
        var integrationDirectory: URL?
        var isActive = true

        init(_ parent: TerminalHostView) {
            self.parent = parent
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard isActive, parent.controller.terminal === source else { return }
            parent.onTitleChange(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard isActive, parent.controller.terminal === source,
                  let directory, let report = Self.parseReport(directory) else { return }
            parent.onDirectoryChange(report.host, report.directory)
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard isActive, parent.controller.terminal === source else { return }
            isActive = false
            parent.controller.detach(parent.controller.terminal!)
            parent.onExit(exitCode)
        }

        /// Preserve the authority for validation, but resolve the path through
        /// the workspace filesystem rather than the Mac's file URL authority.
        static func parseReport(
            _ reported: String
        ) -> (host: String?, directory: URL)? {
            if let parsed = URL(string: reported), parsed.isFileURL {
                let path = parsed.path
                guard path.hasPrefix("/") else { return nil }
                // An empty authority carries no information.
                let host = parsed.host.flatMap { $0.isEmpty ? nil : $0 }
                return (host, URL(fileURLWithPath: path))
            }
            guard reported.hasPrefix("/") else { return nil }
            return (nil, URL(fileURLWithPath: reported))
        }
    }
}
