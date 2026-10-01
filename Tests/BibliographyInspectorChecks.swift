import AppKit
import SwiftUI
import BibTeXKit
import BibTeXViewer
@testable import TypeNBash

@main
struct BibliographyInspectorChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileBrowserModel()
        precondition(!files.supportsCitations)
        for ext in ["md", "MD", "txt", "tex", "bib", "swift"] {
            let file = root.appendingPathComponent("document.\(ext)")
            try "Sample".write(to: file, atomically: true, encoding: .utf8)
            files.select(WorkspaceFileEntry(url: file, isDirectory: false, byteCount: 6))
            precondition(files.supportsCitations == (ext.lowercased() == "md"))
        }
        let url = root.appendingPathComponent("A very long bibliography filename that must fit the narrow inspector.bib")
        let source = """
        @article{aVeryLongCitationKeyThatMustNeverExpandTheInspectorWidth,
          title = {A very long paper title about scientific writing and the behavior of compact bibliography inspectors},
          author = {Doe, Jane and Smith, Alex}, year = {2026}, journal = {Journal of Research}}
        @book{second, title = {Another reference}, author = {Jones, Sam}, year = {2025}}
        @book{second, title = {A duplicate key reference}, author = {Smith, Alex}, year = {2024}}
        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let domain = "BibliographyChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = BibLibrary(projectID: UUID(), root: root,
                                 selections: BibSelectionStore(defaults: defaults), inbox: nil)
        library.select(url)
        for _ in 0..<200 {
            if library.entries.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(library.entries.count == 3)
        let browser = BibliographyBrowserModel()
        browser.search = "  jane  "
        precondition(browser.entries(in: library).count == 1)
        browser.search = "Journal of Research"
        precondition(browser.entries(in: library).count == 1)
        browser.search = "no matching paper"
        precondition(browser.entries(in: library).isEmpty)
        precondition(browser.citation(ids: Set(library.entries.map(\.id)), in: library)
                     == "[@aVeryLongCitationKeyThatMustNeverExpandTheInspectorWidth; @second]")
        browser.selection = ["second"]
        browser.pendingRemoval = ["second"]
        browser.reset()
        precondition(browser.search.isEmpty && browser.selection.isEmpty && browser.pendingRemoval.isEmpty)

        for width in [260.0, 300.0] {
            // TypeNBash forces the dark scheme for every workspace window.
            let view = BibliographyInspector(library: library, onOpenFile: { _ in }, onChooseFile: {})
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            precondition(host.frame.width == width, "Inspector stays within its allocated width")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let output = URL(fileURLWithPath: "/tmp/centcom-bibliography-\(Int(width))-dark.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            }
            window.close()
        }
        print("Bibliography checks passed: search, citation ordering and duplicate keys, state reset, and 260/300-point layouts in the app’s dark scheme.")
    }
}
