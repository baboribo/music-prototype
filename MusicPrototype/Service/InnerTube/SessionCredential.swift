import CryptoKit
import Foundation

/// The user's own signed-in music.youtube.com browser session, read from a file
/// outside the repository. Values stay in memory: never logged, persisted or copied.
/// A static cookie can stop working at any time (sign-out elsewhere, rotation),
/// so it is only ever handed out through `SessionCredentialStore`.
struct SessionCredential: Sendable {
    private let cookie: String
    private let authUser: String
    /// The session's own visitor id; requests must not mix it with an anonymous one.
    let visitorID: String?

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

/// Owns the session file and its known validity. Once the server rejects the
/// session, that version of the file is never sent again; replacing the file at
/// the same path (a fresh sign-in) makes the next request pick it up.
actor SessionCredentialStore {
    private let path: String
    private var loaded: (credential: SessionCredential, version: Date?)?
    /// Modification date of the file version the server rejected.
    private var rejectedVersion: Date??

    init(path: String) { self.path = path }

    func current() throws -> SessionCredential {
        let version = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let rejectedVersion, rejectedVersion == version { throw CatalogError.signedOut }
        if let loaded, loaded.version == version { return loaded.credential }
        let credential = try SessionCredential.load(path: path)
        loaded = (credential, version)
        rejectedVersion = nil
        return credential
    }

    func markRejected() {
        rejectedVersion = .some(loaded?.version)
        loaded = nil
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
