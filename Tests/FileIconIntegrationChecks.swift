import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct FileIconIntegrationChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let recordBefore = CommandLine.arguments.contains("--record-before")
        let samples: [(name: String, file: String, hex: UInt32)] = [
            ("markdown", "notes.md", 0x42A5F5), ("tsconfig", "tsconfig.json", 0x3178C6),
            ("jsconfig", "jsconfig.json", 0xF7DF1E), ("vue-config", "vue.config.ts", 0x4FC08D),
            ("markdoc-config", "markdoc.config.js", 0xFFB300), ("database", "data.sqlite3", 0xFFCA28),
            ("word", "report.docx", 0x2368C4), ("swift", "main.swift", 0xF05138),
            ("react", "main.jsx", 0x61DAFB), ("vercel", "vercel.json", 0x000000),
            ("editorconfig", ".editorconfig", 0xFEFEFE),
        ]
        var mismatches: [String] = []

        // Keep the reviewed cutouts, but paint unselected rows with their brand
        // color. Conflicting inherited styles must not override either state.
        for sample in samples {
            let name = sample.name
            let icon = FileTypeIcon.icon(for: URL(filePath: "/tmp/\(sample.file)"), isDirectory: false)
            precondition(icon.brandRGB == sample.hex, "Wrong brand HEX for \(sample.file)")
            for dark in [false, true] {
                let foreground: Color = dark ? .white : .black
                for selected in [false, true] {
                    let reference = Image("pack/\(name)")
                        .renderingMode(.template).resizable().symbolRenderingMode(.monochrome)
                        .aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                        .foregroundStyle(selected ? foreground : brandColor(sample.hex))
                    let expected = try pixels(reference, dark: dark)
                    let actual = try pixels(FileTypeIconView(
                        icon: icon, symbolStyle: foreground,
                        renderingMode: selected ? .template : .original
                    ), dark: dark)
                    // Equivalent SwiftUI colors can differ by one 8-bit step
                    // at antialiased edges; larger tint/geometry changes fail.
                    if actual.count != expected.count || zip(actual, expected).contains(where: { abs(Int($0.0) - Int($0.1)) > 1 }) {
                        let differences = zip(actual, expected).map { abs(Int($0) - Int($1)) }
                        FileHandle.standardError.write(Data("Pixel differences for \(name): \(differences.filter { $0 > 0 }.count) bytes, max \(differences.max() ?? 0)\n".utf8))
                        mismatches.append("\(name): dark=\(dark), selected=\(selected)")
                    }
                }
            }
        }
        let board = VStack(alignment: .leading, spacing: 10) {
            Text("Production file icons — brand color / selected / reference").font(.headline)
            ForEach(samples.indices, id: \.self) { index in
                let sample = samples[index]
                let name = sample.name
                let icon = FileTypeIcon.icon(for: URL(filePath: "/tmp/\(sample.file)"), isDirectory: false)
                HStack {
                    Text(name).frame(width: 130, alignment: .leading)
                    ForEach([false, true], id: \.self) { dark in
                        HStack(spacing: 24) {
                            FileTypeIconView(icon: icon,
                                             symbolStyle: dark ? Color.white : .black, renderingMode: .original)
                            FileTypeIconView(icon: icon,
                                             symbolStyle: dark ? Color.white : .black, renderingMode: .template)
                            Image("pack/\(name)").renderingMode(.template).resizable()
                                .symbolRenderingMode(.monochrome).aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16).foregroundStyle(brandColor(sample.hex))
                        }
                        .padding(12).foregroundStyle(.pink)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .background(dark ? Color.black : Color.white)
                    }
                }
            }
        }.padding().foregroundStyle(.black).background(Color(white: 0.9))
        let renderer = ImageRenderer(content: board)
        renderer.scale = 3
        let destination = "/tmp/centcom-file-icons-\(recordBefore ? "before" : "after").png"
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render the production icon view")
        }
        try png.write(to: URL(filePath: destination))
        print("Preview: \(destination)")
        print("Rendering mismatches: \(mismatches)")
        if recordBefore { return }
        precondition(mismatches.isEmpty, "Production rendering differs from the reviewed symbols")

        let expected: [String: String] = [
            "notes.md": "markdown", "README": "markdown", "TSCONFIG.JSON": "tsconfig",
            "jsconfig.json": "jsconfig", "vue.config.ts": "vue-config", "markdoc.config.js": "markdoc-config",
            "library.d.ts": "typescript-def", "main.ts": "typescript", "data.sqlite3": "database",
            "report.docx": "word", "references.bibtex": "bibliography", "graph.gv": "pipeline", "busy.ifb": "calendar",
        ]
        for (filename, name) in expected {
            precondition(FileTypeIcon.icon(for: URL(filePath: "/tmp/\(filename)"), isDirectory: false).glyph == .custom("pack/\(name)"), filename)
        }
        precondition(FileTypeIcon.icon(for: URL(filePath: "/tmp/notes.md"), isDirectory: true).glyph == .symbol("folder.fill"))
        precondition(FileTypeIcon.icon(for: URL(filePath: "/tmp/unknown.unmapped"), isDirectory: false).glyph == .symbol("doc"))
        let data = try Data(contentsOf: Bundle.main.url(forResource: "FileIcons", withExtension: "json")!)
        let registry = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var verified: Set<String> = []
        for group in ["extensions", "filenames"] {
            for row in registry[group] as! [[String: String]] {
                guard let name = row["custom"] else { fatalError("Unmapped icon: \(row)") }
                let filename = row["file"] ?? "sample." + row["ext"]!
                precondition(FileTypeIcon.icon(for: URL(filePath: "/tmp/\(filename)"), isDirectory: false).brandRGB != nil,
                             "Missing brand color: \(filename)")
                if verified.insert(name).inserted {
                    precondition(NSImage(symbolName: name, bundle: .main, variableValue: 1) != nil, "Missing compiled asset: \(name)")
                }
            }
        }
        print("PASS: HEX brand tints, selection overrides, neutral contrast and preserved cutouts in light/dark; filename precedence, compound extensions, fallbacks, and \(verified.count) referenced compiled symbols")
    }

    static func brandColor(_ hex: UInt32) -> Color {
        if hex == 0 || hex == 0xFFFFFF || hex == 0xFEFEFE { return .primary }
        return Color(nsColor: NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255,
                                     green: CGFloat(hex >> 8 & 255) / 255,
                                     blue: CGFloat(hex & 255) / 255, alpha: 1))
    }

    @MainActor static func pixels<V: View>(_ view: V, dark: Bool) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: 28, height: 28)
            .foregroundStyle(.pink).environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white))
        renderer.scale = 3
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let bytes = bitmap.bitmapData else {
            fatalError("Could not capture icon pixels")
        }
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
