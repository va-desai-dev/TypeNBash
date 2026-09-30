import SwiftUI

struct WritingInspector: View {
    let model: FileBrowserModel
    @State private var monitor = WritingStatisticsMonitor()

    var body: some View {
        Group {
            if let file = model.selectedFile, WindowSession.textFileTypes(for: file) {
                if model.writingText != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Writing", systemImage: "pencil.line")
                                .font(.headline)
                            Text(file.lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            let statistics = monitor.file == file ? monitor.statistics : nil
                            LabeledContent("Words", value: statistics?.words.formatted() ?? "—")
                            LabeledContent("Paragraphs", value: statistics?.paragraphs.formatted() ?? "—")
                            LabeledContent("Sentences", value: statistics?.sentences.formatted() ?? "—")
                            Divider()
                            LabeledContent("Pages (estimated)", value: statistics?.pages.formatted() ?? "—")
                            Text("250 words per page, rounded up. Paragraphs are nonempty text blocks. Counts include unsaved edits.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.isPreviewTruncated {
                                Label("Partial document: counts cover the loaded preview only.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .monospacedDigit()
                        .padding(16)
                    }
                    .task(id: file) {
                        await monitor.sample(model: model, file: file)
                    }
                    .id(file)
                } else {
                    ContentUnavailableView("No Text Available", systemImage: "doc.text",
                                           description: Text("Statistics appear when the document is loaded."))
                }
            } else {
                ContentUnavailableView("Not a Compatible File", systemImage: "document.badge.gearshape.fill",
                                       description: Text("Open a .md or .txt file."))
            }
        }
    }
}
