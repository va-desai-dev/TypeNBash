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

    var id: Self { self }

    /// Colors shared by the app chrome and the editor: `background` is also
    /// `Color.card`, `text` is also `Color.foreground`.
    static let appSlots: [Self] = [.background, .text, .accentColor, .secondaryForeground]
    static let editorSlots: [Self] = [.invisibles, .lineHighlight, .insertionPoint, .selection]
    static let syntaxSlots: [Self] = [.keywords, .commands, .types, .variables, .values,
                                      .numbers, .strings, .characters, .comments, .attributes]

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
        }
    }

    /// The slot's color in `theme`.
    func color(in theme: Theme) -> NSColor {
        switch self {
        case .text: theme.text.color
        case .background: theme.background.color
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
        case .accentColor: NSColor(Color.accentColor)
        case .secondaryForeground: NSColor(Color.secondary)
        }
    }

    /// Replaces the slot's color in `theme`.
    func set(_ color: NSColor, in theme: inout Theme) {
        switch self {
        case .text: theme.text.color = color
        case .background: theme.background.color = color
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
        }
    }
}


// MARK: - Overrides

/// The user's theme color overrides, read straight from user defaults.
///
/// A `DynamicProperty`, so any view holding one — every editor and the
/// Settings window — re-renders when an override changes. A slot with no
/// stored code (or an unparsable one) keeps the TypeNBash theme color.
struct EditorThemeOverrides: DynamicProperty {
    @AppStorage(.textColor) private var text: String?
    @AppStorage(.backgroundColor) private var background: String?
    @AppStorage(.invisiblesColor) private var invisibles: String?
    @AppStorage(.lineHighlight) private var lineHighlight: String?
    @AppStorage(.insertionPoint) private var insertionPoint: String?
    @AppStorage(.selectionColor) private var selection: String?

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
        }
    }

    /// The user's color for `slot`, or nil when it follows the base theme.
    func color(for slot: EditorThemeSlot) -> NSColor? {
        colorCode(for: slot).wrappedValue.flatMap { NSColor.sRGB(colorCode: $0) }
    }

    var hasOverrides: Bool {
        EditorThemeSlot.allCases.contains { colorCode(for: $0).wrappedValue != nil }
    }

    /// `theme` with every overridden slot replaced.
    func applied(to theme: Theme) -> Theme {
        var theme = theme
        for slot in EditorThemeSlot.allCases {
            if let color = color(for: slot) {
                slot.set(color, in: &theme)
            }
        }
        return theme
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
    func apply(_ preset: EditorThemePreset) {
        for slot in EditorThemeSlot.allCases {
            colorCode(for: slot).wrappedValue = preset.isDefault ? nil : preset.colorCodes[slot]
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
            ColorPicker(slot.label, selection: selection, supportsOpacity: true)
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
