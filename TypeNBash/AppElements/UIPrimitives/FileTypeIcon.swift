import AppKit
import SwiftUI

/// The icon for a file-browser row: a symbol from the app's own icon pack, a
/// Material Icon Theme asset, or an SF Symbol, looked up in the bundled
/// `FileIcons.json`.
///
/// The registry is keyed by file type, not by icon: one row per extension or
/// whole filename, each naming its icon. Rows with no icon are file types
/// TypeNBash knows about that still need one. A row with a `custom` pack symbol
/// keeps its older `material` or `symbol` beside it as the way back:
///
///     { "ext" : "swift", "material" : "swift", "custom" : "pack/swift" }
///
/// The reviewed pack uses monochrome geometry with a brand HEX tint when
/// unselected. Selected rows supply their own foreground style.
///
/// `nonisolated` for the same reason as `WorkspaceFileEntry`: entries and
/// `GitDiffFile` resolve their icon off the main actor.
nonisolated struct FileTypeIcon: Hashable, Sendable {
    enum Glyph: Hashable, Sendable {
        /// A name inside the `material` asset-catalog namespace, e.g. "swift".
        case material(String)
        case symbol(String)
        /// A `.symbolset` in the asset catalog, e.g. "pack/swift" from Scripts/IconPack.
        case custom(String)
    }

    /// Effects that loop for as long as the icon is on screen. Symbols only.
    enum Effect: String, Sendable {
        case pulse, breathe, variableColor, rotate
    }

    var glyph: Glyph
    var effect: Effect?
    var brandRGB: UInt32?

    static func symbol(_ name: String) -> FileTypeIcon { FileTypeIcon(glyph: .symbol(name)) }

    static func icon(for url: URL, isDirectory: Bool) -> FileTypeIcon {
        if isDirectory { return .symbol("folder.fill") }

        let filename = url.lastPathComponent.lowercased()
        if let icon = registry.filenames[filename] { return icon }

        // Longest extension first, so "foo.d.ts" finds "d.ts" before "ts".
        var rest = Substring(filename)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if let icon = registry.extensions[String(rest)] { return icon }
        }
        return .symbol("questionmark.app.dashed")
    }


    /// Icons whose default artwork is too dark for a light background; the
    /// catalog carries a `_light` counterpart for each.
    static var lightVariants: Set<String> { registry.lightVariants }

    /// One row of `FileIcons.json`: `ext` or `file`, its icons, and an optional effect.
    /// The effect is read as a string so a typo drops it, not the whole file.
    private struct Entry: Decodable {
        var ext: String?
        var file: String?
        var material: String?
        var symbol: String?
        var custom: String?
        var effect: String?

        func icon(brandColors: [String: UInt32]) -> FileTypeIcon? {
            let glyph = custom.map(Glyph.custom) ?? material.map(Glyph.material) ?? symbol.map(Glyph.symbol)
            let colorKey = material ?? symbol ?? custom
            return glyph.map { FileTypeIcon(glyph: $0, effect: effect.flatMap(Effect.init),
                                           brandRGB: colorKey.flatMap { brandColors[$0] }) }
        }
    }

    private struct Registry {
        var extensions: [String: FileTypeIcon] = [:]
        var filenames: [String: FileTypeIcon] = [:]
        var lightVariants: Set<String> = []
    }

    private static let registry: Registry = {
        struct File: Decodable {
            var extensions: [Entry]
            var filenames: [Entry]
            var lightVariants: [String]
            var brandColors: [String: String]?
        }
        guard
            let url = Bundle.main.url(forResource: "FileIcons", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return Registry() }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            // The file is edited by hand; every row falls back to "doc" until it's fixed.
            assertionFailure("FileIcons.json: \(error)")
            return Registry()
        }

        let brandColors = (file.brandColors ?? [:]).compactMapValues { value -> UInt32? in
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.count == 6 else { return nil }
            return UInt32(hex, radix: 16)
        }
        var registry = Registry(lightVariants: Set(file.lightVariants))
        for entry in file.extensions {
            if let key = entry.ext, let icon = entry.icon(brandColors: brandColors) { registry.extensions[key.lowercased()] = icon }
        }
        for entry in file.filenames {
            if let key = entry.file, let icon = entry.icon(brandColors: brandColors) { registry.filenames[key.lowercased()] = icon }
        }
        return registry
    }()
}

/// Draws a `FileTypeIcon` at list-row size. `.template` is the selected row:
/// every icon then draws flat in `symbolStyle`.
struct FileTypeIconView<S: ShapeStyle>: View {
    let icon: FileTypeIcon
    let symbolStyle: S
    let renderingMode: Image.TemplateRenderingMode
    @Environment(\.colorScheme) private var colorScheme


    private var iconStyle: AnyShapeStyle {
        guard renderingMode != .template, let rgb = icon.brandRGB else { return AnyShapeStyle(symbolStyle) }
        let red = (rgb >> 16) & 0xFF, green = (rgb >> 8) & 0xFF, blue = rgb & 0xFF
        let high = max(red, max(green, blue)), low = min(red, min(green, blue))
        // Near-black/white brand marks follow the appearance for contrast.
        if high - low <= 32 && (high <= 50 || low >= 210) { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255,
                                  blue: Double(blue) / 255, opacity: 1))
    }

    /// Unknown file types draw dimmed, except on a selected row, which supplies its own style.
    private func symbolGlyphStyle(for name: String) -> AnyShapeStyle {
        guard renderingMode != .template, name == "questionmark.app.dashed" else { return AnyShapeStyle(symbolStyle) }
        return AnyShapeStyle(Color.secondary)
    }

    var body: some View {
        switch icon.glyph {
            case .material(let name):
                let variant = colorScheme == .light && FileTypeIcon.lightVariants.contains(name)
                    ? "\(name)_light"
                    : name
                Image("material/\(variant)")
                    .renderingMode(renderingMode)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(symbolStyle)
            case .symbol(let name):
                Image(systemName: name)
                    .renderingMode(renderingMode)
                    .modifier(LoopingEffect(effect: icon.effect))
                    .frame(width: 16)
                    .foregroundStyle(symbolGlyphStyle(for: name))
            case .custom(let name):
                // Explicit monochrome preserves the lettering and clear-behind
                // layers in the Markdown and config symbols in every row state.
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .symbolRenderingMode(.monochrome)
                    .modifier(LoopingEffect(effect: icon.effect))
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(iconStyle)
        }
    }
}

private struct LoopingEffect: ViewModifier {
    let effect: FileTypeIcon.Effect?

    func body(content: Content) -> some View {
        switch effect {
            case nil: content
            case .pulse: content.symbolEffect(.pulse)
            case .breathe: content.symbolEffect(.breathe)
            case .variableColor: content.symbolEffect(.variableColor.iterative)
            case .rotate: content.symbolEffect(.rotate)
        }
    }
}
