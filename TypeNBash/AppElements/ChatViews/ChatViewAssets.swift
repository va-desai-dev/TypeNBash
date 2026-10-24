import SwiftUI
import SwiftData
import PhotosUI


struct ChatInputBar: View {
    @State private var inputPrompt: String = ""
    let sending: Bool
    let onSend: (String) -> Void
    // When generating, the send arrow becomes a Stop button that calls this. nil
    // keeps the old behavior (the arrow just disables while sending).
    var onStop: (() -> Void)? = nil
    // Group sessions allow sending with an empty draft: it yields the floor to
    // the selected speaker (a turn with no user message). 1:1 keeps the gate.
    var allowsEmptySend: Bool = false
    // No usable chat model: send stays dead and the screen's banner says why.
    var isBlocked: Bool = false
    // Optional control rendered inside the pill, just left of the send button
    // (e.g. the chat-mode tool menu). nil keeps the bar send-only.
    var trailingAccessory: AnyView? = nil

    // Focus belongs beside the TextField. The screen dismisses through the
    // responder chain and does not mirror this state in a second view.
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            TextField("Ask something…", text: $inputPrompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focused)
                .onKeyPress { press in
                    if press.key == .return && !press.modifiers.contains(.shift) {
                        submit()
                        return .handled
                    }
                    return .ignored
                }

            if let trailingAccessory {
                trailingAccessory
            }

            Group {
                if sending, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.foreground)
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(inputPrompt.isEmpty || isBlocked)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .padding(.vertical, 4)

        }
        .glassEffect(.clear.tint(Color.card.opacity(0.6)), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 18)
    }


    private func submit() {
        guard !sending, !isBlocked, !inputPrompt.isEmpty else { return }
        onSend(inputPrompt)
        inputPrompt = ""
    }
}


