import AppKit
import Defaults
import SwiftUI

/// The shell around every pane's find rows: font, control size, padding, background.
/// Pane headers and footers keep their own `PaneBar` contract.
struct FindBarContent: ViewModifier {
    static var font: NSFont { .preferredFont(forTextStyle: .body) }
    /// Every find row is this tall whatever sits beside the field, so rows in
    /// neighbouring panes line up.
    static var rowHeight: CGFloat { 24 }
    /// Width of a field's icon and label ("Find", "Replace", "With").
    static var labelWidth: CGFloat { 80 }

    func body(content: Content) -> some View {
        content
            .font(Font(Self.font))
            .controlSize(.small)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card)
    }
}

extension View {
    /// For a bordered button's label in a find row. The bezel is drawn behind the
    /// label, so a flexible label makes the button run the row's full height and
    /// share any spare width with its neighbours.
    func fillsFindRow() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Switches between Find and Replace and offers recent searches.
/// `onSelect` receives `true` for Replace so the caller can move focus.
struct FindModeMenu: View {
    let showsChevron: Bool
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
            HStack(alignment: .center, spacing: 8) {
                Text(showsReplace ? "Replace" : "Find")
                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
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
            HStack(alignment: .center, spacing: 10) {
                Text("Options")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
        }
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("More find options")
        .accessibilityLabel("More Find Options")
        .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
            settings.scenePadding()
        }
    }
}


//Specially for Project wide text search navigator eyebrows

struct ProjectFindModeMenu: View {
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
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.navigator(icon: ""))
        .help("Find and replace")
        .accessibilityLabel("Change mode")
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
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.navigator(icon: ""))
        .help("Find content options")
        .accessibilityLabel("Find Content Options")
    }
}

struct ProjectSearchOptionButton<Settings: View>: View {
    let settings: Settings
    @State private var showsSettings = false
    @Binding var ignoresCase: Bool
    let dismiss: () -> Void


    init(
        ignoresCase: Binding<Bool>,
        dismiss: @escaping () -> Void,
        @ViewBuilder settings: () -> Settings
    ) {
        self._ignoresCase = ignoresCase
        self.settings = settings()
        self.dismiss = dismiss
    }

    private var innerLayMenu: some View {
        Menu {
            settings.scenePadding()
        } label: {
            Label("Advanced Find Options…", systemImage: "gear")
                .foregroundStyle(.foreground)
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help("More find options")
        .accessibilityLabel("More Find Options")
    }

    var body: some View {
        ControlGroup {
            innerLayMenu
            Toggle(isOn: Binding(get: { !ignoresCase }, set: { ignoresCase = !$0 })) {
                Text("Aa")
                    .font(.system(size: 8))
            }
            .toggleStyle(.button)
            .help("Match the case of the search text.")
            .accessibilityLabel("Match Case")
        }
        .controlSize(.regular)
    }
}
