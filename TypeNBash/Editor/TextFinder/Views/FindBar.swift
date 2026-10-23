import AppKit
import SwiftUI
import Defaults

// Find & Replace items shared by every pane. Each pane arranges them into its own
// rows inside `FindBarContent`; nothing here knows which pane it sits in.

/// One bordered input row: icon and label, the native find input, an optional
/// status message, a clear button, then whatever trailing items the caller adds.
struct FindField<Label: View, Trailing: View>: View {
    @Binding var text: String
    let isCompact: Bool
    let placeholder: String
    let systemImage: String?
    let identifier: String
    let message: String?
    let focusRequest: Int
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    let label: Label?
    let trailing: Trailing

    init(text: Binding<String>, isCompact: Bool = false, placeholder: String, systemImage: String? = nil, identifier: String,
         message: String? = nil, focusRequest: Int = 0,
         onSubmit: @escaping () -> Void, onDismiss: @escaping () -> Void,
         @ViewBuilder label: () -> Label?, @ViewBuilder trailing: () -> Trailing) {
        _text = text
        self.isCompact = isCompact
        self.placeholder = placeholder
        self.systemImage = systemImage
        self.identifier = identifier
        self.message = message
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            if !isCompact {
                HStack(spacing: 3) {
                    Image(systemName: systemImage ?? "").foregroundStyle(.secondary)
                    label
                }
                .frame(width: FindBarContent.labelWidth, alignment: .leading)
                Divider().opacity(0.5)
            }
            // Fixed so every field's input starts at the same x, across rows and panes.
            FindInput(text: $text, placeholder: placeholder, focusRequest: focusRequest,
                      identifier: identifier, onSubmit: onSubmit, onDismiss: onDismiss)
                .frame(maxWidth: .infinity)
            if let message {
                Text(message).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear Text")
            }
            // Dividers sit directly in this row so they run the field's full height.
            // Callers separate their own trailing items with `Divider()` the same way.
            if Trailing.self != EmptyView.self {
                Divider().opacity(0.5)
                trailing
            }
        }
        .padding(.horizontal, 4)
        .frame(height: FindBarContent.rowHeight)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

extension FindField where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, systemImage: String, identifier: String,
         message: String? = nil, focusRequest: Int = 0,
         onSubmit: @escaping () -> Void, onDismiss: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.init(text: text, placeholder: placeholder, systemImage: systemImage, identifier: identifier,
                  message: message, focusRequest: focusRequest, onSubmit: onSubmit, onDismiss: onDismiss,
                  label: label) { EmptyView() }
    }
}

/// Switches between Find and Replace and offers recent searches.
/// `onSelect` receives `true` for Replace so the caller can move focus.
struct FindModeMenu: View {
    @Binding var findString: String
    @Binding var showsReplace: Bool
    let onSelect: (_ replacing: Bool) -> Void

    var body: some View {
        Menu {
            Button("Find") { showsReplace = false; onSelect(false) }
            Button("Replace") { showsReplace = true; onSelect(true) }
            Divider().opacity(0.5)
            let history = UserDefaults.standard[.findHistory]
            if history.isEmpty {
                Text("No Recents")
            } else {
                Text("Recent Searches")
                ForEach(history, id: \.self) { string in
                    Button { findString = string } label: {
                        Text(verbatim: string.count <= 64 ? string : String(string.prefix(64)) + "…")
                    }.help(string)
                }
                Divider()
                Button("Clear Recents", systemImage: "trash") {
                    UserDefaults.standard.removeObject(forKey: DefaultKeys.findHistory.rawValue)
                }
            }
        } label: {
            Text(showsReplace ? "Replace" : "Find")
        }
        .menuIndicator(.automatic)
        .menuStyle(.borderlessButton)
        .help("Find and replace")
        .accessibilityLabel("Change mode")
    }
}

struct MatchCaseToggle: View {
    @Binding var ignoresCase: Bool

    var body: some View {
        Toggle("Aa", isOn: Binding(get: { !ignoresCase }, set: { ignoresCase = !$0 }))
            .foregroundStyle(ignoresCase ? .secondary : Color.yellow)
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Match the case of the search text.")
            .accessibilityLabel("Match Case")
    }
}

/// Pane-specific `options` first, then the options every pane shares.
/// The Advanced Find Options popover anchors to this menu, not to the whole bar.
struct FindOptionsMenu<Options: View, Settings: View>: View {
    @Binding var usesRegularExpression: Bool
    let options: Options
    let settings: Settings
    @State private var showsSettings = false

    init(usesRegularExpression: Binding<Bool>,
         @ViewBuilder options: () -> Options, @ViewBuilder settings: () -> Settings) {
        _usesRegularExpression = usesRegularExpression
        self.options = options()
        self.settings = settings()
    }

    var body: some View {
        Menu {
            options
            Button("Advanced Find Options…") { showsSettings = true }
            Divider()
            Toggle("Regular Expression", isOn: $usesRegularExpression)
                .help("Search with a regular expression.")
        } label: {
            Label("Options", systemImage: "chevron.up.chevron.down")
        }
        .menuIndicator(.hidden)
        .help("More find options")
        .accessibilityLabel("More Find Options")
        .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
            settings.scenePadding()
        }
    }
}

struct ProjectSearchTypeMenu: View {
    @Binding var usesRegularExpression: Bool
    @State private var showsPopover = false

    init(usesRegularExpression: Binding<Bool>) {
        _usesRegularExpression = usesRegularExpression
    }

    var contentTypeLabel: String {
        if usesRegularExpression {
            return "RegEx"
        } else {
            return "Text"
        }
    }

    var body: some View {
        Menu {
            Button("Text") { usesRegularExpression = false }
                .help("Search with a plain text.")
            Button("Regular Expression") { usesRegularExpression = true }
                .help("Search with a regular expression.")
        } label: {
            Text(contentTypeLabel)
        }
        .menuIndicator(.automatic)
        .menuStyle(.borderlessButton)
        .help("Find content options")
        .accessibilityLabel("Find Content Options")
    }
}

struct ProjectSearchOptionButton<Settings: View>: View {
    let settings: Settings
    @State private var showsSettings = false

    init(@ViewBuilder settings: () -> Settings) {
        self.settings = settings()
    }
    var body: some View {
        Button { showsSettings = true } label: {
            Label("Advanced Find Options…", systemImage: "gear")
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .tint(.secondary)
        .buttonStyle(.borderless)
        .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
            settings.scenePadding()
        }
        .help("More find options")
        .accessibilityLabel("More Find Options")
    }
}
