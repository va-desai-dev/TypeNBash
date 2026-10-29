//
//  Snippets.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/29/26.
//
import Foundation
import Observation

/// Saved shell snippets, persisted in user defaults.
///
/// The store knows nothing about sessions or terminals: running a snippet is
/// the caller's job, so each window hands its own console in. Holding a
/// `WindowSession` here would recurse, since every session owns this store.
@MainActor
@Observable
final class SnippetsStore {
    /// One store for the app, so every window sees the same snippets.
    static let shared = SnippetsStore()

    private(set) var selectedSnippet: Snippet.ID?
    private(set) var snippets: [Snippet]

    private let defaults: UserDefaults
    private let storageKey = "TypeNBash.snippets"

    init(
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded  = try?
            JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        } else {
            snippets = []
        }
    }

    func select(_ snippet: UUID?) {
        guard selectedSnippet != snippet else { return }
        selectedSnippet = snippet
    }

    func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        persist()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        if selectedSnippet == snippet.id { selectedSnippet = nil }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct Snippet: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    var name: String
    var code: String
    var isSudo: Bool

    init(
        id: UUID,
        name: String,
        code: String,
        isSudo: Bool
    ) {
        self.id = id
        self.name = name
        self.code = code
        self.isSudo = isSudo
    }

    /// The text to type into the shell, or nil when there is nothing to run.
    ///
    /// A sudo snippet runs as one `sudo sh -c` so a multi-line body is elevated
    /// as a whole rather than only its first line.
    var commandLine: String? {
        let body = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let command = isSudo ? "sudo sh -c \(TerminalShellIntegration.posixQuote(body))" : body
        return command + "\n"
    }
}
