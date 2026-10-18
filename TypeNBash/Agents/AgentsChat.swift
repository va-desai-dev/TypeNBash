//
//  AgentsChat.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/26/26.
//

import SwiftUI

/// The agent pane: a transcript over a composer. `AgentSession` does the work;
/// this view forwards prompts, stop requests and the permission choice.
struct AgenticChatView: View {
    @Bindable var session: AgentSession
    @State private var composerHeight: CGFloat = 0

    var body: some View {
        ChatTranscriptView(messages: session.messages, barHeight: composerHeight) { message in
            MessageRow(message: message)
        }
        .overlay {
            if session.messages.isEmpty {
                ContentUnavailableView(
                    "Workspace Agent",
                    systemImage: "sparkles",
                    description: Text("Works in \(session.workingDirectory.lastPathComponent). Choose your model server in Settings → Agents.")
                )
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.providerTitle).lineLimit(1)
                    Spacer()
                    Button("New Chat", action: session.newConversation).disabled(session.isRunning)
                }
                if let error = session.persistenceError { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = session.configurationError { Text(error).font(.caption).foregroundStyle(.red) }
                if AgentBuildCapabilities.localCommands {
                    Toggle("Offer local commands (approval required)", isOn: $session.allowsCommands)
                        .font(.caption).disabled(session.isRunning)
                }
                if let approval = session.approval {
                    Text(approval.title).font(.headline)
                    ScrollView { Text(approval.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220)
                    HStack {
                        Button("Decline", role: .cancel) { session.resolveApproval(false) }
                        Button("Approve") { session.resolveApproval(true) }
                    }
                }
                if !session.changes.isEmpty {
                    DisclosureGroup("Workspace changes (\(session.changes.count))") {
                        ScrollView {
                            ForEach(session.changes) { change in
                                DisclosureGroup(change.path) {
                                    Text(change.review).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    if change.before != nil {
                                        Button("Revert This Edit") { session.revert(change) }.disabled(session.isRunning)
                                    }
                                }
                            }
                        }.frame(maxHeight: 200)
                    }.font(.caption)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.card)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerView(
                sessionTitle: session.workingDirectory.lastPathComponent,
                isSending: session.isRunning,
                trailingAccessory: AnyView(permissionMenu),
                onSend: session.send,
                onStop: session.stop
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                composerHeight = height
            }
        }
    }

    private var permissionMenu: some View {
        ToolMenuGroup(
            items: AgentPermissionMode.allCases,
            isActive: { $0 == session.permissionMode },
            title: \.title,
            systemImage: \.systemImage,
            action: { session.permissionMode = $0 }
        ) {
            Image(systemName: session.permissionMode.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .help("Permissions: \(session.permissionMode.title)")
        .disabled(session.isRunning)
    }
}
