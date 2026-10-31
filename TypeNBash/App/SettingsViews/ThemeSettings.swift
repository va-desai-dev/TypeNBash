//
//  EditorOptionsControls.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/27/26.
//

import AppKit
import Defaults
import SwiftUI
import SyntaxFormat
import SyntaxParsers
internal import URLUtils

// MARK: - Theme Slots

/// One user-overridable color in the editor theme.
enum EditorThemeSlot: CaseIterable, Identifiable {
    case text, background, invisibles, lineHighlight, insertionPoint, selection
    case keywords, commands, types, variables, values, numbers, strings, characters, comments, attributes
    case accentColor, secondaryForeground
    case diffAdded, diffRemoved

    var id: Self { self }

    /// Colors shared by the app chrome and the editor: `background` is also
    /// `Color.card`, `text` is also `Color.foreground`.
    static let appSlots: [Self] = [.background, .text, .accentColor, .secondaryForeground]
    static let editorSlots: [Self] = [.invisibles, .lineHighlight, .insertionPoint, .selection]
    static let syntaxSlots: [Self] = [.keywords, .commands, .types, .variables, .values,
                                      .numbers, .strings, .characters, .comments, .attributes]
    static let diffSlots: [Self] = [.diffAdded, .diffRemoved]

    var label: String {
        switch self {
        case .text: "Text"
        case .background: "Background"
        case .invisibles: "Invisibles"
        case .lineHighlight: "Line Highlight"
        case .insertionPoint: "Insertion Point"
        case .selection: "Selections"
        case .keywords: "Keywords"
        case .commands: "Commands"
        case .types: "Declarations/Types"
        case .variables: "Variables"
        case .values: "Values"
        case .numbers: "Numbers"
        case .strings: "Strings"
        case .characters: "Characters"
        case .comments: "Comments"
        case .attributes: "Attributes"
        case .accentColor: "Accent"
        case .secondaryForeground: "Muted Labels"
        case .diffAdded: "Diff Additions"
        case .diffRemoved: "Diff Deletions"
        }
    }

    /// Where Settings stores the slot's override; `AppTheme` reads it back.
    var defaultsKey: DefaultKey<String?> {
        switch self {
        case .text: DefaultKeys.textColor
        case .background: DefaultKeys.backgroundColor
        case .invisibles: DefaultKeys.invisiblesColor
        case .lineHighlight: DefaultKeys.lineHighlight
        case .insertionPoint: DefaultKeys.insertionPoint
        case .selection: DefaultKeys.selectionColor
        case .keywords: DefaultKeys.keywords
        case .commands: DefaultKeys.commands
        case .types: DefaultKeys.declaredtypes
        case .variables: DefaultKeys.variables
        case .values: DefaultKeys.values
        case .numbers: DefaultKeys.numbers
        case .strings: DefaultKeys.strings
        case .characters: DefaultKeys.characters
        case .comments: DefaultKeys.comments
        case .attributes: DefaultKeys.attributes
        case .accentColor: DefaultKeys.accentColor
        case .secondaryForeground: DefaultKeys.secondaryColor
        case .diffAdded: DefaultKeys.diffAddedColor
        case .diffRemoved: DefaultKeys.diffRemovedColor
        }
    }

    /// Whether the picker offers opacity. The card sits on an opaque window,
    /// and the diff colors are washed to a fixed strength, so a translucent
    /// pick would only wash them out further.
    var supportsOpacity: Bool {
        switch self {
        case .background, .diffAdded, .diffRemoved: false
        default: true
        }
    }

    /// The slot's color in `theme`. App slots read the app palette's defaults
    /// instead: the palette is the source of truth the editor theme follows,
    /// and the editor's own background goes clear while the gradient is on.
    func color(in theme: Theme) -> NSColor {
        switch self {
        case .text: NSColor(AppTheme.defaultForeground)
        case .background: NSColor(AppTheme.defaultCard)
        case .invisibles: theme.invisibles.color
        case .lineHighlight: theme.lineHighlight.color
        case .insertionPoint: theme.insertionPoint.color
        case .selection: theme.selection.color
        case .keywords: theme.keywords.color
        case .commands: theme.commands.color
        case .types: theme.types.color
        case .variables: theme.variables.color
        case .values: theme.values.color
        case .numbers: theme.numbers.color
        case .strings: theme.strings.color
        case .characters: theme.characters.color
        case .comments: theme.comments.color
        case .attributes: theme.attributes.color
        case .accentColor: NSColor(AppTheme.defaultAccent)
        case .secondaryForeground: NSColor(AppTheme.defaultSecondary)
        case .diffAdded: AppTheme.defaultDiffAdded
        case .diffRemoved: AppTheme.defaultDiffRemoved
        }
    }

    /// Replaces the slot's color in `theme`.
    func set(_ color: NSColor, in theme: inout Theme) {
        switch self {
        // App slots: the editor follows the app palette, which already applies
        // the override — and whose pane fill goes clear while the gradient is
        // on, so the window gradient shows through the editor too.
        case .text: theme.text.color = NSColor(Color.foreground)
        case .background: theme.background.color = NSColor(AppTheme.shared.paneBackground)
        case .invisibles: theme.invisibles.color = color
        case .lineHighlight: theme.lineHighlight.color = color
        // A user-picked caret or selection color must win over the system one.
        case .insertionPoint: theme.insertionPoint = .init(color: color, usesSystemSetting: false)
        case .selection: theme.selection = .init(color: color, usesSystemSetting: false)
        case .keywords: theme.keywords.color = color
        case .commands: theme.commands.color = color
        case .types: theme.types.color = color
        case .variables: theme.variables.color = color
        case .values: theme.values.color = color
        case .numbers: theme.numbers.color = color
        case .strings: theme.strings.color = color
        case .characters: theme.characters.color = color
        case .comments: theme.comments.color = color
        case .attributes: theme.attributes.color = color
        // The theme already derives its accent and muted colors from
        // `Color.accentColor`/`Color.secondary`, which apply these overrides.
        case .accentColor, .secondaryForeground: break
        // The editor theme has no diff colors; every diff painter reads them
        // from `AppTheme`, which applies these overrides.
        case .diffAdded, .diffRemoved: break
        }
    }
}


// MARK: - Overrides

/// The Settings window's bindings to the stored theme overrides. Nothing
/// paints from these: `AppTheme` reads the same defaults and is what the
/// chrome, editors and diff views draw with. A slot with no stored code (or an
/// unparsable one) keeps the TypeNBash color.
struct EditorThemeOverrides: DynamicProperty {
    @AppStorage(.textColor) private var text: String?
    @AppStorage(.backgroundColor) private var background: String?
    @AppStorage(.invisiblesColor) private var invisibles: String?
    @AppStorage(.lineHighlight) private var lineHighlight: String?
    @AppStorage(.insertionPoint) private var insertionPoint: String?
    @AppStorage(.selectionColor) private var selection: String?

    @Environment(\.colorScheme) private var scheme

    @AppStorage(.keywords) private var keywords: String?
    @AppStorage(.commands) private var commands: String?
    @AppStorage(.declaredtypes) private var types: String?
    @AppStorage(.variables) private var variables: String?
    @AppStorage(.values) private var values: String?
    @AppStorage(.numbers) private var numbers: String?
    @AppStorage(.strings) private var strings: String?
    @AppStorage(.characters) private var characters: String?
    @AppStorage(.comments) private var comments: String?
    @AppStorage(.attributes) private var attributes: String?

    @AppStorage(.accentColor) private var accent: String?
    @AppStorage(.secondaryColor) private var secondary: String?

    @AppStorage(.diffAddedColor) private var diffAdded: String?
    @AppStorage(.diffRemovedColor) private var diffRemoved: String?

    /// The stored `#RRGGBBAA` code for `slot`; nil means "not overridden".
    func colorCode(for slot: EditorThemeSlot) -> Binding<String?> {
        switch slot {
        case .text: $text
        case .background: $background
        case .invisibles: $invisibles
        case .lineHighlight: $lineHighlight
        case .insertionPoint: $insertionPoint
        case .selection: $selection
        case .keywords: $keywords
        case .commands: $commands
        case .types: $types
        case .variables: $variables
        case .values: $values
        case .numbers: $numbers
        case .strings: $strings
        case .characters: $characters
        case .comments: $comments
        case .attributes: $attributes
        case .accentColor: $accent
        case .secondaryForeground: $secondary
        case .diffAdded: $diffAdded
        case .diffRemoved: $diffRemoved
        }
    }

    /// The user's color for `slot`, or nil when it follows the base theme.
    func color(for slot: EditorThemeSlot) -> NSColor? {
        colorCode(for: slot).wrappedValue.flatMap { NSColor.sRGB(colorCode: $0) }
    }

    var hasOverrides: Bool {
        EditorThemeSlot.allCases.contains { colorCode(for: $0).wrappedValue != nil }
    }

    func removeAll() {
        for slot in EditorThemeSlot.allCases {
            colorCode(for: slot).wrappedValue = nil
        }
    }
}


// MARK: - Presets

/// A named palette from `appThemeConcepts.json`, applied by writing its
/// colors as overrides — so the chrome and every editor follow it the same
/// way they follow a hand-picked color.
struct EditorThemePreset: Identifiable {
    /// The JSON key of the palette that matches the built-in TypeNBash theme.
    static let defaultID = "default"

    let id: String
    /// Each slot's color as a normalized `#RRGGBBAA` code.
    let colorCodes: [EditorThemeSlot: String]

    var isDefault: Bool { id == Self.defaultID }

    /// The mode the palette was drawn for, judged by its background. Nil for
    /// TypeNBash, which has both.
    var displayMode: DisplayMode? {
        guard !isDefault, let background = colorCodes[.background].flatMap({ NSColor.sRGB(colorCode: $0) })
        else { return nil }
        return background.brightnessComponent < 0.5 ? .dark : .light
    }

    /// "tokyoNightInspired" → "Tokyo Night".
    var label: String {
        if isDefault { return "TypeNBash" }
        let name = id.hasSuffix("Inspired") ? String(id.dropLast("Inspired".count)) : id
        let words = name.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(result.isEmpty ? Character(character.uppercased()) : character)
        }
        // Brand names the camel-case split can't spell.
        return words
            .replacingOccurrences(of: "Github", with: "GitHub")
            .replacingOccurrences(of: "Vscode", with: "VS Code")
    }

    /// The JSON field name for `slot`; nil for slots the palettes don't set.
    private static func key(for slot: EditorThemeSlot) -> String? {
        switch slot {
        case .text: "foreground"
        case .background: "background"
        case .invisibles: "invisibles"
        case .lineHighlight: "highlights"
        case .insertionPoint: "insertionPoint"
        case .selection: "selection"
        case .keywords: "keywords"
        case .commands: "commands"
        case .types: "types"
        case .variables: "variables"
        case .values: "values"
        case .numbers: "numbers"
        case .strings: "strings"
        case .characters: "characters"
        case .comments: "comments"
        case .accentColor: "accentControls"
        case .secondaryForeground: "muted"
        case .diffAdded: "diffAdded"
        case .diffRemoved: "diffRemoved"
        case .attributes: nil
        }
    }

    /// Every palette in the bundled JSON: TypeNBash first, the rest by name.
    static let all: [Self] = {
        guard
            let url = Bundle.main.url(forResource: "appThemeConcepts", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let palettes = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [] }

        return palettes
            .map { id, fields in
                // Normalize through NSColor so codes compare equal to the
                // ones the color pickers store.
                let codes = EditorThemeSlot.allCases.reduce(into: [EditorThemeSlot: String]()) { codes, slot in
                    if let hex = key(for: slot).flatMap({ fields[$0] }),
                       let code = NSColor.sRGB(colorCode: hex)?.sRGBColorCode {
                        codes[slot] = code
                    }
                }
                return Self(id: id, colorCodes: codes)
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }()
}

extension EditorThemeOverrides {
    /// Replaces every override with `preset`'s colors. The TypeNBash preset
    /// clears the overrides instead, so the built-in light/dark theme applies.
    /// Any other preset also switches to its own mode: the overrides hold one
    /// color per slot, and a dark palette under light controls is unreadable.
    func apply(_ preset: EditorThemePreset) {
        for slot in EditorThemeSlot.allCases {
            colorCode(for: slot).wrappedValue = preset.isDefault ? nil : preset.colorCodes[slot]
        }
        if let mode = preset.displayMode {
            UserDefaults.standard[.displayMode] = mode
        }
    }

    /// The preset the stored overrides match exactly, or nil once the user
    /// has customized any color.
    func matchingPreset(in presets: [EditorThemePreset]) -> EditorThemePreset? {
        presets.first { preset in
            if preset.isDefault { return !hasOverrides }
            return EditorThemeSlot.allCases.allSatisfy {
                colorCode(for: $0).wrappedValue == preset.colorCodes[$0]
            }
        }
    }
}

// MARK: - Controls

/// The editor options shared by every editor. The same controls sit in each
/// editor's options menu and in the Settings window; both write the same
/// user defaults, so a change in either place reaches every open editor.
struct EditorThemeControls: View {
    @Environment(\.colorScheme) private var colorScheme
    private var overrides = EditorThemeOverrides()
    @AppStorage(.gradientBackground) private var gradientBackground: Bool

    var body: some View {
        Form {
            Section("Preferred Mode") {
                VisualAppearancePicker()
            }
            Section("App Theme") {
                presetPicker
                ForEach(EditorThemeSlot.appSlots) { row(for: $0) }
                Toggle("Gradient Background", isOn: $gradientBackground)
            }
            Section("Editor Theme") {
                ForEach(EditorThemeSlot.editorSlots) { row(for: $0) }
            }
            Section("Syntax Theme") {
                ForEach(EditorThemeSlot.syntaxSlots) { row(for: $0) }
            }
            Section("Diff Theme") {
                ForEach(EditorThemeSlot.diffSlots) { row(for: $0) }
            }
            Section {
                Button("Restore TypeNBash Colors") {
                    overrides.removeAll()
                }
                .disabled(!overrides.hasOverrides)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Picks a bundled palette. Shows "Custom" once any color is edited by hand.
    private var presetPicker: some View {
        let presets = EditorThemePreset.all
        let current = overrides.matchingPreset(in: presets)
        let selection = Binding<String?>(
            get: { current?.id },
            set: { id in
                if let preset = presets.first(where: { $0.id == id }) {
                    overrides.apply(preset)
                }
            }
        )

        return Picker("Preset", selection: selection) {
            if current == nil {
                Text("Custom").tag(String?.none)
            }
            ForEach(presets) { preset in
                Text(preset.label).tag(Optional(preset.id))
            }
        }
    }

    /// A picker that shows the override when set, otherwise the TypeNBash
    /// color; picking a color stores it as an override.
    private func row(for slot: EditorThemeSlot) -> some View {
        let code = overrides.colorCode(for: slot)
        let fallback = slot.color(in: .TypeNBash(colorScheme))
        let selection = Binding<Color>(
            get: { Color(nsColor: overrides.color(for: slot) ?? fallback) },
            set: { code.wrappedValue = NSColor($0).sRGBColorCode }
        )

        return HStack {
            ColorPicker(slot.label, selection: selection, supportsOpacity: slot.supportsOpacity)
            if code.wrappedValue != nil {
                Button("Reset", systemImage: "arrow.uturn.backward") {
                    code.wrappedValue = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Use the TypeNBash Default")
            }
        }
    }
}
