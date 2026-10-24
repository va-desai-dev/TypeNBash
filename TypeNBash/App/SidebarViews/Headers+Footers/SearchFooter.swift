//
//  FileSearchView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/23/26.
//

import SwiftUI

/// The sidebar footer's filter field, like Xcode's navigator filter: it narrows
/// the current tab's list — the file tree, Find results or Changes — to names
/// containing the text. The filtering itself lives in each tab's model.
struct BrowserSearchInput: View {
    @Binding var text: String
    let placeholder: String
    /// Hides the field; the caller owns whether it's shown.
    let onDismiss: () -> Void


    var body: some View {
        HStack {
            FindInput(
                text: $text,
                placeholder: placeholder,
                focusRequest: 1,
                identifier: "fileBrowser.filter",
                onSubmit: { },
                onDismiss: onDismiss
            )
            .frame(maxWidth: .infinity)
            Spacer()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear Text")
            }
        }
        .onExitCommand(perform: onDismiss)
        .padding(.leading, 4)
        .padding(.trailing, 7)
        .frame(height: 28)
        .glassEffect()
    }
}
