//
//  BrowserView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/5/26.
//

import SwiftUI
import WebKit
import Foundation

struct BrowserView<Trailing: View>: View {
    @State private var model: BrowserModel
    @State private var addressSelection: TextSelection?
    /// Spans the header and the page, so it lives here rather than in either.
    @FocusState private var focus: BrowserFocusTarget?
    /// Items the host adds to the end of the header, such as a way back to
    /// whatever the browser replaced. Stays enabled with no tabs open.
    private let trailing: Trailing

    private var activeTab: BrowserTab? { model.activeTab }

    init(model: BrowserModel? = nil, @ViewBuilder trailing: () -> Trailing) {
        _model = State(initialValue: model ?? BrowserModel())
        self.trailing = trailing()
    }

    var body: some View {
        content
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .background(Color.card)
        .onChange(of: model.activeTabID) {
            addressSelection = nil
            let target: BrowserFocusTarget = activeTab?.addressText.isEmpty == true ? .address : .page
            activeTab?.isEditingAddress = target == .address
            focus = target
        }
        .onChange(of: activeTab?.page.url) { activeTab?.syncAddress() }
        .onChange(of: focus) { _, target in
            let wasEditing = activeTab?.isEditingAddress == true
            activeTab?.isEditingAddress = target == .address
            if wasEditing && target != .address { activeTab?.syncAddress() }
        }
    }

    // MARK: - Header

    private var loadingProgress: Double? {
        guard let page = activeTab?.page, page.isLoading else { return nil }
        return page.estimatedProgress
    }

    private var header: some View {
        PaneBar(progress: loadingProgress) {
            Group {
                BrowserHistoryMenu(direction: .back, page: activeTab?.page, onSelect: navigate(to:))
                BrowserHistoryMenu(direction: .forward, page: activeTab?.page, onSelect: navigate(to:))
                BrowserReloadButton(page: activeTab?.page)
                BrowserAddressField(
                    tab: activeTab,
                    focus: $focus,
                    selection: $addressSelection,
                    onSubmit: submitAddress,
                    onCancel: cancelAddressEdit,
                    onFocusRequest: focusAddress
                )
                PaneBarButton("house", help: "Home") { navigate(to: BrowserModel.homeURL) }
                PaneBarButton("arrow.up.forward.app", help: "Open in Default Browser") {
                    model.openInDefaultBrowser()
                }
                .disabled(activeTab?.page.url?.scheme?.hasPrefix("http") != true)
            }
            .disabled(activeTab == nil)
            trailing
                .tint(.red)
                .buttonStyle(.borderedProminent)
        } accessory: {
            PaneBar {
                BrowserTabStrip(model: model, onNewTab: addNewTab)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let tab = activeTab {
            WebView(tab.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewMagnificationGestures(.enabled)
                .webViewLinkPreviews(.enabled)
                .webViewElementFullscreenBehavior(.enabled)
                // A WebPage can only be bound to one WebView at a time; tie identity to the tab.
                .id(tab.id)
                .focused($focus, equals: .page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Open Tabs", systemImage: "globe")
            } actions: {
                Button("New Tab", action: addNewTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func addNewTab() {
        model.open(URLRequest(url: BrowserModel.homeURL))
        focusAddress()
    }

    private func focusAddress() {
        guard let tab = activeTab else { return }
        tab.isEditingAddress = true
        focus = .address
        // Select only the address field, never the web page's first responder.
        addressSelection = TextSelection(range: tab.addressText.startIndex..<tab.addressText.endIndex)
    }

    private func cancelAddressEdit() {
        activeTab?.isEditingAddress = false
        activeTab?.syncAddress()
        addressSelection = nil
        focus = .page
    }

    private func submitAddress() {
        guard let tab = activeTab, let url = BrowserModel.resolve(tab.addressText) else { return }
        tab.isEditingAddress = false
        addressSelection = nil
        focus = .page
        tab.load(URLRequest(url: url))
    }

    private func navigate(to url: URL) {
        activeTab?.isEditingAddress = false
        focus = .page
        activeTab?.load(URLRequest(url: url))
    }

    private func navigate(to item: WebPage.BackForwardList.Item) {
        activeTab?.isEditingAddress = false
        focus = .page
        activeTab?.page.load(item)
    }
}

extension BrowserView where Trailing == EmptyView {
    init(model: BrowserModel? = nil) {
        self.init(model: model) { EmptyView() }
    }
}
