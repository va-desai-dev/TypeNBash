//
//  BrowserBarItems.swift
//  TypeNBash
//
//  The individual controls that go in a browser pane's `PaneBar`s. They read
//  the tab they are given and report intent through closures; `BrowserView`
//  owns focus and decides what each action does to it.
//

import SwiftUI
import WebKit

/// Which part of the browser pane holds keyboard focus.
enum BrowserFocusTarget: Hashable { case address, page }

/// Swaps an editor pane between its open file and the browser. Unstyled, so it
/// picks up the button style of whichever bar it sits in.
struct BrowserToggleButton: View {
    @Binding var showsBrowser: Bool

    var body: some View {
        Button {
            showsBrowser.toggle()
        } label: {
            Image(systemName: showsBrowser ? "xmark" : "globe")
        }
        .help(showsBrowser ? "Return to the Editor" : "Show Browser")
        .accessibilityLabel(showsBrowser ? "Return to the Editor" : "Show Browser")
    }
}

/// Click goes one step; click-and-hold lists the full history in that direction.
struct BrowserHistoryMenu: View {
    enum Direction { case back, forward }

    let direction: Direction
    let page: WebPage?
    let onSelect: (WebPage.BackForwardList.Item) -> Void

    /// Nearest entry first, so the menu reads outward from the current page.
    private var history: [WebPage.BackForwardList.Item] {
        guard let list = page?.backForwardList else { return [] }
        return direction == .back ? list.backList.reversed() : list.forwardList
    }

    var body: some View {
        let history = history
        Menu {
            ForEach(history) { item in
                Button(item.title ?? item.url.absoluteString) { onSelect(item) }
            }
        } label: {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
        } primaryAction: {
            if let nearest = history.first { onSelect(nearest) }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 24)
        .disabled(history.isEmpty)
        .keyboardShortcut(direction == .back ? "[" : "]", modifiers: .command)
        .help(direction == .back ? "Back (⌘[) — hold for history" : "Forward (⌘]) — hold for history")
    }
}

/// Reload, or stop while the page is loading.
struct BrowserReloadButton: View {
    let page: WebPage?

    var body: some View {
        if let page, page.isLoading {
            PaneBarButton("xmark", help: "Stop") { page.stopLoading() }
                .keyboardShortcut(".", modifiers: .command)
        } else {
            PaneBarButton("arrow.clockwise", help: "Reload (⌘R)") { page?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(page?.url == nil)
        }
    }
}

struct BrowserAddressField: View {
    let tab: BrowserTab?
    var focus: FocusState<BrowserFocusTarget?>.Binding
    @Binding var selection: TextSelection?
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// ⌘L, like other browsers.
    let onFocusRequest: () -> Void

    private var isSecure: Bool { tab?.page.url?.scheme == "https" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSecure ? "lock.fill" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search or enter website", text: Binding(
                get: { tab?.addressText ?? "" },
                set: { tab?.addressText = $0 }
            ), selection: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus, equals: .address)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focus.wrappedValue == .address ? Color.accentColor : Color.white.opacity(0.08))
        }
        .background {
            Button("Focus Address", action: onFocusRequest)
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
        }
    }
}

/// Scrolling row of tabs plus the new-tab button.
struct BrowserTabStrip: View {
    let model: BrowserModel
    let onNewTab: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(model.tabs) { tab in
                    BrowserTabButton(
                        tab: tab,
                        isActive: tab.id == model.activeTabID,
                        select: { model.select(tab) },
                        close: { model.close(tab) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)

        PaneBarButton("plus", help: "New Tab (⌘T)", action: onNewTab)
            .keyboardShortcut("t", modifiers: .command)
    }
}

/// A single tab in the strip: title, loading spinner, and a close button on hover.
private struct BrowserTabButton: View {
    let tab: BrowserTab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.page.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
            }

            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isActive ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 26)
        .background(
            isActive ? Color.white.opacity(0.09) : (isHovering ? Color.white.opacity(0.04) : Color.clear),
            in: .rect(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.page.url?.absoluteString ?? tab.displayTitle)
    }
}
