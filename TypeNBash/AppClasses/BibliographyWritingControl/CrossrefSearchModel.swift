import AppKit
import Observation
import BibTeXKit

@Observable
final class CrossrefSearchModel {
    var query = ""
    private(set) var results: [AcademicSource] = []
    private(set) var isSearching = false
    private(set) var message: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let service: CrossrefService

    init(service: CrossrefService = CrossrefService()) { self.service = service }

    var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func search() {
        cancel()
        guard canSearch else { results = []; message = nil; return }
        let id = UUID()
        requestID = id
        let query = query
        isSearching = true
        results = []
        message = nil
        task = Task {
            defer { if requestID == id { isSearching = false } }
            do {
                let sources = try await service.searchSources(query: query)
                guard !Task.isCancelled, requestID == id else { return }
                var seen = Set<String>()
                results = sources.filter { seen.insert($0.id).inserted }
                message = results.isEmpty ? "No matches. Try another title, author, or DOI." : nil
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                message = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        isSearching = false
    }

    func copy(_ source: AcademicSource) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BibTeX.entry(for: source.citation), forType: .string)
        message = "Copied BibTeX. Paste it into your bibliography file."
    }
}
