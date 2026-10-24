import AppKit
import Defaults
import SwiftUI
import SyntaxFormat
import SyntaxParsers
internal import URLUtils

/// The editor options shared by every editor. The same controls sit in each
/// editor's options menu and in the Settings window; both write the same
/// user defaults, so a change in either place reaches every open editor.
struct EditorOptionsControls: View {
    @AppStorage(.editorShowsInvisibles) private var showsInvisibles: Bool
    @AppStorage(.editorShowsIndentGuides) private var showsIndentGuides: Bool
    @AppStorage(.editorShowsLineNumbers) private var showsLineNumbers: Bool
    @AppStorage(.editorShowsChanges) private var showsChanges: Bool
    @AppStorage(.editorWrapsLines) private var wrapsLines: Bool
    @AppStorage(.editorAutomaticCompletion) private var automaticCompletion: Bool
    @AppStorage(.editorUsesSpaces) private var usesSpaces: Bool
    @AppStorage(.editorTabWidth) private var tabWidth: Int

    var body: some View {
        Form {
            Section("Editor View") {
                Toggle("Show Invisibles", isOn: $showsInvisibles)
                Toggle("Show Indent Guides", isOn: $showsIndentGuides)
                Toggle("Show Line Numbers", isOn: $showsLineNumbers)
            }
            Section("Text & Lines") {
                Toggle("Show Changes", isOn: $showsChanges)
                Toggle("Wrap Lines", isOn: $wrapsLines)
                Toggle("Automatic Word Completion", isOn: $automaticCompletion)
                Toggle("Indent Using Spaces", isOn: $usesSpaces)
                Picker("Indent Width", selection: $tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

