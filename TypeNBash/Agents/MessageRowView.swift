//
//  MessageRow.swift
//  ENGRAI
//
//  Created by Vedant A. Desai on 7/4/26.
//
import SwiftUI

// ── Message row: name tag, then the turn's blocks in the order they arrived ──
struct MessageRow: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(isUser ? "YOU" : "AGENT")
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)

            ForEach(message.blocks) { block in
                switch block.kind {
                case .text(let text): markdown(text)
                case .reasoning(let text): ReasoningPanel(text: text, isThinking: false)
                case .tool(let tool): ToolActivityRow(tool: tool)
                }
            }

            if !message.liveReasoning.isEmpty {
                ReasoningPanel(text: message.liveReasoning, isThinking: message.isThinking)
            } else if message.isThinking {
                ReasoningIndicator(isThinking: true)
            }
            if !message.liveText.isEmpty {
                markdown(message.liveText)
            }
            if message.isStreaming, message.blocks.isEmpty, message.liveText.isEmpty, !message.isThinking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 4)
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            if let footnote = message.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                    .padding(.horizontal, 4)
            }
        }
    }

    private func markdown(_ text: String) -> some View {
        MarkdownTextView(text, foreground: Color.foreground, accent: Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }
}

// ── Tool activity ───────────────────────────────────────────────────────────
// One tool call: what it acted on, then its output once the CLI reports it.
private struct ToolActivityRow: View {
    let tool: ToolActivity

    private var statusImage: String {
        if tool.isError { return "xmark.circle" }
        return tool.output == nil ? "circle.dotted" : "checkmark.circle"
    }

    var body: some View {
        DisclosureGroup {
            ScrollView {
                Text(tool.output ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tool.isError ? Color.red : Color(NSColor.secondaryLabelColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(Color.card, in: .rect(cornerRadius: 8))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: statusImage)
                    .foregroundStyle(tool.isError ? Color.red : Color(NSColor.secondaryLabelColor))
                Text(tool.name)
                    .fontWeight(.medium)
                Text(tool.detail)
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
        }
        .disabled(tool.output?.isEmpty ?? true)
        .padding(.horizontal, 4)
    }
}

enum MarkdownText {
    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// ── Reasoning panel ─────────────────────────────────────────────────────────
// Collapsible display of captured model reasoning. Collapsed by default; the
// reader taps the header to expand or collapse it.
private struct ReasoningPanel: View {
    let text: String
    let isThinking: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text(isThinking ? "Thinking…" : "Reasoning")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .symbolEffect(
                    .pulse,
                    isActive: isThinking
                )
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.card, in: .rect(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct ReasoningIndicator: View {
    let isThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                Text(isThinking ? "Thinking…" : "Overthought.")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color(NSColor.secondaryLabelColor))
            .symbolEffect(
                .pulse,
                isActive: isThinking
            )
        }
        .padding(.horizontal, 4)
    }
}
