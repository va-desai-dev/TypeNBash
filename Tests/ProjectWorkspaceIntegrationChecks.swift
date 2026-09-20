import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct ProjectWorkspaceIntegrationChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-layout-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "ProjectLayout-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ProjectStore(defaults: defaults)
        let session = WindowSession(localRoot: root)
        await session.open(store.makeProject(directoryPath: root.path), at: .local(root))
        let router = AppRouter(session: session, profiles: SSHProfileStore(defaults: defaults), store: store)
        let host = NSHostingView(rootView: AnyView(ContentView(router: router)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Project workspace checks"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1100, height: 900))
        await settle()

        let terminals = descendants(of: host, as: TerminalHostNSView.self)
        check(terminals.count == 1, "Project mounts exactly one console")
        let terminal = terminals[0]
        let pid = terminal.terminal.process.shellPid
        check(pid > 0 && terminal.terminal.process.running, "Project console starts a live shell")
        check(terminal.onReady == nil, "Terminal releases its startup closure after launch")
        guard let split = descendants(of: host, as: NSSplitView.self).first(where: { !$0.isVertical }) else {
            fatalError("Project has no native vertical stack")
        }
        check(split.arrangedSubviews.count == 2, "Native split holds editor above console")
        check(split.dividerThickness > 20, "Status footer occupies the actual divider gap")
        for x in [CGFloat(12), split.bounds.midX, split.bounds.maxX - 48] {
            let point = NSPoint(x: x, y: split.arrangedSubviews[0].frame.maxY + split.dividerThickness / 2)
            let target = split.hitTest(split.superview!.convert(point, from: split))
            check(target === split,
                  "Footer labels and empty space route pointer events to the native divider")
        }
        let minimumEditor = (split.delegate as! NSSplitViewController).splitViewItems[0].minimumThickness
        split.setPosition((minimumEditor + split.bounds.height - split.dividerThickness) / 2, ofDividerAt: 0)
        await settle()
        let beforeDrag = split.arrangedSubviews[0].frame.height
        let start = split.convert(NSPoint(x: split.bounds.midX,
                                          y: split.arrangedSubviews[0].frame.maxY + split.dividerThickness / 2), to: nil)
        let end = NSPoint(x: start.x, y: start.y + 15)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let drag = mouse(.leftMouseDragged, at: end)
        let release = mouse(.leftMouseUp, at: end)
        let dragTimer = Timer(timeInterval: 0.05, repeats: false) { _ in
            NSApp.postEvent(drag, atStart: true)
        }
        let releaseTimer = Timer(timeInterval: 0.15, repeats: false) { _ in
            NSApp.postEvent(release, atStart: true)
        }
        RunLoop.main.add(dragTimer, forMode: .eventTracking)
        RunLoop.main.add(releaseTimer, forMode: .eventTracking)
        split.mouseDown(with: mouse(.leftMouseDown, at: start))
        await settle()
        check(abs(split.arrangedSubviews[0].frame.height - beforeDrag) > 10,
              "Dragging the middle of the footer resizes the native split")
        split.setPosition(split.bounds.height - 220, ofDividerAt: 0)
        await settle()
        let consoleHeight = terminal.bounds.height
        check(consoleHeight > 0, "Console remains visible after divider movement")

        guard let toggle = descendants(of: split, as: NSButton.self).first(where: {
            $0.identifier?.rawValue == "project.console.toggle"
        }) else { fatalError("Project footer has no console button") }
        let buttonPoint = NSPoint(x: toggle.frame.midX, y: toggle.frame.midY)
        check(split.hitTest(split.superview!.convert(buttonPoint, from: split)) === toggle,
              "Console button receives clicks instead of starting a divider drag")
        for _ in 0..<3 {
            toggle.performClick(nil)
            await settle()
            check(split.isSubviewCollapsed(split.arrangedSubviews[1]), "Button collapses the native console item")
            check(toggle.frame.maxY <= split.bounds.maxY && !toggle.isHiddenOrHasHiddenAncestor,
                  "Footer button remains visible while the console is hidden")
            check(terminal.terminal.process.running && terminal.terminal.process.shellPid == pid,
                  "Hiding the console preserves its running shell")
            check(toggle.toolTip == "Show Console", "Hidden console offers a Show Console action")
            toggle.performClick(nil)
            await settle()
            check(!split.isSubviewCollapsed(split.arrangedSubviews[1]), "Button reveals the native console item")
            check(abs(terminal.bounds.height - consoleHeight) < 2, "Showing console restores its divider height")
            check(descendants(of: host, as: TerminalHostNSView.self).first === terminal,
                  "Showing console reuses the same terminal view")
        }

        session.fileBrowser.newFile()
        session.fileBrowser.updatePreviewText("draft survives console activity")
        await settle()
        check(descendants(of: host, as: TerminalHostNSView.self).first === terminal,
              "Editor changes preserve the mounted console")
        check(terminal.terminal.process.shellPid == pid, "Editor changes preserve the shell process")
        check(abs(terminal.bounds.height - consoleHeight) < 2,
              "Editor changes preserve the chosen console height")
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1200, height: 900)] {
            window.setContentSize(size)
            await settle()
            check(terminal.bounds.height >= 0 && terminal.bounds.width > 0,
                  "Window resizing keeps valid console geometry")
            check(terminal.terminal.process.shellPid == pid, "Window resizing does not restart the shell")
        }

        // The console's directory is recorded for actions that need it, and still
        // never steers the project browser.
        let browsedBefore = session.fileBrowser.directory
        let selectedBefore = session.fileBrowser.selectedFile
        let elsewhere = URL(fileURLWithPath: "/tmp")
        session.terminalReported(host: nil, directory: elsewhere, generation: session.terminalGeneration)
        await settle()
        check(session.consoleDirectory?.standardizedFileURL == elsewhere.standardizedFileURL,
              "A console directory report is recorded in project mode")
        check(session.fileBrowser.directory == browsedBefore
              && session.fileBrowser.selectedFile == selectedBefore,
              "Recording it does not move the project browser or drop its selection")

        session.closeProject()
        await settle()
        check(descendants(of: host, as: NSSplitView.self).allSatisfy(\.isVertical),
              "Leaving project mode removes the vertical console split")
        check(descendants(of: host, as: TerminalHostNSView.self).count == 1,
              "Home owns one terminal after project teardown")
        check(!terminal.terminal.process.running, "Leaving project mode terminates its old console")
        host.rootView = AnyView(EmptyView())
        await settle()
        session.close()
        window.close()
        await checkFooterControls()
        print("Project workspace integration checks passed")
    }

    /// A footer that holds a control, not just labels.
    ///
    /// The footer sits in the divider gap as a non-arranged subview, so
    /// `NSSplitView` hit-tests straight past it and claims the point for the
    /// divider. That is right for a status label and wrong for a text field,
    /// which is otherwise unclickable.
    @MainActor static func checkFooterControls() async {
        let footer = AnyView(
            HStack(spacing: 8) {
                Text("Missing Data Codes")
                TextField("NA, N/A, .", text: .constant("")).frame(maxWidth: 260)
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 6)
        )
        let controller = ProjectSplitView<AnyView, AnyView, AnyView>.Controller(
            editor: AnyView(Color.blue), footer: footer, console: AnyView(Color.green))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1100, height: 900))
        await settle()

        let split = controller.footerSplit
        let y = split.arrangedSubviews[0].frame.maxY + split.dividerThickness / 2
        func target(_ x: CGFloat) -> NSView? {
            split.hitTest(split.superview!.convert(NSPoint(x: x, y: y), from: split))
        }
        guard let field = descendants(of: split, as: NSTextField.self)
            .max(by: { $0.frame.width < $1.frame.width })
        else { fatalError("The footer's text field never mounted") }
        let fieldRect = field.convert(field.bounds, to: split)

        let hit = target(fieldRect.midX)
        check(hit === field || hit.map { $0.isDescendant(of: field) } == true,
              "A control in the footer receives its own pointer events")
        check(target(12) === split, "Footer labels still route pointer events to the native divider")
        check(target(fieldRect.maxX + 80) === split,
              "Empty footer space still routes pointer events to the native divider")
        check(target(split.bounds.maxX - 18) is NSButton, "The console button keeps its hit target")

        let before = controller.splitViewItems[0].viewController.view.frame.height
        split.setPosition(before - 60, ofDividerAt: 0)
        await settle()
        check(controller.splitViewItems[0].viewController.view.frame.height != before,
              "The divider still moves with a control in the footer")
        window.close()
    }

    @MainActor static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }
}
