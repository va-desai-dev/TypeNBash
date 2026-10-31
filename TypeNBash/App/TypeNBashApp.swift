//
//  TypeNBashApp.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

import Defaults
import SwiftUI

// 1. This reads your Xcode Organizer version automatically
public struct AppVersion {
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    }
}


@main
struct TypeNBashApp: App {
    @State private var windows = WorkspaceWindows()
    @State private var citeTex = CiteTexTargets.shared

    init() {
        AppDefaults.register()
        #if DIRECT_DISTRIBUTION && !APP_STORE
        _ = AppUpdater.controller  // starts Sparkle's scheduled checks at launch
        #endif
    }

    var body: some Scene {
        Window("TypeNBash", id: WorkspaceWindows.welcomeID) {
            EntryView(windows: windows)
                .tint(Color.accentColor)
        }
        .commandsRemoved()
        .windowLevel(.floating)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                WelcomeWindowCommand()
            }
            CommandGroup(after: .newItem, addition: {
                SSHOpenCommand(windows: windows)
            })
            CommandGroup(after: .newItem, addition: {
                ProjectNewCommand(windows: windows)
            })
        }
        WindowGroup(
            id: WorkspaceWindows.workspaceID,
            for: UUID.self
        ) { $id in
            if let id, let router = windows.sessions[id] {
                ContentView(router: router)
                    .tint(Color.accentColor)
                    .foregroundStyle(Color.foreground)
                    .onDisappear { windows.close(id) }
                    .navigationTitle(windows.workspaceName(router))
            }
        }
        .commands {
            TextEditingCommands()
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { ProjectCommands() }
        // The bundled website's guide; its own styles set the look.
        Window(HelpView.menuTitle, id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 920, height: 640)
        .restorationBehavior(.disabled)
        .commands {
            HelpCommands()
            #if DIRECT_DISTRIBUTION && !APP_STORE
            UpdateCommands()
            #endif
        }
        // In the system menu bar so the target can be switched from Safari,
        // where no TypeNBash menu is showing. Available while a project has
        // a Markdown document selected, matching the citations inspector.
        MenuBarExtra("CiteTex", systemImage: "safari", isInserted: .constant(
            windows.sessions.values.contains {
                $0.session.activeProject != nil
                    && $0.session.fileBrowser.supportsCitations
            }
        )) {
            CiteTexMenu(targets: citeTex)
        }
        Settings {
            IDESettingsView()
                .background(AppTheme.shared.windowBackground)
                .toolbar(removing: .title)
                .tint(Color.accentColor)
        }
        .windowLevel(.floating)
        // Standard titlebar on purpose: `.hiddenTitleBar` makes the content view
        // full-size, which slides the panes' NSScrollViews under the titlebar and
        // AppKit then draws its hard scroll-edge pocket over them — something
        // `.scrollEdgeEffectHidden`/`.soft` can't reach.
    }
}

private struct WelcomeWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

private struct SSHOpenCommand: View {
    @Environment(\.openWindow) private var openWindow
    let windows: WorkspaceWindows

    var body: some View {
        Button("New SSH Host...") {
            windows.pendingSSHSetup = true
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("h", modifiers: .command)
    }
}
private struct ProjectNewCommand: View {
    @Environment(\.openWindow) private var openWindow
    let windows: WorkspaceWindows

    var body: some View {
        Button("New Project...") {
            windows.creatingNewProject = true
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("p", modifiers: .command)
    }
}


/// The app chrome colors, with the user's overrides from Settings applied.
///
/// `@Observable`, so every view whose body reads one of the `Color` statics
/// below re-renders when the user picks a new color — no `.id()` reset that
/// would tear down terminals and editors.
@Observable
final class AppTheme {
    static let shared = AppTheme()

    // Each default resolves per appearance, so Light mode gets a light card
    // rather than the dark one with system controls drawn over it.
    static let defaultCard = adaptive(dark: "#0B0A0A", light: "#FCFCFC")
    static let defaultAccent = adaptive(dark: "#B8975E", light: "#8C6B2F")
    static let defaultForeground = adaptive(dark: "#F0EAD6", light: "#242424")
    static let defaultSecondary = adaptive(dark: "#7E7A70", light: "#6E6A60")
    // AppKit colors, so the defaults keep following light and dark mode.
    static let defaultDiffAdded = NSColor.systemGreen
    static let defaultDiffRemoved = NSColor.systemRed

    // The stored `#RRGGBBAA` override codes; nil keeps the default color.
    private var cardCode: String?
    private var accentCode: String?
    private var foregroundCode: String?
    private var secondaryCode: String?
    private var diffAddedCode: String?
    private var diffRemovedCode: String?
    /// The editor and syntax overrides. Only editors read these, so picking a
    /// syntax color leaves the chrome views alone.
    private var editorCodes: [EditorThemeSlot: String] = [:]

    /// Whether the window is painted with `gradientCard` rather than the flat card.
    private(set) var gradientBackground = false
    /// Applied to `NSApp`, so every window and sheet follows it.
    private(set) var displayMode = DisplayMode.dark {
        didSet { NSApplication.shared.appearance = displayMode.appearance }
    }
    var card: Color { Self.color(cardCode) ?? Self.defaultCard }
    var accent: Color { Self.color(accentCode) ?? Self.defaultAccent }
    var foreground: Color { Self.color(foregroundCode) ?? Self.defaultForeground }
    var secondary: Color { Self.color(secondaryCode) ?? Self.defaultSecondary }

    /// The diff palette for AppKit painters: the editor's change bars, the diff
    /// pane's gutter and row washes. SwiftUI reads `Color.diffAdded`/`diffRemoved`.
    var diffColors: GitDiffColors {
        GitDiffColors(added: Self.nsColor(diffAddedCode) ?? Self.defaultDiffAdded,
                      removed: Self.nsColor(diffRemovedCode) ?? Self.defaultDiffRemoved)
    }
    var diffAdded: Color { Color(nsColor: diffColors.added) }
    var diffRemoved: Color { Color(nsColor: diffColors.removed) }

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        reload()
        NSApplication.shared.appearance = displayMode.appearance
        // Settings writes the overrides through `@AppStorage`; follow along.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Re-reads the overrides, assigning only what changed so an unrelated
    /// defaults write doesn't invalidate every themed view.
    private func reload() {
        let defaults = UserDefaults.standard
        let card = defaults.string(forKey: DefaultKeys.backgroundColor.rawValue)
        let accent = defaults.string(forKey: DefaultKeys.accentColor.rawValue)
        let foreground = defaults.string(forKey: DefaultKeys.textColor.rawValue)
        let secondary = defaults.string(forKey: DefaultKeys.secondaryColor.rawValue)
        let diffAdded = defaults.string(forKey: DefaultKeys.diffAddedColor.rawValue)
        let diffRemoved = defaults.string(forKey: DefaultKeys.diffRemovedColor.rawValue)
        if cardCode != card { cardCode = card }
        if accentCode != accent { accentCode = accent }
        if foregroundCode != foreground { foregroundCode = foreground }
        if secondaryCode != secondary { secondaryCode = secondary }
        if diffAddedCode != diffAdded { diffAddedCode = diffAdded }
        if diffRemovedCode != diffRemoved { diffRemovedCode = diffRemoved }
        let editor = (EditorThemeSlot.editorSlots + EditorThemeSlot.syntaxSlots)
            .reduce(into: [EditorThemeSlot: String]()) { codes, slot in
                codes[slot] = defaults.string(forKey: slot.defaultsKey.rawValue)
            }
        if editorCodes != editor { editorCodes = editor }
        let gradient = defaults.bool(forKey: DefaultKeys.gradientBackground.rawValue)
        if gradientBackground != gradient { gradientBackground = gradient }
        let mode = defaults[.displayMode]
        if displayMode != mode { displayMode = mode }
    }

    var gradientCard: LinearGradient {
        .init(colors: [card, card.mix(with: foreground, by: 0.134)],
              startPoint: .bottomLeading,
              endPoint: .topTrailing)
    }

    /// The window's backdrop: one gradient spanning every column, or the flat card.
    var windowBackground: AnyShapeStyle {
        gradientBackground ? AnyShapeStyle(gradientCard) : AnyShapeStyle(card)
    }

    /// Fill for the panes and toolbar. Clear while the gradient is on, so the
    /// single window-wide gradient shows through instead of one per pane.
    var paneBackground: Color {
        gradientBackground ? .clear : .card
    }

    /// The colors every editor and diff view paints with: the TypeNBash
    /// palette for `colorScheme` with each override from Settings applied.
    func editorTheme(_ colorScheme: ColorScheme) -> Theme {
        var theme = Theme.TypeNBash(colorScheme)
        for slot in EditorThemeSlot.allCases {
            if let color = Self.nsColor(code(for: slot)) {
                slot.set(color, in: &theme)
            }
        }
        return theme
    }

    /// The stored override for `slot`, or nil when it keeps the default.
    private func code(for slot: EditorThemeSlot) -> String? {
        switch slot {
        case .text: foregroundCode
        case .background: cardCode
        case .accentColor: accentCode
        case .secondaryForeground: secondaryCode
        case .diffAdded: diffAddedCode
        case .diffRemoved: diffRemovedCode
        default: editorCodes[slot]
        }
    }

    private static func color(_ code: String?) -> Color? {
        nsColor(code).map { Color(nsColor: $0) }
    }

    private static func nsColor(_ code: String?) -> NSColor? {
        code.flatMap { NSColor.sRGB(colorCode: $0) }
    }

    /// AppKit may resolve the color off the main thread, so the closure only
    /// picks between two colors made up front.
    private static func adaptive(dark: String, light: String) -> Color {
        let dark = NSColor.hex(dark), light = NSColor.hex(light)
        return Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The diff palette as AppKit colors, handed to views that paint it. Only
/// `AppTheme.diffColors` makes one. The gutter marker uses each color as
/// picked; the row behind it takes a light wash of the same hue.
struct GitDiffColors: Equatable {
    var added: NSColor
    var removed: NSColor
}

extension Color {
    static var card: Color { AppTheme.shared.card }
    static var accentColor: Color { AppTheme.shared.accent }
    static var foreground: Color { AppTheme.shared.foreground }
    static var secondary: Color { AppTheme.shared.secondary }
    static var diffAdded: Color { AppTheme.shared.diffAdded }
    static var diffRemoved: Color { AppTheme.shared.diffRemoved }
}


// MARK: - Editor Palette

/// The built-in editor colors, before any override. `AppTheme.editorTheme(_:)`
/// is what editors paint with; this is only its starting point and the
/// defaults Settings shows.
extension Theme {

    static func TypeNBash(_ colorScheme: ColorScheme) -> Theme {
        colorScheme == .dark ? .TypeNBashDark : .TypeNBashLight
    }


    private static var TypeNBashDark: Theme {
        var theme = Theme()
        let palette = AppTheme.shared
        // Chrome colors follow the app theme (and the user's overrides of it),
        // so they stay as semantic colors rather than baked-in hex.
        theme.text = .init(color: NSColor(Color.foreground))
        theme.background = .init(color: NSColor(palette.paneBackground))
        theme.invisibles = .init(color: NSColor(Color.secondary.opacity(0.34)))
        theme.lineHighlight = .init(color: NSColor(Color.accentColor.opacity(0.2)))
        theme.insertionPoint = .init(color: .hex("#D6DEE8"), usesSystemSetting: false)
        theme.selection = .init(
            color: NSColor(Color.accentColor.opacity(0.5)),
            usesSystemSetting: false
        )
        // Syntax colors track Xcode's "Midnight" theme. `SyntaxType` has ten
        // slots against Midnight's thirty keys, so each slot takes the color of
        // the Xcode role that best matches what the tree-sitter queries in
        // SyntaxParsers/Queries actually capture into it — noted per line.
        theme.keywords = .init(color: .hex("#D31895"))    // xcode.syntax.keyword
        theme.commands = .init(color: .hex("#009ADE"))    // xcode.syntax.identifier.function
        theme.types = .init(color: .hex("#6BDFFF"))       // xcode.syntax.declaration.type
        theme.variables = .init(color: .hex("#41A1C0"))   // xcode.syntax.declaration.other
        theme.values = .init(color: .hex("#D31895"))      // true/false/nil — keywords in Xcode
        theme.numbers = .init(color: .hex("#786DFF"))     // xcode.syntax.number
        theme.strings = .init(color: .hex("#FF2C38"))     // xcode.syntax.string
        theme.characters = .init(color: .hex("#786DFF"))  // xcode.syntax.character
        theme.comments = .init(color: .hex("#41CC45"))    // xcode.syntax.comment

        // The `attributes` slot holds `@Observable`, `#available`, `#selector`
        // — which Xcode paints as macros, not as `xcode.syntax.attribute`.
        // Midnight's attribute navy (#2D449B) is also unreadable on black.
        theme.attributes = .init(color: .hex("#00B1FF"))  // xcode.syntax.identifier.macro
        return theme
    }

    private static var TypeNBashLight: Theme {
        var theme = Theme()
        // Same values as the light chrome defaults, but through the palette so
        // the editor goes clear for the gradient as it does in dark mode.
        theme.text = .init(color: NSColor(Color.foreground))
        theme.background = .init(color: NSColor(AppTheme.shared.paneBackground))
        theme.invisibles = .init(color: .hex("#BDBDBD"))
        theme.lineHighlight = .init(color: .hex("#EDF2FC"))
        theme.insertionPoint = .init(color: .hex("#242424"), usesSystemSetting: false)
        theme.selection = .init(color: .hex("#B8D4F7"), usesSystemSetting: false)
        theme.keywords = .init(color: .hex("#9433B8"))
        theme.commands = .init(color: .hex("#1F5CB8"))
        theme.types = .init(color: .hex("#057D7A"))
        theme.attributes = .init(color: .hex("#8B0099"))
        theme.variables = .init(color: .hex("#294F99"))
        theme.values = .init(color: .hex("#1466B3"))
        theme.numbers = .init(color: .hex("#1466B3"))
        theme.strings = .init(color: .hex("#B83329"))
        theme.characters = .init(color: .hex("#B83329"))
        theme.comments = .init(color: .hex("#337A38"))
        return theme
    }
}
