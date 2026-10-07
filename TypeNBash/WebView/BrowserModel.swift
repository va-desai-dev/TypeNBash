import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

@Observable
final class BrowserModel {
    /// The bundled site in `Resources/Home`, served offline by `HomePageSchemeHandler`.
    static let homeURL = URL(string: "\(HomePageSchemeHandler.scheme)://home/index.html")!
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabID: UUID?

    var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }

    init(initialURL: URL? = BrowserModel.homeURL) {
        open(initialURL.map { URLRequest(url: $0) })
    }

    func open(_ request: URLRequest? = nil) {
        let tab = BrowserTab(request: request) { [weak self] request in self?.open(request) }
        tabs.append(tab)
        select(tab)
    }

    func select(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }), activeTabID != tab.id else { return }
        activeTab?.isEditingAddress = false
        activeTab?.syncAddress()
        activeTabID = tab.id
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.page.stopLoading()
        tabs.remove(at: index)
        if activeTabID == tab.id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func openInDefaultBrowser() {
        guard let url = activeTab?.page.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", HomePageSchemeHandler.scheme].contains(scheme) {
            guard !["http", "https"].contains(scheme) || url.host?.isEmpty == false else { return nil }
            return url
        }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let isLocal = host == "localhost" || host.hasPrefix("localhost:")
            || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
        let hasWhitespace = text.contains { $0.isWhitespace }
        if !hasWhitespace, (host.contains(".") || isLocal), !host.contains("@"), !text.contains("://"),
           let url = URL(string: (isLocal ? "http://" : "https://") + text), url.host != nil {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}

/// Page lifetime belongs to the tab; address drafts are independent of redirects.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let page: WebPage
    var addressText = ""
    var isEditingAddress = false
    private var requestedURL: URL?

    init(request: URLRequest?, openTab: @escaping @MainActor (URLRequest) -> Void) {
        var configuration = WebPage.Configuration()
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.urlSchemeHandlers[URLScheme(HomePageSchemeHandler.scheme)!] = HomePageSchemeHandler()
        page = WebPage(configuration: configuration,
                       navigationDecider: BrowserNavigationPolicy(openTab: openTab))
        if let request { load(request) }
    }

    /// Embedded WebKit's default user agent omits the `Version/… Safari/…` tail, so
    /// Gmail and many other sites sniff it as an unsupported browser. Mirror the
    /// installed Safari's version: same engine, so the claim is accurate.
    private static let safariUserAgentSuffix: String = {
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        return "Version/\(version) Safari/605.1.15"
    }()

    var displayTitle: String {
        if !page.title.isEmpty { return page.title }
        return page.url?.host() ?? "New Tab"
    }

    func load(_ request: URLRequest) {
        requestedURL = request.url
        addressText = request.url?.absoluteString ?? ""
        page.load(request)
    }

    func syncAddress() {
        guard !isEditingAddress else { return }
        addressText = (page.url ?? requestedURL)?.absoluteString ?? ""
    }
}

@MainActor
struct BrowserNavigationPolicy: WebPage.NavigationDeciding {
    let openTab: @MainActor (URLRequest) -> Void

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        // SwiftUI WebView has no new-window presenter. Route untargeted requests
        // into a tab instead of silently dropping target="_blank" links/forms.
        if action.target == nil {
            openTab(action.request)
            return .cancel
        }
        return .allow
    }
}

/// Serves files from the bundled `Home` folder; paths cannot escape it.
struct HomePageSchemeHandler: URLSchemeHandler {
    static let scheme = "typenbash"
    private static let root = Bundle.main.resourceURL!.appending(path: "Home", directoryHint: .isDirectory).standardizedFileURL

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url else { return continuation.finish(throwing: URLError(.badURL)) }
            let file = Self.root.appending(path: url.path(percentEncoded: false)).standardizedFileURL
            guard file.path.hasPrefix(Self.root.path + "/"), let data = try? Data(contentsOf: file) else {
                return continuation.finish(throwing: URLError(.fileDoesNotExist))
            }
            let mimeType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            continuation.yield(.response(URLResponse(url: url, mimeType: mimeType,
                                                     expectedContentLength: data.count, textEncodingName: "utf-8")))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}
