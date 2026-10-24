//
//  CustomHoverButtonStyle.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/23/26.
//


import SwiftUI

struct NavigatorButtonStyle: ButtonStyle {
    let iconName: String
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center , spacing: 8) {
            configuration.label
                .lineLimit(1)
            Image(systemName: isHovered ? "chevron.up.chevron.down" : "chevron.compact.forward")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .contentShape(Rectangle()) // Ensures the entire row area is hover-detectable
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.secondary.opacity(0.15) : Color.clear)
        )
        .opacity(configuration.isPressed ? 0.7 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// Extension for clean modifiers
extension ButtonStyle where Self == NavigatorButtonStyle {
    static func navigator(icon: String) -> NavigatorButtonStyle {
        NavigatorButtonStyle(iconName: icon)
    }
}

