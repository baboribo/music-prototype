import OSLog
import SwiftUI
import WebKit

/// The app's own signed-in music.youtube.com session, kept by WebKit.
///
/// Credentials live only in this app's persistent WebKit data store (its identifier is kept in
/// UserDefaults, so the store survives relaunch). They are read at request time and dropped:
/// never logged, copied to a file or Keychain, or handed to another store. Sign-in happens on the
/// official pages in a web view on the same store; local sign-out removes this store's data
/// (no server-side logout).
@MainActor
final class WebKitSession: NSObject {
    private static let storeKey = "webSession.storeID"
    private static let log = Logger(subsystem: "MusicPrototype", category: "Auth")
    nonisolated static let origin = "https://music.youtube.com"

    /// What a signed-in YouTube Music page reports about itself (values stay in memory).
    struct PageConfig: Sendable {
        let loggedIn: Bool
        let clientVersion: String?
        let sessionIndex: String?
        let delegatedSessionID: String?
        let visitorData: String?
    }

    /// Kept referenced: a released identifier store returns no cookies.
    let store: WKWebsiteDataStore
    private var hidden: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        let id: UUID
        if let text = defaults.string(forKey: Self.storeKey), let saved = UUID(uuidString: text) {
            id = saved
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: Self.storeKey)
        }
        store = WKWebsiteDataStore(forIdentifier: id)
        super.init()
    }

    /// youtube.com cookies of this store, HttpOnly included.
    func cookies() async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") }
    }

    /// Loads music.youtube.com in a hidden web view on this store and reads its `ytcfg`.
    /// Only a WEB_REMIX page counts: signed out, iPhone is redirected to m.youtube.com.
    func pageConfig() async -> PageConfig? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        hidden = webView
        defer { hidden = nil }
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: URL(string: Self.origin + "/")!))
            // Never wait on the page forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.finishLoad()
            }
        }
        let script = """
        const c = (window.ytcfg && ytcfg.get) ? ytcfg : null;
        const ctx = c ? (c.get('INNERTUBE_CONTEXT') || {}) : {};
        return {
          loggedIn: c ? !!c.get('LOGGED_IN') : false,
          clientName: ctx.client ? ctx.client.clientName : null,
          clientVersion: ctx.client ? ctx.client.clientVersion : null,
          sessionIndex: c && c.get('SESSION_INDEX') !== undefined ? String(c.get('SESSION_INDEX')) : null,
          delegated: c ? (c.get('DELEGATED_SESSION_ID') || null) : null,
          visitor: c ? (c.get('VISITOR_DATA') || null) : null,
        };
        """
        guard let result = (try? await webView.callAsyncJavaScript(script, contentWorld: .page)) as? [String: Any],
              result["clientName"] as? String == "WEB_REMIX" else {
            Self.log.info("page config unavailable (host \(webView.url?.host() ?? "-", privacy: .public))")
            return nil
        }
        let config = PageConfig(loggedIn: result["loggedIn"] as? Bool ?? false,
                                clientVersion: result["clientVersion"] as? String,
                                sessionIndex: result["sessionIndex"] as? String,
                                delegatedSessionID: result["delegated"] as? String,
                                visitorData: result["visitor"] as? String)
        // Presence and the public client version only.
        Self.log.info("page config: loggedIn \(config.loggedIn) client \(config.clientVersion ?? "-", privacy: .public) brand \(config.delegatedSessionID != nil)")
        return config
    }

    private func finishLoad() {
        loaded?.resume()
        loaded = nil
    }

    /// App-local sign-out: removes everything this store holds. The server session is not revoked.
    func clear() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        Self.log.info("local sign-out: \(records.count) records removed")
    }

    /// The official sign-in, in a web view on this store.
    func signInView() -> AnyView {
        AnyView(SignInWebView(store: store).ignoresSafeArea(edges: .bottom))
    }
}

extension WebKitSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === hidden { finishLoad() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === hidden { finishLoad() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === hidden { finishLoad() }
    }
}

/// Google sign-in and YouTube Music in a web view on the app's store. Logs host and path only.
private struct SignInWebView: UIViewRepresentable {
    let store: WKWebsiteDataStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: WebKitSession.origin + "/")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private static let log = Logger(subsystem: "MusicPrototype", category: "Auth")
        private var reissued: Set<URL> = []

        /// A cross-site youtube.com GET would open the YouTube app as a universal link;
        /// loading it again in this view keeps the sign-in here (public API only).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let host = url.host(),
                  action.targetFrame?.isMainFrame ?? true, action.request.httpMethod == "GET",
                  host.hasSuffix("youtube.com"), webView.url?.host() != host, !reissued.contains(url)
            else { decisionHandler(.allow); return }
            reissued.insert(url)
            decisionHandler(.cancel)
            Self.log.info("sign-in: reissued \(host, privacy: .public)\(url.path(), privacy: .public)")
            webView.load(action.request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.log.info("sign-in: \(webView.url?.host() ?? "-", privacy: .public)\(webView.url?.path() ?? "", privacy: .public)")
        }

        /// Pop-ups (window.open) open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
