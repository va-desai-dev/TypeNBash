//
//  ListRows.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/29/26.
//

import SwiftUI

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// Bespoke selection row: a plain Button drives the section's selection instead of
// List(selection:), so AppKit never draws its emphasized tint over the palette.
// The selected row fills with the themed accent. Right-click is the native Mac
// gesture, so per-row actions arrive as context-menu items.
struct MacColumnRowButton<MenuItems: View>: View {

    let action: () -> Void
    let name: String
    // Shown when `name` is blank, e.g. "Untitled Persona".
    let placeholder: String
    var subtitle: String? = nil
    let isSelected: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal.circle")
                    .font(.largeTitle)
                    .foregroundStyle(
                        isSelected ? Color.foreground : Color(NSColor.controlColor)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.trimmed.isEmpty ? placeholder : name)
                        .fontWeight(.semibold)
                        .foregroundStyle(.foreground)
                        .lineLimit(1)
                    if let subtitle, !subtitle.trimmed.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color(NSColor.controlColor) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.foreground : Color.accentColor,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .buttonStyle(.plain)
        .contextMenu {
            menuItems()
        }
    }
}

