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
    let session: AgentSession
    @State private var composerHeight: CGFloat = 0

    var body: some View {
        ChatTranscriptView(messages: session.messages, barHeight: composerHeight) { message in
            MessageRow(message: message)
        }
        .overlay {
            if session.messages.isEmpty {
                ContentUnavailableView(
                    "Claude Code",
                    systemImage: "terminal",
                    description: Text("Works in \(session.workingDirectory.lastPathComponent)")
                )
            }
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
    }
}
