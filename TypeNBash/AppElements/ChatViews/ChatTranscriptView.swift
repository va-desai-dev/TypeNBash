import SwiftUI
import SwiftData

/// Owns the transcript's bottom-pinned presentation invariant.
/// The screen supplies rows; this view keeps the semantic tail visible whenever
/// content, the keyboard viewport, or the native composer bar changes.
struct ChatTranscriptView<RowContent: View>: View {
    let messages: [ChatMessage]
    let isWaiting: Bool? = false
    let barHeight: CGFloat
    @ViewBuilder let rowContent: (ChatMessage) -> RowContent

    private var revision: TailRevision {
        TailRevision(
            contentLength: (messages.last?.blocks.count ?? 0) + (messages.last?.liveText.count ?? 0),
            thinkingLength: messages.last?.liveReasoning.count ?? 0,
            isWaiting: isWaiting ?? false
        )
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { message in
                            rowContent(message)
                        }

                        if isWaiting ?? false {
                            WaitingForModelRow()
                        }

                        // A concrete semantic tail gives ScrollViewReader an exact
                        // destination even while LazyVStack realizes distant rows.
                        Color.clear
                            .frame(height: 1)
                            .id(TranscriptAnchor.tail)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .contentMargins(.top, 6, for: .scrollContent)
                .contentMargins(.bottom, 6, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .task(id: scrollRequest(in: viewport.size)) {
                    // Yield once so LazyVStack and the native safe-area bar finish
                    // the same layout pass. This is scheduling, not a timed retry.
                    await Task.yield()
                    scrollToTail(using: scrollProxy)
                }
            }
        }
    }

    private func scrollRequest(in viewportSize: CGSize) -> ScrollRequest {
        ScrollRequest(
            revision: revision,
            viewportSize: viewportSize,
            barHeight: barHeight
        )
    }

    private func scrollToTail(using proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(TranscriptAnchor.tail, anchor: .bottom)
        }
    }
}

private enum TranscriptAnchor: Hashable {
    case tail
}

private struct TailRevision: Hashable {
    let contentLength: Int
    let thinkingLength: Int
    let isWaiting: Bool
}

private struct ScrollRequest: Hashable {
    let revision: TailRevision
    let viewportSize: CGSize
    let barHeight: CGFloat
}

private struct WaitingForModelRow: View {

    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("Waiting for model…")
                .font(.caption)
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
        }
    }
}
