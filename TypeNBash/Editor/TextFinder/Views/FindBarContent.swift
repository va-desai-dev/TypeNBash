import AppKit
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
