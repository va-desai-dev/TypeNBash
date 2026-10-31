//
//  SyntaxDefinition.swift
//
//  TypeNBash
//
//  Loads CotEditor's bundled `.cotsyntax` definitions and maps a file's
//  extension to one. A lightweight stand-in for CotEditor's `SyntaxManager`
//  (which is tied to user-settings file management we don't need).
//

import Foundation
import SyntaxFormat

nonisolated enum SyntaxDefinition {

    /// One entry of the bundled `SyntaxMap.json`.
    private struct MapEntry: Decodable {
        var extensions: [String]?
        var filenames: [String]?
        var interpreters: [String]?
    }

    /// Lowercased file extension → syntax name (e.g. "swift" → "Swift").
    private static let extensionMap: [String: String] = build(\.extensions)

    /// Lowercased whole filename → syntax name (e.g. ".htaccess" → "Apache").
    private static let filenameMap: [String: String] = build(\.filenames)

    /// Lowercased interpreter → syntax name (e.g. "bash" → "Shell Script").
    private static let interpreterMap: [String: String] = build(\.interpreters)

    /// Lowercased syntax name → syntax name (e.g. "python" → "Python").
    private static let nameMap: [String: String] = rawMap.keys.reduce(into: [:]) { result, name in
        result[name.lowercased()] = name
    }

    private static let rawMap: [String: MapEntry] = {
        guard
            let url = Bundle.main.url(forResource: "SyntaxMap", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let map = try? JSONDecoder().decode([String: MapEntry].self, from: data)
        else { return [:] }
        return map
    }()

    private static func build(_ keyPath: KeyPath<MapEntry, [String]?>) -> [String: String] {
        var result: [String: String] = [:]
        for (name, entry) in rawMap {
            for key in entry[keyPath: keyPath] ?? [] {
                let key = key.lowercased()
                if result[key] == nil { result[key] = name }
            }
        }
        return result
    }

    /// The syntax name that matches the given file, or `nil` if none applies.
    static func syntaxName(for fileURL: URL) -> String? {
        let filename = fileURL.lastPathComponent.lowercased()
        if let name = filenameMap[filename] { return name }

        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty, let name = extensionMap[ext] { return name }

        return nil
    }

    /// The syntax a fenced code block's info string names, or `nil` if none
    /// applies. Only the first word counts (```python title="x.py"), and it
    /// may be an extension (`py`), a syntax name (`python`) or an interpreter (`bash`).
    static func syntaxName(forFenceLanguage language: String?) -> String? {
        guard let word = language?.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return nil }
        return extensionMap[word] ?? nameMap[word] ?? interpreterMap[word]
    }

    /// Loads the `Syntax` for the given file, or `nil` if no definition matches.
    static func load(for fileURL: URL?) -> (syntax: Syntax, name: String)? {
        guard let fileURL, let name = syntaxName(for: fileURL) else { return nil }
        return load(name: name)
    }

    /// Loads the bundled `Syntax` with the given name.
    static func load(name: String) -> (syntax: Syntax, name: String)? {
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "cotsyntax"),
            let wrapper = try? FileWrapper(url: url, options: .immediate),
            let syntax = try? Syntax(fileWrapper: wrapper)
        else { return nil }
        return (syntax, name)
    }
}
