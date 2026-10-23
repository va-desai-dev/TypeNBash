import AppKit
import SwiftUI
import Defaults
import TextFind

/// Keeps the editor's find notification bridge mounted even while its bar is closed.
struct EditorFindBar: View {
    let session: EditorSession
    @Bindable private var settings: TextFinderSettings = .shared
    @AppStorage(.findUsesRegularExpression) private var usesRegularExpression: Bool
    @AppStorage(.findIgnoresCase) private var ignoresCase: Bool
    @AppStorage(.findInSelection) private var inSelection: Bool
    @State private var showsReplace = false
    @State private var findFocus = 0
    @State private var replaceFocus = 0
    @State private var result: FindResult?
    @State private var showsResults = false
    @State private var resultModel = FindPanelResultView.Model()
    @State private var showObserver: NotificationCenter.ObservationToken?
    @State private var resultObserver: NotificationCenter.ObservationToken?
    @State private var allResultsObserver: NotificationCenter.ObservationToken?

    var body: some View {
        VStack(spacing: 0) {
            if session.isFindBarPresented {
                // Fields in one column, actions in another. The action column is pinned to
                // its widest row's natural width and every row's buttons stretch to fill it,
                // so both fields end at the same x and the buttons sit flush with them.
                HStack(spacing: 6) {
                    VStack(spacing: 4) {
                        FindField(text: $settings.findString, placeholder: "Find", systemImage: "magnifyingglass",
                                  identifier: "editor.search.query",
                                  message: result?.action == .find ? (result?.positionMessage ?? result?.message) : nil,
                                  focusRequest: session.findFocusRequest + findFocus,
                                  onSubmit: { session.performFind(NSEvent.modifierFlags.contains(.shift) ? .previousMatch : .nextMatch) },
                                  onDismiss: session.dismissFind) {
                            modeMenu
                        } trailing: {
                            MatchCaseToggle(ignoresCase: $ignoresCase)
                            Divider().opacity(0.5)
                            optionsMenu
                        }
                        if showsReplace {
                            FindField(text: $settings.replacementString, placeholder: "Replace with", systemImage: "pencil",
                                      identifier: "search.replacement",
                                      message: result?.action == .replace ? result?.message : nil,
                                      focusRequest: replaceFocus,
                                      onSubmit: { session.performFind(.replaceAndFind) },
                                      onDismiss: session.dismissFind) {
                                Text("With")
                            } trailing: {
                                optionsMenu
                            }
                            .disabled(settings.findString.isEmpty)
                        }
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            navigationButtons
                            if !resultModel.matches.isEmpty { resultsButton }
                            Button(action: session.dismissFind) { Text("Done").fillsFindRow() }
                                .buttonStyle(.accessoryBar)
                                .help("Close find bar (⎋)")
                                .accessibilityLabel("Close Find Bar")
                        }
                        .frame(height: FindBarContent.rowHeight)
                        if showsReplace {
                            ControlGroup {
                                Button { session.performFind(.replaceAndFind) } label: { Text("Replace").fillsFindRow() }
                                    .help("Replace this match, then find the next one.")
                                Button { session.performFind(.replaceAll) } label: { Text("All").fillsFindRow() }
                                    .help("Replace every match.")
                            }
                            .buttonStyle(.bordered)
                            .frame(height: FindBarContent.rowHeight)
                            .disabled(settings.findString.isEmpty)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .modifier(FindBarContent())
                .onExitCommand(perform: session.dismissFind)
                .onAppear { findFocus += 1 }
                Divider()
            }
        }
        .onChange(of: settings.findString) {
            result = nil
            guard session.isFindBarPresented, settings.shouldSearchIncrementally,
                  session.textView?.window?.isKeyWindow == true else { return }
            session.incrementalSearch()
        }
        .onChange(of: settings.replacementString) {
            if result?.action == .replace { result = nil }
        }
        .onChange(of: session.isFindBarPresented) {
            if !session.isFindBarPresented {
                showsReplace = false
                result = nil
                resultModel = FindPanelResultView.Model()
                showsResults = false
            }
        }
        .onAppear {
            guard showObserver == nil else { return }
            showObserver = NotificationCenter.default.addObserver(for: TextFinder.ShowFindInterfaceMessage.self) { message in
                guard let client = message.client, client === session.textView else { return }
                session.find()
            }
            resultObserver = NotificationCenter.default.addObserver(for: TextFinder.DidFindMessage.self) { message in
                guard session.isFindBarPresented, let textView = session.textView,
                      message.clientIdentifier == ObjectIdentifier(textView) else { return }
                result = message.result
            }
            allResultsObserver = NotificationCenter.default.addObserver(for: TextFinder.DidFindAllMessage.self) { message in
                guard session.isFindBarPresented, let client = message.client, client === session.textView else { return }
                resultModel.matches = message.matches
                resultModel.findString = message.findString
                resultModel.target = client
                showsResults = !message.matches.isEmpty
            }
        }
        .onDisappear {
            showObserver = nil
            resultObserver = nil
            allResultsObserver = nil
        }
    }

    private var modeMenu: some View {
        FindModeMenu(findString: $settings.findString, showsReplace: $showsReplace) { replacing in
            if replacing { replaceFocus += 1 } else { findFocus += 1 }
        }
    }

    private var optionsMenu: some View {
        FindOptionsMenu(usesRegularExpression: $usesRegularExpression) {
            Button("Find All") { session.performFind(.findAll) }
            Button("Highlight All") { session.performFind(.highlight) }
            Button("Select All Matches") { session.performFind(.selectAll) }
            Button("Remove Highlights") { session.performFind(.unhighlight) }
            Toggle("Search In Selection Only", isOn: $inSelection)
        } settings: {
            FindSettingsView()
        }
    }

    private var resultsButton: some View {
        Button { showsResults.toggle() } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .help("Show the Find All results.")
        .accessibilityLabel("Find All Results")
        .popover(isPresented: $showsResults, arrowEdge: .bottom) {
            FindPanelResultView(model: resultModel) { showsResults = false }
                .frame(width: 560, height: 280).padding(.bottom, 8)
        }
    }

    private var navigationButtons: some View {
        ControlGroup {
            Button { session.performFind(.previousMatch) } label: { Image(systemName: "chevron.left").fillsFindRow() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Find the previous match (⇧⌘G)").accessibilityLabel("Find Previous")
            Button { session.performFind(.nextMatch) } label: { Image(systemName: "chevron.right").fillsFindRow() }
                .keyboardShortcut("g", modifiers: .command)
                .help("Find the next match (⌘G)").accessibilityLabel("Find Next")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(settings.findString.isEmpty)
    }
}
