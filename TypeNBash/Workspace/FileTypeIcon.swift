import AppKit
import SwiftUI

/// The icon for a file-browser row: a Material Icon Theme asset for the file
/// types TypeNBash can open, an SF Symbol for folders and everything else.
///
/// `nonisolated` for the same reason as `WorkspaceFileEntry`: entries and
/// `GitDiffFile` resolve their icon off the main actor.
nonisolated enum FileTypeIcon: Hashable, Sendable {
    /// A name inside the `material` asset-catalog namespace, e.g. "swift".
    case material(String)
    case symbol(String)

    static func icon(for url: URL, isDirectory: Bool) -> FileTypeIcon {
        if isDirectory { return .symbol("folder.fill") }

        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if let name = filenameIcons[filename] ?? extensionIcons[ext] {
            return .material(name)
        }
        // Everything the editor highlights, keyed by the same syntax lookup it uses.
        if let syntax = SyntaxDefinition.syntaxName(for: url), let name = syntaxIcons[syntax] {
            return .material(name)
        }
        // Non-text formats the preview pane renders.
        if FileBrowserModel.imageExtensions.contains(ext) { return .material("image") }
        if FileBrowserModel.documentExtensions.contains(ext) { return .material("pdf") }
        if FileBrowserModel.tableExtensions.contains(ext) { return .symbol("tablecells") }
        return .symbol("doc")
    }

    /// Whole-filename overrides, checked first (lowercased).
    private static let filenameIcons: [String: String] = [
        "readme.md": "readme", "readme": "readme", "readme.txt": "readme",
        "license": "license", "license.md": "license", "license.txt": "license",
        "changelog.md": "changelog", "changelog": "changelog",
        "gemfile": "gemfile",
        ".editorconfig": "editorconfig",
        "package.swift": "swift",
    ]

    /// Extensions that deserve a more specific icon than their syntax's.
    private static let extensionIcons: [String: String] = [
        "h": "h",
        "hpp": "hpp", "hh": "hpp", "hxx": "hpp", "h++": "hpp", "hp": "hpp",
        "cu": "cuda", "cuh": "cuda",
        "tsx": "react_ts",
        "clj": "clojure", "edn": "clojure",
        "log": "log",
    ]

    /// `SyntaxMap.json` syntax name → Material icon.
    private static let syntaxIcons: [String: String] = [
        "AWK": "console",
        "Ada": "ada",
        "Apache": "settings",
        "AppleScript": "applescript",
        "Assembly": "assembly",
        "BibTeX": "bibliography",
        "C": "c",
        "C#": "csharp",
        "C++": "cpp",
        "CSS": "css",
        "CoffeeScript": "coffee",
        "D": "d",
        "DTD": "xml",
        "Dart": "dart",
        "Diff": "diff",
        "Dockerfile": "docker",
        "Erlang": "erlang",
        "Fortran": "fortran",
        "Git": "git",
        "Git Config": "git",
        "Git Ignore": "git",
        "Go": "go",
        "HTML": "html",
        "Haskell": "haskell",
        "INI": "settings",
        "JSON": "json",
        "Java": "java",
        "JavaScript": "javascript",
        "Julia": "julia",
        "Kotlin": "kotlin",
        "LaTeX": "tex",
        "Lisp": "lisp",
        "Lua": "lua",
        "MATLAB": "matlab",
        "METAFONT": "font",
        "Makefile": "makefile",
        "Markdown": "markdown",
        "Metal": "shader",
        "Mojo": "mojo",
        "PHP": "php",
        "Pascal": "pascal",
        "Perl": "perl",
        "Plain Text": "document",
        "PowerShell": "powershell",
        "Properties": "settings",
        "Protocol Buffers": "proto",
        "Python": "python",
        "R": "r",
        "Ruby": "ruby",
        "Rust": "rust",
        "SQL": "database",
        "SVG": "svg",
        "Scala": "scala",
        "Scheme": "scheme",
        "Shell Script": "console",
        "Swift": "swift",
        "TOML": "toml",
        "Tcl": "tcl",
        "Textile": "document",
        "TypeScript": "typescript",
        "Verilog": "verilog",
        "XML": "xml",
        "Xcode Project": "settings",
        "YAML": "yaml",
        "jq": "json",
        "reStructuredText": "document",
    ]

    /// Icons whose default artwork is too dark for a light background; the
    /// catalog carries a `_light` counterpart for each.
    static let lightVariants: Set<String> = ["toml"]
}

/// Draws a `FileTypeIcon` at list-row size. Material assets keep their own
/// colors; `symbolStyle` only tints the SF Symbol fallback.
struct FileTypeIconView<S: ShapeStyle>: View {
    let icon: FileTypeIcon
    let symbolStyle: S

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch icon {
            case .material(let name):
                let variant = colorScheme == .light && FileTypeIcon.lightVariants.contains(name)
                    ? "\(name)_light"
                    : name
                Image("material/\(variant)")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            case .symbol(let name):
                Image(systemName: name)
                    .foregroundStyle(symbolStyle)
                    .frame(width: 16)
        }
    }
}
