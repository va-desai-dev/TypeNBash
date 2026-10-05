import SwiftUI
import BibTeXKit
import BibTeXViewer

struct BibliographyInspector: View {
    @ObservedObject var library: BibLibrary
    let onOpenFile: (URL) -> Void
    let onChooseFile: () -> Void
    @State private var browser = BibliographyBrowserModel()
    @State private var showsCrossrefSearch = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $browser.selection) {
                ForEach(browser.entries(in: library)) { entry in
                    BibliographyEntryRow(entry: entry)
                        .tag(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu { actions(for: entry) }
                        .onTapGesture(count: 2) { browser.copy(ids: [entry.id], in: library) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if library.fileURL == nil {
                    placeholder("Choose a bibliography", detail: "Choose or create a .bib file for this project.")
                } else if library.document == nil {
                    placeholder(library.lastMessage == nil ? "Loading bibliography…" : "Bibliography unavailable",
                                detail: "")
                } else if library.entries.isEmpty {
                    placeholder("No citations yet", detail: "Save a citation from Safari with CiteTex, or add one in the editor.")
                } else if browser.entries(in: library).isEmpty {
                    placeholder("No matches", detail: "Try another author, title, or citation key.")
                }
            }
            .onCopyCommand {
                guard let text = browser.citation(ids: browser.selection, in: library) else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
            if let message = library.lastMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.card)
        .sheet(isPresented: $showsCrossrefSearch) { CrossrefSearchSheet() }
        .confirmationDialog("Remove \(browser.pendingRemoval.count) citations?", isPresented: Binding(
            get: { !browser.pendingRemoval.isEmpty },
            set: { if !$0 { browser.pendingRemoval.removeAll() } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { browser.remove(from: library) }
            Button("Cancel", role: .cancel) { browser.pendingRemoval.removeAll() }
        } message: {
            Text("This removes the entries from the bibliography file. Citations using these keys will no longer resolve.")
        }
        .onChange(of: library.fileURL) { browser.reset() }
        .onChange(of: library.entries) {
            browser.selection.formIntersection(Set(library.entries.map(\.id)))
        }
        .onChange(of: browser.search) {
            browser.selection.formIntersection(Set(browser.entries(in: library).map(\.id)))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(library.availableFiles, id: \.self) { url in
                    Toggle(library.displayPath(url), isOn: Binding(
                        get: { library.fileURL == url },
                        set: { if $0 { library.select(url) } }
                    ))
                }
                Divider()
                Button("Choose or Create…", action: onChooseFile)
                Button("Rescan Project") { library.refreshAvailableFiles() }
                if let url = library.fileURL {
                    Button("Open Bibliography") { onOpenFile(url) }
                    if library.access.canBrowseLocally {
                        Button("Reveal in Finder") { library.revealInFinder() }
                    }
                    Button("Stop Using This File") { library.select(nil) }
                }
            } label: {
                Label(library.fileURL?.lastPathComponent ?? "Choose Bibliography…", systemImage: "books.vertical")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
            .help(library.fileURL.map(library.displayPath) ?? "Choose or create a bibliography")


            if library.fileURL != nil {
                HStack {
                    TextField("Search author, title, key", text: $browser.search)
                        .textFieldStyle(.roundedBorder)
                    Button("Search Crossref…", systemImage: "network") { showsCrossrefSearch = true }
                        .labelStyle(.iconOnly)
                }
                HStack(spacing: 8) {
                    Text(browser.selection.isEmpty ? "\(library.entries.count) citations" : "\(browser.selection.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Copy Citation", systemImage: "doc.on.doc") {
                        browser.copy(ids: browser.selection, in: library)
                    }
                    .disabled(browser.selection.isEmpty)
                    Menu("Citation Actions", systemImage: "ellipsis") {
                        Button("Select All Matches") { browser.selection = Set(browser.entries(in: library).map(\.id)) }
                        Button("Deselect All") { browser.selection.removeAll() }
                        Divider()
                        Button("Copy BibTeX") { browser.copy(ids: browser.selection, in: library, source: true) }
                            .disabled(browser.selection.isEmpty)
                        Button("Remove Selected…", role: .destructive) { browser.pendingRemoval = browser.selection }
                            .disabled(browser.selection.isEmpty)
                    }
                    .menuIndicator(.hidden)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            if library.pendingCaptures > 0, !library.autoAcceptCaptures || library.fileURL == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(library.pendingCaptures) Safari captures waiting", systemImage: "safari")
                        .font(.caption)
                    if library.fileURL != nil {
                        Button("Add Captures") { library.acceptCaptures() }
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder private func actions(for entry: BibEntry) -> some View {
        let ids = browser.selection.contains(entry.id) ? browser.selection : [entry.id]
        Button("Copy Citation") { browser.copy(ids: ids, in: library) }
        Button("Copy BibTeX") { browser.copy(ids: ids, in: library, source: true) }
        if let url = library.fileURL {
            Button("Open Bibliography") { onOpenFile(url) }
        }
        if let doi = entry.citation.doi, let url = URL(string: "https://doi.org/\(doi)") {
            Link("Open DOI", destination: url)
        } else if let address = entry.citation.url, let url = URL(string: address) {
            Link("Open URL", destination: url)
        }
        Divider()
        Button("Remove…", role: .destructive) { browser.pendingRemoval = ids }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.callout)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BibliographyEntryRow: View {
    let entry: BibEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.citation.title.isEmpty ? entry.key : entry.citation.title)
                .font(.callout)
                .lineLimit(2)
            Text(entry.citation.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(entry.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.isDuplicateKey {
                Label("Duplicate key", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help("\(entry.citation.title)\n\(entry.key)\nDouble-click to copy citation. Command-click to select several.")
    }
}
