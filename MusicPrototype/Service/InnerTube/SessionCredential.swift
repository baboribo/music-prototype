import CryptoKit
import Foundation

/// The user's own signed-in music.youtube.com session: the app's WebKit store, or (development)
/// a browser export file outside the repository. Values stay in memory: never logged, persisted
/// or copied. A cookie can stop working at any time (sign-out elsewhere, rotation), so it is only
/// ever handed out through `SessionCredentialStore`.
struct SessionCredential: Sendable {
    private let cookie: String
    private let authUser: String
    /// The session's own visitor id; requests must not mix it with an anonymous one.
    let visitorID: String?
    /// The signed-in page's own client version, when known.
    var clientVersion: String?
    /// A brand channel's delegated session (`X-Goog-PageId`), when the page names one.
    var pageID: String?

    private init(cookie: String, authUser: String, visitorID: String?) {
        self.cookie = cookie
        self.authUser = authUser
        self.visitorID = visitorID
    }

    /// From the WebKit store's cookies and the signed-in page's config.
    init(cookies: [HTTPCookie], page: WebKitSession.PageConfig?) {
        self.init(cookie: HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? "",
                  authUser: page?.sessionIndex ?? "0", visitorID: page?.visitorData)
        clientVersion = page?.clientVersion
        pageID = page?.delegatedSessionID
    }

    enum LoadError: LocalizedError {
        case insideRepository
        case unreadable
        case noCookie

        var errorDescription: String? {
            switch self {
            case .insideRepository: "세션·녹화 파일은 저장소 밖에 있어야 합니다."
            case .unreadable: "세션 파일을 읽을 수 없습니다."
            case .noCookie: "세션 파일에 Cookie 헤더가 없습니다."
            }
        }
    }

    /// Accepts a browser "copy all request headers" export
    /// (`{"requestHeaders": {"headers": [{name, value}]}}`) or a raw cookie line.
    /// A recorded `Authorization` is ignored; a fresh signature is derived per request.
    static func load(path: String) throws -> SessionCredential {
        let file = try ExternalFile.validate(path)
        guard let text = try? String(contentsOfFile: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { throw LoadError.unreadable }
        if text.hasPrefix("{") {
            let json = try JSON(data: Data(text.utf8))
            let entries = json.at("requestHeaders.headers")?.array ?? json["headers"]?.array ?? []
            func header(_ name: String) -> String? {
                entries.first { $0["name"]?.string?.caseInsensitiveCompare(name) == .orderedSame }?["value"]?.string
            }
            guard let cookie = header("Cookie") else { throw LoadError.noCookie }
            return SessionCredential(cookie: cookie, authUser: header("X-Goog-AuthUser") ?? "0",
                                     visitorID: header("X-Goog-Visitor-Id"))
        }
        let line = text.hasPrefix("Cookie:") ? String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) : text
        guard !line.isEmpty else { throw LoadError.noCookie }
        return SessionCredential(cookie: line, authUser: "0", visitorID: nil)
    }

    /// What the web client itself sends for a signed-in request.
    func headers(origin: String) -> [String: String] {
        var headers = ["Cookie": cookie, "X-Goog-AuthUser": authUser, "X-Origin": origin]
        // "<scheme> <ts>_<sha1(ts value origin)>", one per cookie variant present.
        let ts = Int(Date().timeIntervalSince1970)
        let parts = [("SAPISIDHASH", "SAPISID"), ("SAPISID1PHASH", "__Secure-1PAPISID"), ("SAPISID3PHASH", "__Secure-3PAPISID")]
            .compactMap { scheme, name -> String? in
                guard let value = cookieValue(name) else { return nil }
                let digest = Insecure.SHA1.hash(data: Data("\(ts) \(value) \(origin)".utf8))
                return "\(scheme) \(ts)_\(digest.map { String(format: "%02x", $0) }.joined())"
            }
        if !parts.isEmpty { headers["Authorization"] = parts.joined(separator: " ") }
        return headers
    }

    private func cookieValue(_ name: String) -> String? {
        for pair in cookie.split(separator: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }
}

/// Hands out the current credential and remembers which one the server rejected.
///
/// - `.webKit`: the app's WebKit store (production). A cookie set the server rejected is
///   identified by an in-memory fingerprint and not sent again; signing in again changes it.
/// - `.file`: a browser export outside the repository (development). Once rejected, that version
///   of the file is not sent again; replacing the file (a fresh sign-in) is picked up.
actor SessionCredentialStore {
    enum Source: Sendable {
        case webKit(WebKitSession)
        case file(String)
    }

    private let source: Source
    private var loaded: (credential: SessionCredential, version: Date?)?
    /// Modification date of the file version the server rejected.
    private var rejectedVersion: Date??
    private var rejectedFingerprint: String?
    private var page: (fingerprint: String, task: Task<WebKitSession.PageConfig?, Never>)?
    private var lastFingerprint: String?
    private var onRejected: (@Sendable () -> Void)?

    init(source: Source) { self.source = source }

    /// Called whenever the server rejects the session (for the account state).
    func setOnRejected(_ handler: @escaping @Sendable () -> Void) { onRejected = handler }

    func current() async throws -> SessionCredential {
        switch source {
        case .file(let path):
            let version = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let rejectedVersion, rejectedVersion == version { throw CatalogError.signedOut }
            if let loaded, loaded.version == version { return loaded.credential }
            let credential = try SessionCredential.load(path: path)
            loaded = (credential, version)
            rejectedVersion = nil
            return credential
        case .webKit(let session):
            let cookies = await session.cookies()
            guard let fingerprint = Self.fingerprint(cookies) else { throw CatalogError.signedOut }
            if fingerprint == rejectedFingerprint { throw CatalogError.signedOut }
            lastFingerprint = fingerprint
            // The page config (client version, account index, visitor) is read once per signed-in session.
            if page?.fingerprint != fingerprint {
                page = (fingerprint, Task { await session.pageConfig() })
            }
            let config = await page?.task.value
            return SessionCredential(cookies: cookies, page: config)
        }
    }

    /// Whether a usable session is there now (no request is made).
    func isSignedIn() async -> Bool {
        do {
            _ = try await current()
            if case .webKit = source, let config = await page?.task.value, !config.loggedIn { return false }
            return true
        } catch {
            return false
        }
    }

    func markRejected() {
        switch source {
        case .file: rejectedVersion = .some(loaded?.version); loaded = nil
        case .webKit: rejectedFingerprint = lastFingerprint; page = nil
        }
        onRejected?()
    }

    /// After a sign-in or sign-out: forget what was learned about the previous session.
    func reset() {
        rejectedFingerprint = nil
        rejectedVersion = nil
        page = nil
        loaded = nil
    }

    /// Identifies the signed-in cookie set without keeping its values (SHA-256, memory only).
    /// Nil when the store holds no signed-in session.
    private static func fingerprint(_ cookies: [HTTPCookie]) -> String? {
        let names = ["SAPISID", "__Secure-3PAPISID", "SID", "__Secure-3PSID"]
        let values = names.compactMap { name in cookies.first { $0.name == name }.map { "\(name)=\($0.value)" } }
        guard values.contains(where: { $0.hasPrefix("SAPISID=") || $0.hasPrefix("__Secure-3PAPISID=") }) else { return nil }
        return SHA256.hash(data: Data(values.joined(separator: ";").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Session files and recorded responses hold account data; they must live outside the repository.
enum ExternalFile {
    /// Two levels above this file's folder (`MusicPrototype/Service/InnerTube`).
    private static let repositoryRoot: String = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .standardizedFileURL.resolvingSymlinksInPath().path()

    static func validate(_ path: String) throws -> String {
        let resolved = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path()
        if resolved.hasPrefix(repositoryRoot) { throw SessionCredential.LoadError.insideRepository }
        return resolved
    }
}
