import CryptoKit
import Foundation
import WebKit

/// Auth/session feasibility with public WebKit API only. Evidence is logged without
/// values: cookie names, flags and lifetimes; HTTP status and the server's logged_in.
/// Nothing here is persisted besides what WebKit's own data store keeps.
@MainActor
final class AuthProbe: NSObject, WKHTTPCookieStoreObserver {
    private let log: ProbeLog
    private weak var store: WKHTTPCookieStore?
    /// Names of auth cookies last seen, to report additions/removals/rotation.
    private var lastAuth: [String: Date?] = [:]

    /// Cookies the web client's signed-in requests depend on (names only).
    static let authNames: Set<String> = [
        "SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID", "SID", "__Secure-1PSID", "__Secure-3PSID",
        "HSID", "SSID", "APISID", "LOGIN_INFO", "SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
    ]

    init(log: ProbeLog) { self.log = log }

    func attach(_ webView: WKWebView) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        self.store = store
        store.add(self)
    }

    // MARK: Cookie store

    /// Which auth cookies exist for youtube.com, their flags and remaining lifetime.
    func inventory() async {
        guard let store else { return }
        let cookies = await store.allCookies()
        let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        let auth = youtube.filter { Self.authNames.contains($0.name) }
        log.append("auth.inventory", [
            "youtubeCookies": youtube.count,
            "authCookies": auth.map { c in
                [
                    "name": c.name, "domain": c.domain, "httpOnly": c.isHTTPOnly, "secure": c.isSecure,
                    "session": c.isSessionOnly,
                    "expiresInDays": c.expiresDate.map { Int($0.timeIntervalSinceNow / 86400) } ?? -1,
                ] as [String: Any]
            }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") },
        ])
        lastAuth = Dictionary(auth.map { ($0.name + "@" + $0.domain, $0.expiresDate) }, uniquingKeysWith: { a, _ in a })
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.reportChange(cookieStore) }
    }

    /// Rotation / sign-out evidence: which auth cookies appeared, vanished or got a new expiry.
    private func reportChange(_ cookieStore: WKHTTPCookieStore) async {
        let auth = await cookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") && Self.authNames.contains($0.name) }
        let now = Dictionary(auth.map { ($0.name + "@" + $0.domain, $0.expiresDate) }, uniquingKeysWith: { a, _ in a })
        let added = Set(now.keys).subtracting(lastAuth.keys).sorted()
        let removed = Set(lastAuth.keys).subtracting(now.keys).sorted()
        let renewed = now.keys.filter { lastAuth[$0] != nil && lastAuth[$0]! != now[$0]! }.sorted()
        guard !(added.isEmpty && removed.isEmpty && renewed.isEmpty) else { return }
        lastAuth = now
        log.append("auth.cookiesChanged", ["added": added, "removed": removed, "renewed": renewed])
    }

    // MARK: Native request with the web view's session

    /// One signed-in InnerTube request from native code, built from the web view's cookie
    /// store (Cookie header + per-request SAPISIDHASH, as the web client does).
    func nativeRequest(client: (name: String, id: String, version: String)) async {
        guard let store else { return }
        let origin = "https://music.youtube.com"
        let url = URL(string: "\(origin)/youtubei/v1/browse?prettyPrint=false")!
        let cookies = await store.allCookies().filter { $0.domain.hasSuffix("youtube.com") }
        guard !cookies.isEmpty else { log.append("auth.native", ["result": "noCookies"]); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let auth = Self.sapisidHash(cookies, origin: origin) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "browseId": "FEmusic_library_landing",
            "context": ["client": ["clientName": client.name, "clientVersion": client.version, "hl": "ko", "gl": "KR"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Set-Cookie names only: does a native request rotate anything the web view would need?
            let setCookies = (response as? HTTPURLResponse).map { HTTPCookie.cookies(withResponseHeaderFields: $0.allHeaderFields as? [String: String] ?? [:], for: url).map(\.name) } ?? []
            log.append("auth.native", ["client": client.name, "status": status, "loggedIn": Self.loggedIn(data) ?? "?",
                                       "bytes": data.count, "setCookieNames": setCookies.sorted()])
        } catch {
            log.append("auth.native", ["client": client.name, "error": (error as NSError).localizedDescription])
        }
    }

    nonisolated static func sapisidHash(_ cookies: [HTTPCookie], origin: String) -> String? {
        let ts = Int(Date().timeIntervalSince1970)
        let parts = [("SAPISIDHASH", "SAPISID"), ("SAPISID1PHASH", "__Secure-1PAPISID"), ("SAPISID3PHASH", "__Secure-3PAPISID")]
            .compactMap { scheme, name -> String? in
                guard let value = cookies.first(where: { $0.name == name })?.value else { return nil }
                let digest = Insecure.SHA1.hash(data: Data("\(ts) \(value) \(origin)".utf8))
                return "\(scheme) \(ts)_\(digest.map { String(format: "%02x", $0) }.joined())"
            }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    nonisolated static func loggedIn(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = root["responseContext"] as? [String: Any],
              let services = context["serviceTrackingParams"] as? [[String: Any]] else { return nil }
        for service in services {
            for param in service["params"] as? [[String: Any]] ?? [] where param["key"] as? String == "logged_in" {
                return param["value"] as? String
            }
        }
        return nil
    }

    // MARK: Page context

    /// What the loaded page itself says about its session and client (booleans and names only).
    func pageState(_ webView: WKWebView) async {
        let js = """
        const c = (window.ytcfg && ytcfg.get) ? ytcfg : null;
        const ctx = c ? (c.get('INNERTUBE_CONTEXT') || {}) : {};
        return {
          host: location.host,
          hasYtcfg: !!c,
          loggedIn: c ? c.get('LOGGED_IN') : null,
          clientName: ctx.client ? ctx.client.clientName : null,
          clientVersion: ctx.client ? ctx.client.clientVersion : null,
          hasDelegatedSession: c ? !!c.get('DELEGATED_SESSION_ID') : null,
          hasSessionIndex: c ? c.get('SESSION_INDEX') !== undefined : null,
          jsCanReadSAPISID: document.cookie.split('; ').some(p => p.startsWith('SAPISID=')),
        };
        """
        do {
            let result = try await webView.callAsyncJavaScript(js, contentWorld: .page)
            log.append("auth.page", (result as? [String: Any]) ?? ["result": "none"])
        } catch {
            log.append("auth.page", ["error": (error as NSError).localizedDescription])
        }
    }

    // MARK: Logout (isolated store only)

    /// Logout = removing this app's website data for YouTube/Google. Exercised on a separate
    /// identifier store so the user's signed-in default store is never touched.
    func logoutOnIsolatedStore() async {
        let id = UUID()
        let (before, after, records) = await Self.fillAndClear(id)
        // The store object must be released before its identifier can be deleted.
        try? await Task.sleep(for: .seconds(1))
        var removedStore = "no"
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: id)
            removedStore = "yes"
        } catch {
            removedStore = (error as NSError).localizedDescription
        }
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        log.append("auth.logoutIsolated", ["cookiesBefore": before, "cookiesAfter": after, "records": records,
                                           "storeRemoved": removedStore, "identifierStillListed": identifiers.contains(id)])
    }

    private static func fillAndClear(_ id: UUID) async -> (Int, Int, Int) {
        let isolated = WKWebsiteDataStore(forIdentifier: id)
        // A harmless marker cookie stands in for a session.
        let marker = HTTPCookie(properties: [
            .domain: ".youtube.com", .path: "/", .name: "SPIKE_MARKER", .value: "1", .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600),
        ])!
        await isolated.httpCookieStore.setCookie(marker)
        let before = await isolated.httpCookieStore.allCookies().count
        let records = await isolated.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let targets = records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") }
        await isolated.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets)
        let after = await isolated.httpCookieStore.allCookies().count
        return (before, after, targets.count)
    }
}

/// Paths of the page's own network calls (no bodies, no queries), to see which
/// endpoints and attestation steps the official web flow uses.
enum NetworkObserverScript {
    static let source = """
    (() => {
      const post = (kind, url) => {
        try {
          const u = new URL(url, location.href);
          const interesting = u.pathname.includes('/youtubei/') || /attest|botguard|\\/bg\\/|waa|jnn-pa|\\/att\\//i.test(u.host + u.pathname);
          if (interesting) window.webkit.messageHandlers.probe.postMessage({kind: 'net', via: kind, host: u.host, path: u.pathname});
        } catch (_) {}
      };
      const fetch0 = window.fetch;
      window.fetch = function (input, init) {
        post('fetch', typeof input === 'string' ? input : (input && input.url));
        return fetch0.apply(this, arguments);
      };
      const open0 = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        post('xhr', url);
        return open0.apply(this, arguments);
      };
      const beacon0 = navigator.sendBeacon ? navigator.sendBeacon.bind(navigator) : null;
      if (beacon0) navigator.sendBeacon = function (url, data) { post('beacon', url); return beacon0(url, data); };
    })();
    """
}
