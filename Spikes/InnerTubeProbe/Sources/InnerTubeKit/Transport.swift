import Foundation

/// One InnerTube client identity. Data and playback may use different ones,
/// so nothing here is global.
public struct ClientIdentity: Sendable, Hashable {
    public let label: String
    public let name: String
    public let version: String
    public let nameID: Int
    public let host: String
    public let userAgent: String
    public let extra: [String: JSON]
    /// Web clients send the player's signature timestamp with /player.
    public let isWeb: Bool
    /// True when the version was not taken from a maintained reference.
    public let versionIsGuess: Bool

    public static let webRemix = ClientIdentity(
        label: "WEB_REMIX", name: "WEB_REMIX", version: "1.20260927.17.00", nameID: 67,
        host: "music.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        extra: [:], isWeb: true, versionIsGuess: false)

    public static let web = ClientIdentity(
        label: "WEB", name: "WEB", version: "2.20260708.00.00", nameID: 1,
        host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        extra: [:], isWeb: true, versionIsGuess: false)

    public static let webSafari = ClientIdentity(
        label: "WEB_SAFARI", name: "WEB", version: "2.20260708.00.00", nameID: 1,
        host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        extra: [:], isWeb: true, versionIsGuess: false)

    public static let ios = ClientIdentity(
        label: "IOS", name: "IOS", version: "21.26.4", nameID: 5,
        host: "youtubei.googleapis.com",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"],
        isWeb: false, versionIsGuess: false)

    /// Not defined by yt-dlp or YouTube.js as of 2026-09; version is a guess.
    public static let iosMusic = ClientIdentity(
        label: "IOS_MUSIC", name: "IOS_MUSIC", version: "8.34.2", nameID: 26,
        host: "youtubei.googleapis.com",
        userAgent: "com.google.ios.youtubemusic/8.34.2 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"],
        isWeb: false, versionIsGuess: true)

    public static let all: [ClientIdentity] = [.webRemix, .web, .webSafari, .ios, .iosMusic]

    public static func named(_ label: String) -> ClientIdentity? {
        all.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    func context(visitorData: String?) -> JSON {
        var client: [String: JSON] = [
            "clientName": .string(name), "clientVersion": .string(version),
            "hl": "ko", "gl": "KR",
        ]
        if !isWeb { client["userAgent"] = .string(userAgent) }
        if let visitorData { client["visitorData"] = .string(visitorData) }
        client.merge(extra) { $1 }
        return ["client": .object(client)]
    }
}

public struct InnerTubeResponse: Sendable {
    public let status: Int
    public let json: JSON?
    public let byteCount: Int
    /// nil when the request went out anonymously.
    public let auth: String?

    /// The server's own view of the session (`logged_in`, `has_unlimited_entitlement`).
    public func tracking(_ key: String) -> String? {
        json?.at("responseContext.serviceTrackingParams")?.array
            .flatMap { $0["params"]?.array ?? [] }
            .first { $0["key"]?.string == key }?["value"]?.string
    }
}

public enum InnerTubeError: Error, CustomStringConvertible {
    case notHTTP
    case bootstrap(String)
    public var description: String {
        switch self {
        case .notHTTP: "non-HTTP response"
        case .bootstrap(let s): "bootstrap failed: \(s)"
        }
    }
}

/// Anonymous InnerTube transport. Authentication is deliberately absent:
/// data and playback auth are decided separately after compatibility tests.
public final class InnerTubeTransport: Sendable {
    let session: URLSession
    public let visitorData: String?
    public let signatureTimestamp: Int?
    let auth: AuthMaterial?

    public init(visitorData: String?, signatureTimestamp: Int?, auth: AuthMaterial? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        self.visitorData = visitorData
        self.signatureTimestamp = signatureTimestamp
        self.auth = auth
    }

    public func authenticated(_ auth: AuthMaterial?) -> InnerTubeTransport {
        InnerTubeTransport(visitorData: visitorData, signatureTimestamp: signatureTimestamp, auth: auth)
    }

    /// Reads the public `VISITOR_DATA` and the web player's `signatureTimestamp`
    /// the way the web client itself does on page load.
    public static func bootstrap() async throws -> InnerTubeTransport {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.setValue(ClientIdentity.webRemix.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ko-KR,ko;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let visitor = html.firstCapture(#""VISITOR_DATA":"([^"]+)""#) else {
            throw InnerTubeError.bootstrap("VISITOR_DATA not found")
        }
        var sts: Int?
        if let jsPath = html.firstCapture(#""jsUrl":"([^"]+)""#),
           let jsURL = URL(string: "https://music.youtube.com" + jsPath) {
            let (js, _) = try await session.data(from: jsURL)
            sts = String(decoding: js, as: UTF8.self)
                .firstCapture(#"signatureTimestamp:(\d+)"#).flatMap(Int.init)
        }
        return InnerTubeTransport(visitorData: visitor, signatureTimestamp: sts)
    }

    public func post(_ endpoint: String, client: ClientIdentity, body: [String: JSON]) async throws -> InnerTubeResponse {
        var url = URLComponents()
        url.scheme = "https"
        url.host = client.host
        url.path = "/youtubei/v1/\(endpoint)"
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.nameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if client.isWeb {
            request.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
            request.setValue("https://\(client.host)/", forHTTPHeaderField: "Referer")
        }
        let usedAuth = auth.flatMap { $0.applies(to: client) ? $0 : nil }
        let visitor = usedAuth?.visitorID ?? visitorData
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let usedAuth {
            for (k, v) in usedAuth.headers(origin: "https://\(client.host)") { request.setValue(v, forHTTPHeaderField: k) }
        }
        var payload = body
        payload["context"] = client.context(visitorData: visitor)
        request.httpBody = try JSONEncoder().encode(JSON.object(payload))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InnerTubeError.notHTTP }
        return InnerTubeResponse(status: http.statusCode,
                                 json: try? JSONDecoder().decode(JSON.self, from: data),
                                 byteCount: data.count, auth: usedAuth?.label)
    }
}

extension String {
    func firstCapture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
