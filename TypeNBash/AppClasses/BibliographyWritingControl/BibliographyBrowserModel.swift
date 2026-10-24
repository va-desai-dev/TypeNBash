import AppKit
import Observation
import BibTeXKit
import BibTeXViewer

extension FileBrowserModel {
    var supportsCitations: Bool { selectedFile?.pathExtension.lowercased() == "md" }
}

/// Presentation state and citation actions; BibLibrary owns file access and captures.
@MainActor @Observable
final class BibliographyBrowserModel {
    var search = ""
    var selection = Set<String>()
    var pendingRemoval = Set<String>()

    func entries(in library: BibLibrary) -> [BibEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.entries }
        return library.entries.filter { entry in
            let citation = entry.citation
            return ([entry.key, citation.title, citation.containerTitle ?? ""]
                    + citation.authors.map(\.display) + citation.editors.map(\.display))
                .contains { $0.localizedStandardContains(query) }
        }
    }

    func citation(ids: Set<String>, in library: BibLibrary) -> String? {
        var seen = Set<String>()
        let keys = library.entries.filter { ids.contains($0.id) }
            .map(\.key).filter { seen.insert($0).inserted }
        return keys.isEmpty ? nil : "[" + keys.map { "@\($0)" }.joined(separator: "; ") + "]"
    }

    func copy(ids: Set<String>, in library: BibLibrary, source: Bool = false) {
        let text: String?
        if source, let document = library.document {
            let entries = document.entries.filter { ids.contains($0.id) }
            text = entries.isEmpty ? nil : entries.map { document.source(of: $0) }.joined(separator: "\n\n") + "\n"
        } else {
            text = citation(ids: ids, in: library)
        }
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func remove(from library: BibLibrary) {
        library.delete(ids: pendingRemoval)
        selection.subtract(pendingRemoval)
        pendingRemoval.removeAll()
    }

    func reset() {
        search = ""
        selection.removeAll()
        pendingRemoval.removeAll()
    }
}
