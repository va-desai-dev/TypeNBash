import AppKit
import SwiftUI
import Defaults

// Find & Replace items shared by every pane. Each pane arranges them into its own
// rows inside `FindBarContent`; nothing here knows which pane it sits in.

/// One bordered input row: icon and label, the native find input, an optional
/// status message, a clear button, then whatever trailing items the caller adds.
struct FindField<Label: View, Trailing: View>: View {
    @Binding var text: String
    let isCompact: Bool
    let placeholder: String
    let systemImage: String?
    let identifier: String
    let message: String?
    let focusRequest: Int
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    let label: Label?
    let trailing: Trailing

    init(text: Binding<String>, isCompact: Bool = false, placeholder: String, systemImage: String? = nil, identifier: String,
         message: String? = nil, focusRequest: Int = 0,
         onSubmit: @escaping () -> Void, onDismiss: @escaping () -> Void,
         @ViewBuilder label: () -> Label?, @ViewBuilder trailing: () -> Trailing) {
        _text = text
        self.isCompact = isCompact
        self.placeholder = placeholder
        self.systemImage = systemImage
        self.identifier = identifier
        self.message = message
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            if !isCompact {
                HStack(spacing: 3) {
                    Image(systemName: systemImage ?? "").foregroundStyle(.secondary)
                    label
                }
                .frame(width: FindBarContent.labelWidth, alignment: .leading)
                Divider().opacity(0.5)
            }
            // Fixed so every field's input starts at the same x, across rows and panes.
            FindInput(text: $text, placeholder: placeholder, focusRequest: focusRequest,
                      identifier: identifier, onSubmit: onSubmit, onDismiss: onDismiss)
                .frame(maxWidth: .infinity)
            if let message {
                Text(message).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear Text")
            }
            // Dividers sit directly in this row so they run the field's full height.
            // Callers separate their own trailing items with `Divider()` the same way.
            if Trailing.self != EmptyView.self {
                Divider().opacity(0.5)
                trailing
            }
        }
        .padding(.horizontal, 4)
        .frame(height: FindBarContent.rowHeight)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

extension FindField where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, systemImage: String, identifier: String,
         message: String? = nil, focusRequest: Int = 0,
         onSubmit: @escaping () -> Void, onDismiss: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.init(text: text, placeholder: placeholder, systemImage: systemImage, identifier: identifier,
                  message: message, focusRequest: focusRequest, onSubmit: onSubmit, onDismiss: onDismiss,
                  label: label) { EmptyView() }
    }
}
