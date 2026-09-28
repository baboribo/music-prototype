import Foundation
import OSLog

/// One InnerTube request/response exchange; live or replayed.
protocol InnerTubeTransport: Sendable {
    func post(_ endpoint: String, body: [String: JSON]) async throws -> JSON
}

/// Signed-in WEB_REMIX requests to music.youtube.com's InnerTube API (browse data
/// only; no playback). Client version from yt-dlp master, 2026-09.
struct InnerTubeClient: InnerTubeTransport {
    private static let host = "music.youtube.com"
    private static let clientName = "WEB_REMIX"
    private static let clientNameID = "67"
    private static let clientVersion = "1.20260707.12.00"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private let store: SessionCredentialStore
    private let session: URLSession
    private static let log = Logger(subsystem: "MusicPrototype", category: "InnerTube")

    init(store: SessionCredentialStore) {
        self.store = store
        // No cookie jar: the only cookies sent are the session's own, per request.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func post(_ endpoint: String, body: [String: JSON]) async throws -> JSON {
        // Throws without a request when this session version was already rejected.
        let credential = try await store.current()
        let origin = "https://\(Self.host)"
        var request = URLRequest(url: URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        if let visitor = credential.visitorID { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        for (name, value) in credential.headers(origin: origin) { request.setValue(value, forHTTPHeaderField: name) }

        var client: [String: JSON] = [
            "clientName": .string(Self.clientName), "clientVersion": .string(Self.clientVersion),
            "hl": "ko", "gl": "KR",
        ]
        if let visitor = credential.visitorID { client["visitorData"] = .string(visitor) }
        var payload = body
        payload["context"] = ["client": .object(client)]
        request.httpBody = try JSONSerialization.data(withJSONObject: JSON.object(payload).foundationValue)

        Self.log.info("request \(endpoint, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CatalogError.unexpectedResponse }
        // A rejected request signature or revoked cookie.
        if status == 401 || status == 403 {
            Self.log.info("session rejected (HTTP \(status))")
            await store.markRejected()
            throw CatalogError.signedOut
        }
        guard status == 200 else { throw CatalogError.http(status) }
        let json = try JSON(data: data)
        // An expired or signed-out cookie still gets 200, as an anonymous response.
        if json.loggedIn == false {
            Self.log.info("session rejected (logged_in=0)")
            await store.markRejected()
            throw CatalogError.signedOut
        }
        return json
    }
}

extension JSON {
    /// The server's own view of the session (`logged_in` tracking param).
    var loggedIn: Bool? {
        at("responseContext.serviceTrackingParams")?.array
            .flatMap { $0["params"]?.array ?? [] }
            .first { $0["key"]?.string == "logged_in" }?["value"]?.string
            .map { $0 == "1" }
    }
}
