import SwiftUI
import Foundation
import AppKit

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
            } else if model.visibleResults.isEmpty {
                ContentUnavailableView("No matching files", systemImage: "line.3.horizontal.decrease",
                    description: Text("No file with matches has “\(model.pathFilter)” in its path."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleResults) { file in
                    ProjectSearchFileRow(model: model, file: file, onOpen: onOpen)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paneBar(.top) {
            ProjectSearchControls(model: model)
        }
        .sheet(item: $model.review) { review in
            ProjectReplacementReviewView(model: model, review: review)
        }
    }
}

struct ProjectSearchFileRow: View {
    let model: ProjectSearchModel
    let file: ProjectSearchResult
    let onOpen: (ProjectSearchResult, ProjectSearchMatch) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(file.matches) { match in
                Button { onOpen(file, match) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(match.line)").foregroundStyle(.secondary).monospacedDigit()
                        Text("\(match.before)\(Text(match.matched).bold().foregroundStyle(Color.accentColor))\(match.after)")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(file.path), line \(match.line): \(match.before)\(match.matched)\(match.after)")
                .contextMenu {
                    Button("Open Match") { onOpen(file, match) }
                    Button("Preview Replace Match…") { model.previewReplacement(file: file, match: match.range) }
                        .disabled(!model.canReplace || !model.showsReplacement)
                }
            }
        } label: {
            FileListRow(
                filename: file.label,
                icon: file.icon,
                style: .secondary,
                tag: file.url
            ) {
                Text("\(file.matches.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .help(file.path)
            .contextMenu {
                Button("Preview Replace in File…") { model.previewReplacement(file: file) }
                    .disabled(!model.canReplace || !model.showsReplacement)
            }
        }
    }
}
