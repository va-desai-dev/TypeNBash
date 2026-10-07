import AppKit
import SwiftUI
import WebKit
@testable import TypeNBash

@main
struct BrowserIntegrationChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run() } catch { fatalError("Browser checks: \(error)") }
            exit(0)
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        precondition(BrowserModel.resolve("  ") == nil)
        precondition(BrowserModel.resolve("localhost:8080/login")?.absoluteString == "http://localhost:8080/login")
        precondition(BrowserModel.resolve("example.com/login")?.absoluteString == "https://example.com/login")
        for query in ["two words", "two\nwords", "person@example.com"] {
            let components = URLComponents(url: BrowserModel.resolve(query)!, resolvingAgainstBaseURL: false)!
            precondition(components.queryItems?.first?.value == query)
        }

        let model = BrowserModel(initialURL: nil)
        let tab = model.activeTab!
        let url = URL(string: "https://browser-fixture.invalid/")!
        let html = """
        <html><head><title>Browser fixture</title></head><body>
        <input id="input" value="Keep my selection"><p id="prose">Do not select the whole page.</p>
        <a id="newtab" target="_blank" href="https://browser-fixture.invalid/login">Login</a>
        </body></html>
        """
        let host = NSHostingView(rootView: BrowserView(model: model).frame(width: 900, height: 650))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Browser Integration Checks"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        for try await _ in tab.page.load(simulatedRequest: URLRequest(url: url), responseHTML: html) {}
        try await settle()
        tab.syncAddress()

        _ = try await tab.page.callJavaScript("document.getElementById('input').focus(); document.getElementById('input').setSelectionRange(5, 7)")
        let commandL = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
        precondition(window.performKeyEquivalent(with: commandL), "Command-L must focus the address field")
        try await settle()
        guard let editor = window.firstResponder as? NSTextView else { fatalError("Address field did not receive focus") }
        precondition(editor.string == url.absoluteString)
        precondition(editor.selectedRange().length == (url.absoluteString as NSString).length)
        let selectedPageText = try await tab.page.callJavaScript("return window.getSelection().toString()") as? String
        precondition(selectedPageText == "", "Address selection must not select webpage text")
        editor.insertText("search draft", replacementRange: editor.selectedRange())
        try await settle()
        precondition(tab.addressText == "search draft")
        tab.syncAddress()
        precondition(tab.addressText == "search draft", "URL updates must not overwrite an address draft")
        _ = window.performKeyEquivalent(with: commandL)
        try await settle()
        precondition(editor.selectedRange().length == ("search draft" as NSString).length,
                     "Command-L must select the address even when already focused")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle()
        precondition(tab.addressText == url.absoluteString, "Escape restores the current URL")
        precondition(window.firstResponder !== editor, "Escape returns focus to the page")

        _ = window.performKeyEquivalent(with: commandL)
        try await settle()
        guard let submitted = window.firstResponder as? NSTextView else { fatalError("Repeated Command-L failed") }
        submitted.insertText("about:blank", replacementRange: submitted.selectedRange())
        submitted.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle()
        precondition(tab.page.url?.absoluteString == "about:blank", "Return must submit the address")
        precondition(window.firstResponder !== submitted, "Submitting must release address focus")

        for try await _ in tab.page.load(simulatedRequest: URLRequest(url: url), responseHTML: html) {}
        _ = try await tab.page.callJavaScript("document.getElementById('newtab').click()")
        try await settle()
        precondition(model.tabs.count == 2, "New-window links must create a tab")
        precondition(model.activeTab !== tab)
        precondition(model.activeTab?.addressText == "https://browser-fixture.invalid/login")
        model.close(model.activeTab!)
        precondition(model.activeTab === tab)
        model.close(tab)
        precondition(model.activeTab == nil && model.activeTabID == nil)
        model.open()
        precondition(model.tabs.count == 1 && model.activeTab != nil)
        print("PASS: address parsing, Command-L selection, draft preservation, Escape, Return, new-window links, and tab closing")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }
}
