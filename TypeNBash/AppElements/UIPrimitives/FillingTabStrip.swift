//
//  FillingTabStrip.swift
//  TypeNBash
//
//  A pane's tab strip, with segments that share the full row width.
//
//  SwiftUI's segmented and tabs picker styles size each segment to its content,
//  so the control stays compressed however wide it is laid out.
//  `NSSegmentedControl` exposes `.fillEqually`, so the strip is the stock
//  AppKit control.
//

import AppKit
import SwiftUI

struct FillingTabStrip<Tab: Hashable>: NSViewRepresentable {
    /// What a segment shows. Images carry the tab name as their tooltip and
    /// accessibility description.
    enum Content {
        case image(NSImage?)
        case title(String)
    }

    let accessibilityLabel: String
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let content: (Tab) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = tabs.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        if #available(macOS 27, *) {
            control.role = .tabs
        }
        for (segment, tab) in tabs.enumerated() {
            switch content(tab) {
            case .image(let image):
                image?.accessibilityDescription = title(tab)
                control.setImage(image, forSegment: segment)
                control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
            case .title(let text):
                control.setLabel(text, forSegment: segment)
            }
            control.setToolTip(title(tab), forSegment: segment)
        }
        control.setAccessibilityLabel(accessibilityLabel)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = { [tabs, $selection] segment in
            guard tabs.indices.contains(segment) else { return }
            $selection.wrappedValue = tabs[segment]
        }
        if let index = tabs.firstIndex(of: selection), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// Takes every point of width offered, so the segments stretch with the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: max(width, intrinsic.width), height: intrinsic.height)
    }

    @MainActor final class Coordinator: NSObject {
        var select: (Int) -> Void = { _ in }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            select(sender.selectedSegment)
        }
    }
}
