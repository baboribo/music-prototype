import SwiftUI
import WebKit

/// Fresh-store auth end to end: an isolated WebKit data store (its id kept in UserDefaults so
/// it survives relaunch), an in-app sign-in sheet, and checks that log metadata only —
/// cookie names/flags/lifetimes, page config presence, HTTP status, logged_in, entitlement.
@MainActor
@Observable
final class AuthE2E: NSObject, WKNavigationDelegate {
    private(set) var lines: [String] = []
    private(set) var storeID: UUID
    private(set) var store: WKWebsiteDataStore
    private(set) var busy = false
    private let file = URL.documentsDirectory.appending(path: "auth-e2e.log")
    private static let storeKey = "authE2E.storeID"
    /// Page config read from a signed-in music.youtube.com page (values stay in memory).
    private var page: PageConfig?
    private var hidden: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Never>?

    struct PageConfig {
        let loggedIn: Bool
        let clientName: String?
        let clientVersion: String?
        let sessionIndex: String?
        let delegatedSession: String?
        let visitorData: String?
    }

    override init() {
        let defaults = UserDefaults.standard
        let id: UUID
        let isNew: Bool
        if let text = defaults.string(forKey: Self.storeKey), let saved = UUID(uuidString: text) {
            id = saved
            isNew = false
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: Self.storeKey)
            isNew = true
        }
        storeID = id
        store = WKWebsiteDataStore(forIdentifier: id)
        super.init()
        log("launch", ["store": isNew ? "new" : "existing"])
    }

    func log(_ kind: String, _ body: [String: Any]) {
        var entry = body
        entry["kind"] = kind
        entry["t"] = Int(Date().timeIntervalSince1970)
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        if !FileManager.default.fileExists(atPath: file.path()) { try? Data().write(to: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    // MARK: Checks

    /// Cookies (metadata) → page config → one native InnerTube request.
    func check(_ reason: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        log("check", ["reason": reason])
        await inventory()
        await readPage()
        await nativeRequest()
    }

    func inventory() async {
        let cookies = await store.httpCookieStore.allCookies()
        let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        let google = cookies.filter { $0.domain.hasSuffix("google.com") }
        let auth = youtube.filter { AuthProbe.authNames.contains($0.name) }
        log("cookies", [
            "youtube": youtube.count, "google": google.count, "authCount": auth.count,
            "auth": auth.map { c in
                "\(c.name)|\(c.domain)|http\(c.isHTTPOnly ? 1 : 0)|sec\(c.isSecure ? 1 : 0)|\(c.expiresDate.map { "\(Int($0.timeIntervalSinceNow / 86400))d" } ?? "session")"
            }.sorted(),
        ])
    }

    /// Loads music.youtube.com in a hidden web view on the same store and reads ytcfg.
    func readPage() async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        webView.navigationDelegate = self
        hidden = webView
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        }
        let js = """
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
        let result = (try? await webView.callAsyncJavaScript(js, contentWorld: .page)) as? [String: Any] ?? [:]
        let config2 = PageConfig(
            loggedIn: result["loggedIn"] as? Bool ?? false,
            clientName: result["clientName"] as? String, clientVersion: result["clientVersion"] as? String,
            sessionIndex: result["sessionIndex"] as? String, delegatedSession: result["delegated"] as? String,
            visitorData: result["visitor"] as? String)
        page = config2
        // Presence and public version only; session index is a small integer, not a secret.
        log("page", [
            "host": webView.url?.host() ?? "?", "loggedIn": config2.loggedIn,
            "client": "\(config2.clientName ?? "-") \(config2.clientVersion ?? "-")",
            "sessionIndex": config2.sessionIndex ?? "-", "brandChannel": config2.delegatedSession != nil,
            "hasVisitorData": config2.visitorData != nil,
        ])
        hidden = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard webView === self.hidden else { return }
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard webView === self.hidden else { return }
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    /// The app's own request, with credentials taken from the store at request time and the
    /// page's client version / account index. Classified the way the main app does.
    func nativeRequest() async {
        await nativeRequest(browseId: "FEmusic_library_landing")
        // An artist page response carries has_unlimited_entitlement (library landing doesn't).
        await nativeRequest(browseId: "UCTUR0sVEkD8T5MlSHqgaI_Q")
    }

    private func nativeRequest(browseId: String) async {
        let origin = "https://music.youtube.com"
        let url = URL(string: "\(origin)/youtubei/v1/browse?prettyPrint=false")!
        let cookies = await store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") }
        // Only a signed-in YTM page's config applies; signed out, music.youtube.com redirects
        // to m.youtube.com (MWEB) on iPhone.
        let usable = page.flatMap { $0.clientName == "WEB_REMIX" ? $0 : nil }
        let clientVersion = usable?.clientVersion ?? WebController.remix.version
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(usable?.sessionIndex ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let delegated = usable?.delegatedSession { request.setValue(delegated, forHTTPHeaderField: "X-Goog-PageId") }
        if let visitor = usable?.visitorData { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let auth = AuthProbe.sapisidHash(cookies, origin: origin) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "ko", "gl": "KR"]
        if let visitor = usable?.visitorData { client["visitorData"] = visitor }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["browseId": browseId, "context": ["client": client]])
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let params = Self.trackingParams(data)
            let loggedIn = params["logged_in"]
            // Same rule as the main app's InnerTubeClient.
            let outcome = status == 401 || status == 403 ? "signedOut(http)" : status != 200 ? "http error" : loggedIn == "0" ? "signedOut(logged_in=0)" : "ok"
            log("native", ["browse": browseId.hasPrefix("FE") ? browseId : "artist", "status": status, "logged_in": loggedIn ?? "?", "premium": params["has_unlimited_entitlement"] ?? "?",
                           "cookiesSent": cookies.count, "clientVersion": clientVersion,
                           "configFromPage": usable != nil, "outcome": outcome])
        } catch {
            log("native", ["error": (error as NSError).localizedDescription])
        }
    }

    nonisolated static func trackingParams(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = (root["responseContext"] as? [String: Any])?["serviceTrackingParams"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for service in services {
            for param in service["params"] as? [[String: Any]] ?? [] {
                if let key = param["key"] as? String, ["logged_in", "has_unlimited_entitlement"].contains(key) {
                    out[key] = param["value"] as? String
                }
            }
        }
        return out
    }

    // MARK: Local logout

    /// App-local sign-out: removes this app store's website data. No server-side logout.
    func localLogout() async {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        page = nil
        log("localLogout", ["recordsRemoved": records.count])
        await check("after local logout")
    }
}

struct AuthE2EView: View {
    @State private var auth = AuthE2E()
    @State private var showingSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Sign in") { showingSignIn = true }.accessibilityIdentifier("e2e.signin")
                Button("Check") { Task { await auth.check("manual") } }.accessibilityIdentifier("e2e.check")
                Button("Local logout") { Task { await auth.localLogout() } }.accessibilityIdentifier("e2e.logout")
            }
            .buttonStyle(.borderedProminent)
            .disabled(auth.busy)
            Text("store …\(auth.storeID.uuidString.suffix(4))").font(.caption.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(auth.lines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task { await auth.check("launch") }
        .sheet(isPresented: $showingSignIn, onDismiss: { Task { await auth.check("sign-in sheet closed") } }) {
            NavigationStack {
                SignInWebView(store: auth.store, log: auth.log)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("YouTube Music")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("완료") { showingSignIn = false } }
                    }
            }
        }
    }
}

/// The official sign-in in a web view on the isolated store. Logs host and path only.
struct SignInWebView: UIViewRepresentable {
    let store: WKWebsiteDataStore
    let log: (String, [String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(log: log) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.userContentController.add(context.coordinator, name: "probe")
        config.userContentController.addUserScript(
            WKUserScript(source: NetworkObserverScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let log: (String, [String: Any]) -> Void
        private var reissued: Set<URL> = []

        init(log: @escaping (String, [String: Any]) -> Void) { self.log = log }

        /// Same universal-link handling as the player spike: re-issue cross-site youtube.com GETs.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let host = url.host(),
                  action.targetFrame?.isMainFrame ?? true, action.request.httpMethod == "GET",
                  host.hasSuffix("youtube.com"), webView.url?.host() != host, !reissued.contains(url)
            else { decisionHandler(.allow); return }
            reissued.insert(url)
            decisionHandler(.cancel)
            log("signin.reissue", ["host": host, "path": url.path()])
            webView.load(action.request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("signin.nav", ["host": webView.url?.host() ?? "?", "path": webView.url?.path() ?? "?"])
        }

        /// Pop-ups (window.open) open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "net",
                  let path = body["path"] as? String,
                  path.contains("subscription") || path.contains("/att/") || path.contains("Waa")
            else { return }
            log("signin.net", ["host": body["host"] ?? "?", "path": path])
        }
    }
}
