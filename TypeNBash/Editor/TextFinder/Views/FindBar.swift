//
//  FindBar.swift
//
//  TypeNBash
//
//  A thin inline Find & Replace bar for the editor pane, in place of
//  CotEditor's floating find panel. Everything it drives goes through one
//  `EditorSession`, so a search belongs to the editor it was started from
//  rather than to whatever text view the application-wide responder chain
//  happens to reach.
//

import AppKit
import SwiftUI
import Defaults
import TextFind

/// Hosts the find bar for one editor.
///
/// Stays mounted while the bar is hidden: this is what listens for the text
/// view asking for the find interface (⌘F), so there has to be something
/// present before the bar exists.
struct EditorFindBar: View {

    let session: EditorSession

    @State private var showObserver: NotificationCenter.ObservationToken?

    var body: some View {
        VStack(spacing: 0) {
            if session.isFindBarPresented {
                FindBar(session: session)
                Divider()
            }
        }
        .onAppear {
            guard self.showObserver == nil else { return }
            self.showObserver = NotificationCenter.default.addObserver(for: TextFinder.ShowFindInterfaceMessage.self) { message in
                // Every editor observes; only the one that was asked responds.
                guard let client = message.client, client === self.session.textView else { return }
                self.session.find()
            }
        }
        .onDisappear {
            self.showObserver = nil
        }
    }
}


// MARK: -

private struct FindBar: View {

    let session: EditorSession


    @Bindable private var settings: TextFinderSettings = .shared

    @AppStorage(.findUsesRegularExpression) private var usesRegularExpression: Bool
    @AppStorage(.findIgnoresCase) private var ignoresCase: Bool
    @AppStorage(.findInSelection) private var inSelection: Bool

    @State private var showsReplace = false
    @State private var result: FindResult?
    @State private var isPressingShift = false
    @State private var isSettingsPresented = false
    @State private var isRegexReferencePresented = false
    @State private var isResultPresented = false
    @State private var resultModel = FindPanelResultView.Model()
    @State private var didFindObserver: NotificationCenter.ObservationToken?
    @State private var didFindAllObserver: NotificationCenter.ObservationToken?
    @FocusState private var focus: Field?

    private enum Field { case find, replace }

    /// Caps the text fields so the bar reads as a search box with controls
    /// beside it rather than one field stretched across a wide window.
    private static let fieldWidth: Double = 80


    // MARK: View

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                findField(prompt: "Find",
                      text: $settings.findString, target: .find,
                      message: self.findMessage, history: .findHistory)
                .onSubmit {
                    self.session.performFind(self.isPressingShift ? .previousMatch : .nextMatch)
                }
                .onModifierKeysChanged(mask: .shift) { _, new in
                    self.isPressingShift = new.contains(.shift)
                }
                navigationButtons
                resultsButton
                Button {
                    self.session.dismissFind()
                } label: {
                    Text("Done")
                }
                .buttonStyle(.bordered)
                .help("Close find bar (⎋)")
                .accessibilityLabel("Close Find Bar")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)

            if self.showsReplace {
                HStack(spacing: 6) {
                    replaceField(prompt: "Replace with",
                          text: $settings.replacementString, target: .replace,
                          message: self.replaceMessage, history: .replaceHistory)
                    .onSubmit { self.session.performFind(.replaceAndFind) }
                    ControlGroup {
                        Button("Replace") { self.session.performFind(.replaceAndFind) }
                            .buttonStyle(.bordered)
                            .help("Replace this match, then find the next one.")
                        Button("All") { self.session.performFind(.replaceAll) }
                            .buttonStyle(.bordered)
                            .help("Replace every match.")
                    }
                }
                .disabled(self.settings.findString.isEmpty)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.card)
        .onExitCommand { self.session.dismissFind() }
        .onAppear { self.focus = .find }
        .onChange(of: self.session.findFocusRequest) { self.focus = .find }
        .onChange(of: self.settings.findString) {
            self.result = nil

            // The settings object is app-wide, so a keystroke in one window
            // reaches every open bar. Only the window being typed in searches.
            guard self.settings.shouldSearchIncrementally,
                  self.session.textView?.window?.isKeyWindow == true
                    else { return }

            self.session.incrementalSearch()
        }
        .onChange(of: self.settings.replacementString) {
            if self.result?.action == .replace { self.result = nil }
        }
        .onAppear {
            guard self.didFindObserver == nil else { return }
            self.didFindObserver = NotificationCenter.default.addObserver(for: TextFinder.DidFindMessage.self) { message in
                guard let textView = self.session.textView,
                      message.clientIdentifier == ObjectIdentifier(textView)
                        else { return }
                self.result = message.result
            }
            self.didFindAllObserver = NotificationCenter.default.addObserver(for: TextFinder.DidFindAllMessage.self) { message in
                guard let client = message.client, client === self.session.textView else { return }
                self.resultModel.matches = message.matches
                self.resultModel.findString = message.findString
                self.resultModel.target = client
                self.isResultPresented = !message.matches.isEmpty
            }
        }
        .onDisappear {
            self.didFindObserver = nil
            self.didFindAllObserver = nil
        }
    }

    /// The leading menu in a field: switches between Find and Replace, and
    /// recalls a previous entry for whichever field it belongs to.
    private func modeMenu(text: Binding<String>, history: DefaultKey<[String]>) -> some View {
        Menu {
            Button("Find") {
                self.showsReplace = false
                self.focus = .find
            }
            Button("Replace") {
                self.showsReplace = true
                self.focus = .replace
            }
            Divider()
            self.recentsItems(text: text, history: history)
        } label: {
            Text(self.showsReplace ? "Replace" : "Find")
        }
        .menuIndicator(.automatic)
        .help(self.showsReplace ? "Show the search field" : "Show the replacement field")
        .accessibilityLabel("Change mode")
    }


    /// The stored history for one field, as menu items that refill it.
    @ViewBuilder private func recentsItems(text: Binding<String>, history: DefaultKey<[String]>) -> some View {
        let histories = UserDefaults.standard[history]

        if histories.isEmpty {
            Text("No Recents")
        } else {
            Text("Recent Searches").foregroundStyle(.secondary)
            ForEach(histories, id: \.self) { string in
                Button {
                    text.wrappedValue = string
                } label: {
                    // Long patterns would otherwise stretch the menu.
                    Text(verbatim: string.count <= 64 ? string : String(string.prefix(64)) + "…")
                }
                .help(string)
            }
            Divider()
            Button("Clear Recents", systemImage: "trash") {
                UserDefaults.standard.removeObject(forKey: history.rawValue)
            }
        }
    }

    /// One rounded field: history menu, the text itself, the match count, and a clear button.
    private func replaceField(prompt: LocalizedStringKey,
                              text: Binding<String>, target: Field,
                              message: String?, history: DefaultKey<[String]>) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                Text("With")
            }
            .frame(
                width: FindBar.fieldWidth,
                alignment: .init(horizontal: .leading, vertical: .center)
            )
            Divider()
            TextField(prompt, text: text)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($focus, equals: target)

            if let message {
                Text(message)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear")
            }
            Divider()
            moreMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }

    /// One rounded field: history menu, the text itself, the match count, and a clear button.
    private func findField(prompt: LocalizedStringKey,
                           text: Binding<String>, target: Field,
                           message: String?, history: DefaultKey<[String]>) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    self.modeMenu(text: text, history: history)
            }
            .frame(
                width: FindBar.fieldWidth,
                alignment: .init(horizontal: .leading, vertical: .center)
            )
            Divider()
            TextField(prompt, text: text)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($focus, equals: target)

            if let message {
                Text(message)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear")
            }
            Divider()
            optionToggles
            Divider()
            moreMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }


    private var navigationButtons: some View {
        ControlGroup {
            Button {
                self.session.performFind(.previousMatch)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Find the previous match (⇧⌘G)")
            .accessibilityLabel("Find Previous")

            Button {
                self.session.performFind(.nextMatch)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("g", modifiers: .command)
            .help("Find the next match (⌘G)")
            .accessibilityLabel("Find Next")
        }
        .controlSize(.regular)
        .disabled(self.settings.findString.isEmpty)
    }


    private var optionToggles: some View {
        HStack(spacing: 2) {
            // The stored setting is the negative one, so the button reads as
            // "match case" while the default it writes stays `findIgnoresCase`.
            Toggle(isOn: Binding(get: { !self.ignoresCase }, set: { self.ignoresCase = !$0 })) {
                Text("Aa")
            }
            .foregroundStyle(self.ignoresCase ? .secondary : Color.yellow)
            .help("Match the case of the search text.")
            .accessibilityLabel("Match Case")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
    }


    /// Opens the Find All result list. Present only once there is a list to show.
    @ViewBuilder private var resultsButton: some View {
        if !self.resultModel.matches.isEmpty {
            Button {
                self.isResultPresented.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("Show the Find All results.")
            .accessibilityLabel("Find All Results")
            .popover(isPresented: $isResultPresented, arrowEdge: .bottom) {
                FindPanelResultView(model: self.resultModel) {
                    self.isResultPresented = false
                }
                .frame(width: 560, height: 280)
                .padding(.bottom, 8)
            }
        }
    }


    private var moreMenu: some View {
        Menu {
            Button("Find All") { self.session.performFind(.findAll) }
            Button("Highlight All") { self.session.performFind(.highlight) }
            Button("Select All Matches") { self.session.performFind(.selectAll) }
            Button("Remove Highlights") { self.session.performFind(.unhighlight) }
            Toggle("Search In Selection Only", isOn: $inSelection)
            Button("Advanced Find Options…") { self.isSettingsPresented = true }
            Divider()
            Toggle(isOn: $usesRegularExpression) {
                Text("Regular Expression")
            }
            .help("Search with a regular expression. ⌥-click for the syntax reference.")
            .accessibilityLabel("Regular Expression")
            .toggleStyle(.button)
        } label: {
            Label("Options", systemImage: "chevron.up.chevron.down")
        }
        .menuIndicator(.hidden)
        .help("More find options")
        .accessibilityLabel("More Find Options")
        .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
            FindSettingsView()
                .scenePadding()
        }
    }


    // MARK: Private Methods

    /// The match position or count shown inside the find field.
    private var findMessage: String? {
        guard let result, result.action == .find else { return nil }
        return result.positionMessage ?? result.message
    }


    /// The replacement count shown inside the replacement field.
    private var replaceMessage: String? {
        guard let result, result.action == .replace else { return nil }
        return result.message
    }
}
