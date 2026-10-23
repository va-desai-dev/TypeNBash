import SwiftUI

struct ProjectReplacementReviewView: View {
    let model: ProjectSearchModel
    let review: ProjectReplacementReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace \(review.count) matches in \(review.replacements.count) files?").font(.headline)
            Text("Closed files are saved immediately. The open document keeps its changes unsaved. Files that changed since the search will be skipped.")
                .font(.callout).foregroundStyle(.secondary)
            List(review.replacements) { replacement in
                Section(replacement.file.path) {
                    ForEach(replacement.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Line \(change.match.line)").foregroundStyle(.secondary)
                            let original = (replacement.file.text as NSString).substring(with: change.match.range)
                            Text("− " + String(original.prefix(300))).foregroundStyle(.red)
                            Text("+ " + String(change.replacement.prefix(300))).foregroundStyle(.green)
                            if original.count > 300 || change.replacement.count > 300 {
                                DisclosureGroup("Show full replacement") {
                                    Text("− " + original).foregroundStyle(.red)
                                    Text("+ " + change.replacement).foregroundStyle(.green)
                                }
                            }
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace") {
                    dismiss()
                    Task { await model.apply(review) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 650, height: 480)
    }
}
