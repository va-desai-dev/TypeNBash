//
//  HelpView.swift
//  TypeNBash
//

import SwiftUI
import WebKit

/// The user guide: the bundled website's guide page, in a window of its own.
struct HelpView: View {
    static let windowID = "help"
    static let menuTitle = " TypeNBash Help"

    @State private var page = HelpPage.make()

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewMagnificationGestures(.enabled)
    }
}

/// Replaces the default Help item so it opens this window. The Help menu
/// itself, and its search field, stay the system's.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            HelpMenuButton()
        }
    }
}

private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(HelpView.menuTitle, systemImage: "lightbulb") {
            openWindow(id: HelpView.windowID)
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut("?", modifiers: .command)
    }
}
