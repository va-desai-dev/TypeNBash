import SwiftUI
import SwiftData

struct ChatComposerView: View {

    let sessionTitle: String
    let isSending: Bool
    // Built by the screen (which owns the web-search state) and rendered inside
    // the input pill next to send. nil in roleplay / when web search is off.
    var trailingAccessory: AnyView? = nil
    // The chat lane has no usable model, so sending can only fail. Passed down
    // to the input bar, which kills the send button; the screen renders a
    // ConnectionIssueBanner above this view saying which field is blank.
    var isBlocked: Bool = false
    let onSend: (String) -> Void
    // Abort the in-flight turn; surfaced as a Stop button while sending.
    var onStop: (() -> Void)? = nil


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatInputBar(
                sending: isSending,
                onSend: onSend,
                onStop: onStop,
                allowsEmptySend: false,
                isBlocked: isBlocked,
                trailingAccessory: trailingAccessory
            )
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// ENGRAIPrimitives — a menu group you render yourself, so rows can be colored.
struct ToolMenuGroup<Item: Identifiable, Label: View>: View {
    let items: [Item]
    let isActive: (Item) -> Bool
    let title: (Item) -> String
    let systemImage: (Item) -> String
    let action: (Item) -> Void
    @ViewBuilder let label: () -> Label   // the pill button in the input bar

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            action(item); open = false
                        } label: {
                            HStack {
                                Image(systemName: systemImage(item))
                                Text(title(item))
                                Spacer()
                                if isActive(item) {
                                    Image(systemName: "checkmark")
                                }
                            }
                            // ← the part a real Menu can't give you
                            .foregroundStyle(isActive(item) ? Color.accentColor
                                                             : Color.foreground)
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .presentationCompactAdaptation(.popover)
            }
    }
}
