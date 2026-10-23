//
//  ProjectSearchFileRow.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/22/26.
//


//
//  ProjectSearchFileRow.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/22/26.
//
import AppKit
import Foundation
import SwiftUI

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
            FileListRow(filename: file.label, icon: file.icon, style: .secondary, tag: file.url) {
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
