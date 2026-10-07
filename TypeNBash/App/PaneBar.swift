//
//  PaneBar.swift
//  TypeNBash
//
//  The chrome shared by every pane header and footer. It owns sizing, padding,
//  background and the hairline toward the content; it knows nothing about what
//  sits inside it. Callers wire the items in directly, so a bar never has to
//  branch on what kind of pane it is attached to.
//

import SwiftUI

struct PaneBar<Content: View, Accessory: View>: View {
    /// Row height every bar shares, so headers line up across split panes.
    static var rowHeight: CGFloat { 34 }

    /// Which side of the content the bar sits on; the divider faces the content.
    let edge: VerticalEdge
    let showsDivider: Bool
    /// Drawn along the divider while non-nil; 0...1.
    let progress: Double?
    let content: Content
    /// Secondary bars stacked under a header, such as a find bar or tab strip.
    /// Each one draws its own trailing divider.
    let accessory: Accessory

    init(
        edge: VerticalEdge = .top,
        showsDivider: Bool = true,
        progress: Double? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.edge = edge
        self.showsDivider = showsDivider
        self.progress = progress
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            if edge == .bottom && showsDivider { Divider() }
            HStack(alignment: .center, spacing: 8) {
                content
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { progressLine }
            if edge == .top && showsDivider { Divider() }
            accessory
        }
        .background(Color.card)
    }

    @ViewBuilder
    private var progressLine: some View {
        if let progress {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * max(0.05, progress))
                    .animation(.easeOut(duration: 0.2), value: progress)
            }
            .frame(height: 2)
            .offset(y: 1)
        }
    }
}

extension PaneBar where Accessory == EmptyView {
    init(
        edge: VerticalEdge = .top,
        showsDivider: Bool = true,
        progress: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(edge: edge, showsDivider: showsDivider, progress: progress, content: content) { EmptyView() }
    }
}

/// A borderless icon button sized for a `PaneBar` row.
struct PaneBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
