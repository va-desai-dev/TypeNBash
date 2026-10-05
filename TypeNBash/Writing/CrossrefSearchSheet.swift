import SwiftUI
import BibTeXKit

struct CrossrefSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = CrossrefSearchModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Crossref").font(.headline)
            HStack {
                TextField("Title, author, DOI, or DOI URL", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .disabled(!model.canSearch)
            }
            if model.isSearching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching Crossref…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }
            }
            List(model.results) { source in
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.citation.title).font(.callout).textSelection(.enabled)
                    Text(source.citation.summary).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let url = source.url { Link(source.doi, destination: url).lineLimit(1) }
                        Spacer()
                        Button("Copy BibTeX") { model.copy(source) }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 6)
            }
            .listStyle(.plain)
            .overlay {
                if model.results.isEmpty && !model.isSearching && model.message == nil {
                    Text("Find scholarly works by title or author,\nor paste a DOI for an exact lookup.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Metadata from Crossref").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        .background(Color.card)
        .onDisappear { model.cancel() }
    }
}
