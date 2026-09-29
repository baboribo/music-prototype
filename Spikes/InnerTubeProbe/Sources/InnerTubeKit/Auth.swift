import CryptoKit
import Foundation

/// The account's own credentials, read from a file outside the repository.
/// Values never leave memory: no logging, no dumps.
public enum AuthMaterial: Sendable {
    /// Signed-in music.youtube.com session. `visitorID` is the session's own
    /// visitor id, which replaces the anonymous one when present.
    case cookie(String, authUser: String, visitorID: String?)
    /// OAuth access token from the device flow with the user's own client.
    case bearer(String)

    public var label: String {
        switch self {
        case .cookie: "cookie"
        case .bearer: "oauth"
        }
    }

    /// The cookie line (in memory only), for requests outside InnerTube.
    public var cookieHeader: String? {
        if case .cookie(let c, _, _) = self { c } else { nil }
    }

    var visitorID: String? {
        if case .cookie(_, _, let v) = self { v } else { nil }
    }

    /// Accepts `{"access_token": …}`, a browser "copy all headers" export
    /// (`{"requestHeaders": {"headers": [{name, value}]}}`), or a raw cookie line.
    /// A recorded `Authorization` is ignored: it is a timestamped signature,
    /// so a fresh one is derived from the cookie per request.
    public static func load(path: String) throws -> AuthMaterial {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{"), let json = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) {
            if let token = json["access_token"]?.string { return .bearer(token) }
            let entries = json.at("requestHeaders.headers")?.array ?? json["headers"]?.array ?? []
            func header(_ name: String) -> String? {
                entries.first { $0["name"]?.string?.caseInsensitiveCompare(name) == .orderedSame }?["value"]?.string
            }
            guard let cookie = header("Cookie") else { throw InnerTubeError.bootstrap("no Cookie header in auth file") }
            return .cookie(cookie, authUser: header("X-Goog-AuthUser") ?? "0", visitorID: header("X-Goog-Visitor-Id"))
        }
        let line = text.hasPrefix("Cookie:") ? String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) : text
        return .cookie(line, authUser: "0", visitorID: nil)
    }

    /// Whether this client identity accepts this kind of credential at all.
    /// Web clients sign requests with cookies; app clients use OAuth.
    public func applies(to client: ClientIdentity) -> Bool {
        switch self {
        case .cookie: client.isWeb
        case .bearer: true
        }
    }

    func headers(origin: String) -> [String: String] {
        switch self {
        case .bearer(let token):
            return ["Authorization": "Bearer \(token)"]
        case .cookie(let cookie, let authUser, _):
            var headers = ["Cookie": cookie, "X-Goog-AuthUser": authUser, "X-Origin": origin]
            // The web client's own request signature, one per cookie variant:
            // "<scheme> <ts>_<sha1(ts value origin)>".
            let ts = Int(Date().timeIntervalSince1970)
            let parts = [("SAPISIDHASH", "SAPISID"), ("SAPISID1PHASH", "__Secure-1PAPISID"), ("SAPISID3PHASH", "__Secure-3PAPISID")]
                .compactMap { scheme, name -> String? in
                    guard let value = cookie.firstCapture(#"(?:^|;\s*)"# + NSRegularExpression.escapedPattern(for: name) + #"=([^;]+)"#) else { return nil }
                    let digest = Insecure.SHA1.hash(data: Data("\(ts) \(value) \(origin)".utf8))
                    return "\(scheme) \(ts)_\(digest.map { String(format: "%02x", $0) }.joined())"
                }
            if !parts.isEmpty { headers["Authorization"] = parts.joined(separator: " ") }
            return headers
        }
    }
}

/// RFC 8628 device authorization with the user's own OAuth client
/// ("TVs and Limited Input devices"). No third-party client IDs are embedded.
public enum DeviceFlow {
    public static func run(clientID: String, clientSecret: String, writeTo path: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        func form(_ url: String, _ fields: [String: String]) async throws -> JSON {
            var r = URLRequest(url: URL(string: url)!)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
            let (data, _) = try await session.data(for: r)
            return try JSONDecoder().decode(JSON.self, from: data)
        }
        let code = try await form("https://oauth2.googleapis.com/device/code",
                                  ["client_id": clientID, "scope": "https://www.googleapis.com/auth/youtube"])
        guard let deviceCode = code["device_code"]?.string else {
            print("device code request failed: \(code["error"]?.string ?? "?") \(code["error_description"]?.string ?? "")")
            return
        }
        print("Open \(code["verification_url"]?.string ?? "https://www.google.com/device") and enter \(code["user_code"]?.string ?? "?")")
        var interval = UInt64(code["interval"]?.number ?? 5)
        while true {
            try await Task.sleep(for: .seconds(interval))
            let token = try await form("https://oauth2.googleapis.com/token", [
                "client_id": clientID, "client_secret": clientSecret, "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch token["error"]?.string {
            case nil:
                FileManager.default.createFile(atPath: path, contents: try JSONEncoder().encode(token),
                                               attributes: [.posixPermissions: 0o600])
                print("token saved (scope: \(token["scope"]?.string ?? "?"), expires in \(Int(token["expires_in"]?.number ?? 0))s)")
                return
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case let error?: print("token error: \(error)"); return
            }
        }
    }
}
