import SwiftUI

struct ProjectSearchView: View {
    @Bindable var model: ProjectSearchModel
    let onOpen: (ProjectSearchResult, ProjectSearchMatch) -> Void
    let files: FileBrowserModel

    var body: some View {
        Group {
            if model.results.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "Search this project" : model.isSearching ? "Searching…" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Search text files inside the project root."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.results) { file in
                    ProjectSearchFileRow(model: model, file: file, onOpen: onOpen)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            ProjectSearchControls(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            PaneBar(edge: .bottom) {
                Text("\(model.count) \(model.count == 1 ? "result" : "results") in \(model.results.count) \(model.results.count == 1 ? "file" : "files")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.canReplace && !model.isReplacing {
                    Button { model.previewReplacement() } label: {
                        Text("Replace…")
                    }
                    .buttonStyle(.bordered)
                    .help("Preview Replace All…")
                    .disabled(!model.canReplace)
                }
            }
        }
        .background(Color.card)
        .sheet(item: $model.review) { review in
            ProjectReplacementReviewView(model: model, review: review)
        }
    }
}
