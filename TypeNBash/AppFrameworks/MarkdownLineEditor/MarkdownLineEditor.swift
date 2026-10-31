//
//  MarkdownLineEditor.swift
//  TypeNBash
//
//  Rendered Markdown editing built the way Xcode's Markdown editor is: a
//  contenteditable page where every source line is one `<div>`, markers show
//  only on the caret's line, and each edit comes back as a line splice. The
//  page (MarkdownLineEditor.html/.css/.js) owns the line grammar and renders
//  each keystroke itself, with no round trip; this side owns the text that
//  the file model saves.
//

import AppKit
import SwiftMath
import SwiftUI
import WebKit

struct MarkdownLineEditorView: View {
    @Binding var text: String
    @State private var bridge = MarkdownLineEditorBridge()

    var body: some View {
        WebView(bridge.page)
            .webViewContentBackground(.hidden)
            .onAppear {
                bridge.onEdit = { text = $0 }
                bridge.show(text)
            }
            .onChange(of: text) { _, newValue in
                // The page's own edits come back equal; anything else (a
                // revert, a reload from disk) replaces the document.
                if newValue != bridge.text { bridge.show(newValue) }
            }
    }
}

@MainActor
final class MarkdownLineEditorBridge {
    /// Created on first use, so the bridges SwiftUI builds and throws away
    /// with each view value never start a web process.
    private(set) lazy var page = makePage()
    private(set) var text = ""
    var onEdit: ((String) -> Void)?

    private var lines = [""]
    private var lineEnding = "\n"
    private var isReady = false

    /// Replaces the page's document with `newText`.
    func show(_ newText: String) {
        text = newText
        lineEnding = newText.contains("\r\n") ? "\r\n" : "\n"
        lines = newText.components(separatedBy: lineEnding)
        if isReady { push() }
    }

    private func push() {
        let arguments: [String: Any] = ["lines": lines, "theme": Self.theme()]
        Task { _ = try? await page.callJavaScript("editor.load(lines, theme)", arguments: arguments) }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            push()
        case "splice":
            guard let from = message["from"] as? Int, let to = message["to"] as? Int,
                  let inserted = message["lines"] as? [String],
                  0 <= from, from <= to, to <= lines.count
            else { return resync() }
            lines.replaceSubrange(from..<to, with: inserted)
            commit()
        case "reset":
            guard let all = message["lines"] as? [String] else { return }
            lines = all
            commit()
        case "math":
            guard let items = message["items"] as? [[String: Any]] else { return }
            let results = items.compactMap(MathTypesetter.typeset)
            Task { _ = try? await page.callJavaScript("editor.mathReady(results)", arguments: ["results": results]) }
        default:
            break
        }
    }

    private func commit() {
        text = lines.joined(separator: lineEnding)
        onEdit?(text)
    }

    /// Takes the page's whole text when a splice doesn't fit this copy.
    private func resync() {
        Task {
            guard let all = try? await page.callJavaScript("return editor.lines()") as? [String] else { return }
            lines = all
            commit()
        }
    }

    private func makePage() -> WebPage {
        let configuration = WebPage.Configuration()
        let proxy = MessageProxy()
        proxy.bridge = self
        configuration.userContentController.add(proxy, name: "editor")
        let page = WebPage(configuration: configuration, navigationDecider: StayOnPage())
        _ = page.load(html: Self.html)
        return page
    }

    /// The page with its stylesheet and scripts inlined, so nothing loads from disk at runtime.
    private static let html: String = {
        func resource(_ name: String, _ ext: String) -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext),
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return "" }
            return contents
        }
        // A literal `</script` inside an inlined script would end its tag early.
        func script(_ name: String) -> String {
            resource(name, "js").replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        }
        return resource("MarkdownLineEditor", "html")
            .replacingOccurrences(of: "/*{{CSS}}*/", with: resource("MarkdownLineEditor", "css"))
            .replacingOccurrences(of: "/*{{HIGHLIGHT}}*/", with: script("MarkdownLineEditor-highlight"))
            .replacingOccurrences(of: "/*{{JS}}*/", with: script("MarkdownLineEditor"))
    }()

    /// The app theme's text and accent colors, resolved for light and dark so
    /// the page can follow its own appearance; it takes the rest from the system.
    private static func theme() -> [String: String] {
        var theme: [String: String] = [:]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                theme["fg-\(name)"] = css(Color.foreground)
                theme["accent-\(name)"] = css(Color.accentColor)
            }
        }
        return theme
    }

    private static func css(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "rgba(%d, %d, %d, %.3f)",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), c.alphaComponent)
    }
}

/// Typesets the page's `$…$` and `$$…$$` with SwiftMath. Each formula comes
/// back as a 2x PNG drawn in black, which the page uses as a mask filled
/// with the text color, plus its size and baseline in CSS pixels.
enum MathTypesetter {
    static func typeset(_ item: [String: Any]) -> [String: Any]? {
        guard let id = item["id"] as? Int, let tex = item["tex"] as? String else { return nil }
        let size = CGFloat(item["size"] as? Double ?? 15)
        let display = item["display"] as? Bool ?? false
        var math = MathImage(latex: tex, fontSize: size, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout, image.size.width > 0, image.size.height > 0,
              let png = png(image, scale: 2)
        else { return ["id": id, "error": true] }
        // MathImage centers the formula vertically, never shorter than half the
        // font size; its baseline sits `descent` above the bottom of that box.
        let inked = max(layout.ascent + layout.descent, size / 2)
        let baseline = (image.size.height - inked) / 2 + layout.descent
        return [
            "id": id,
            "url": "data:image/png;base64," + png.base64EncodedString(),
            "w": image.size.width, "h": image.size.height, "d": baseline,
        ]
    }

    private static func png(_ image: NSImage, scale: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((image.size.width * scale).rounded(.up)),
            pixelsHigh: Int((image.size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Forwards page messages without the content controller retaining the bridge.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: MarkdownLineEditorBridge?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        bridge?.receive(message.body)
    }
}

/// Keeps the editor on its page: links open in the browser, dropped files go nowhere.
private struct StayOnPage: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.scheme != "about" else { return .allow }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}
