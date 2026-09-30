import Foundation
import OSLog

// Direct Format Resolver: videoId → a playable audio URL for the signed-in session.
// The engine only sees `ResolvedAudio` / `ResolutionError`; the solver, the player JS, their
// versions and caches are replaceable parts behind this actor. Nothing here logs or persists
// URLs, signatures, n values or cookies. Reference: `Spikes/WebPlayerSpike` (B3–B3.3).

/// A playable audio stream for one video, valid until `expiresAt`.
struct ResolvedAudio: Sendable {
    let videoID: String
    let url: URL
    let itag: Int
    /// The service's length (`approxDurationMs`); AVPlayer's own is wrong for these files as served.
    let duration: Double?
    let expiresAt: Date?
    /// Diagnostics: milliseconds per resolution phase.
    var timings: [String: Int] = [:]

    func isFresh(for seconds: TimeInterval, skew: TimeInterval = 0) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow - skew > seconds
    }
}

enum ResolutionError: LocalizedError {
    case signedOut
    case unplayable(String)
    case noAudioFormat
    case solverUnavailable(String)
    case solverFailed(String)
    case unreachable(Int)
    case http(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "YouTube Music에 로그인되어 있지 않거나 세션이 만료되었습니다."
        case .unplayable: "이 곡은 여기에서 재생할 수 없습니다."
        case .noAudioFormat: "재생할 수 있는 오디오 형식이 없습니다."
        case .solverUnavailable, .solverFailed: "재생 준비에 실패했습니다. 잠시 후 다시 시도하세요."
        case .unreachable(let status), .http(let status): "오디오를 불러오지 못했습니다 (HTTP \(status))."
        case .malformed: "재생 정보를 해석하지 못했습니다."
        }
    }

    /// Short label for logs (no values).
    var label: String {
        switch self {
        case .signedOut: "signedOut"
        case .unplayable(let r): "unplayable(\(r))"
        case .noAudioFormat: "noAudioFormat"
        case .solverUnavailable(let r): "solverUnavailable(\(r))"
        case .solverFailed(let r): "solverFailed(\(r))"
        case .unreachable(let s): "unreachable(\(s))"
        case .http(let s): "http(\(s))"
        case .malformed(let r): "malformed(\(r))"
        }
    }
}

// MARK: Replaceable parts

/// The web player's JS for the current player version, which the solver runs.
struct PlayerJS: Sendable {
    let id: String
    let signatureTimestamp: Int
    let source: String
}

protocol PlayerJSProvider: Sendable {
    func current() async throws -> PlayerJS
}

struct Solved: Sendable {
    let n: [String: String]
    let sig: [String: String]
    /// Diagnostics: solver-internal milliseconds and which path ran (numbers/labels only).
    var diagnostics: [String: Int] = [:]
}

protocol SignatureSolver: Sendable {
    /// Identity for logs and cache keys (e.g. "ejs 0.8.0").
    var identity: String { get }
    func solve(_ player: PlayerJS, n: [String], sig: [String]) async throws -> Solved
}

// MARK: Resolver

actor PlaybackResolver {
    private let credentials: SessionCredentialStore
    private let playerJS: PlayerJSProvider
    private let solver: SignatureSolver
    private static let origin = "https://music.youtube.com"
    private static let log = Logger(subsystem: "MusicPrototype", category: "Playback")
    /// AAC in MP4 (AVFoundation); 141 first. Opus is WebM.
    static let preferredItags = [141, 140]

    init(credentials: SessionCredentialStore, playerJS: PlayerJSProvider, solver: SignatureSolver) {
        self.credentials = credentials
        self.playerJS = playerJS
        self.solver = solver
    }

    /// Per-call timings: resolves overlap (current track and prefetch), so no shared state.
    private func timed<T>(_ name: String, _ phase: inout [String: Int], _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            phase[name, default: 0] += Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
        return try await body()
    }

    func resolve(_ videoID: String) async throws -> ResolvedAudio {
        var phase: [String: Int] = [:]
        let player = try await timed("playerJS", &phase) { try await playerJS.current() }
        let root = try await timed("player", &phase) { try await playerResponse(videoID, sts: player.signatureTimestamp) }
        let playability = root.dict("playabilityStatus")
        guard playability?["status"] as? String == "OK" else {
            throw ResolutionError.unplayable(playability?["status"] as? String ?? "?")
        }
        let formats = root.dict("streamingData")?["adaptiveFormats"] as? [[String: Any]] ?? []
        guard let format = Self.preferredItags.lazy.compactMap({ itag in formats.first { $0["itag"] as? Int == itag } }).first,
              let itag = format["itag"] as? Int else { throw ResolutionError.noAudioFormat }

        // Both challenges first; one solver call per resolve.
        var comps: URLComponents
        var sig: (s: String, sp: String)?
        if let direct = (format["url"] as? String).flatMap(URLComponents.init(string:)) {
            comps = direct
        } else if let cipher = format["signatureCipher"] as? String {
            let q = URLComponents(string: "x:?" + cipher)?.queryItems ?? []
            func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
            guard let s = v("s"), let raw = v("url"), let parsed = URLComponents(string: raw) else {
                throw ResolutionError.malformed("signatureCipher")
            }
            comps = parsed
            sig = (s, v("sp") ?? "signature")
        } else {
            throw ResolutionError.noAudioFormat
        }
        let n = comps.queryItems?.first { $0.name == "n" }?.value
        let solved = try await timed("solve", &phase) {
            try await solver.solve(player, n: n.map { [$0] } ?? [], sig: sig.map { [$0.s] } ?? [])
        }
        for (key, value) in solved.diagnostics { phase["solver." + key] = value }
        if let n {
            guard let t = solved.n[n] else { throw ResolutionError.solverFailed("n unsolved") }
            comps.queryItems = comps.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: t) : $0 }
        }
        if let sig {
            guard let value = solved.sig[sig.s] else { throw ResolutionError.solverFailed("sig unsolved") }
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: sig.sp, value: value)]
        }
        guard let url = comps.url else { throw ResolutionError.malformed("url") }
        // A wrong transform (a changed player the solver no longer understands) shows up as 403 here.
        let status = await timed("probe", &phase) { await Self.probe(url) }
        guard status == 206 || status == 200 else { throw ResolutionError.unreachable(status) }

        let length = (format["approxDurationMs"] as? String).flatMap(Double.init).map { $0 / 1000 }
            ?? (root.dict("videoDetails")?["lengthSeconds"] as? String).flatMap(Double.init)
        let expire = comps.queryItems?.first { $0.name == "expire" }?.value
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return ResolvedAudio(videoID: videoID, url: url, itag: itag, duration: length, expiresAt: expire, timings: phase)
    }

    private func playerResponse(_ videoID: String, sts: Int) async throws -> [String: Any] {
        let credential: SessionCredential
        do { credential = try await credentials.current() } catch { throw ResolutionError.signedOut }
        let clientVersion = credential.clientVersion ?? InnerTubeClient.fallbackClientVersion
        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        for (name, value) in credential.headers(origin: Self.origin) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor = credential.visitorID { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let pageID = credential.pageID { request.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId") }
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "ko", "gl": "KR"]
        if let visitor = credential.visitorID { client["visitorData"] = visitor }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
            "context": ["client": client],
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": sts, "html5Preference": "HTML5_PREF_WANTS"]],
        ] as [String: Any])
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            await credentials.markRejected()
            throw ResolutionError.signedOut
        }
        guard status == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolutionError.http(status)
        }
        if (try? JSON(data: data))?.loggedIn == false {
            await credentials.markRejected()
            throw ResolutionError.signedOut
        }
        return root
    }

    static func probe(_ url: URL) async -> Int {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let response = try? await URLSession(configuration: .ephemeral).data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}

private extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

/// Current web player JS from music.youtube.com, cached by player id in memory and Caches.
actor WebPlayerJSProvider: PlayerJSProvider {
    private var cached: PlayerJS?
    private var checkedAt: Date?
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    func current() async throws -> PlayerJS {
        // The page names the player version; re-check it at most every 30 minutes.
        if let cached, let checkedAt, Date().timeIntervalSince(checkedAt) < 1800 { return cached }
        var home = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        home.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let html = String(decoding: try await URLSession.shared.data(for: home).0, as: UTF8.self)
        guard let range = html.range(of: #""jsUrl":"([^"]+)""#, options: .regularExpression) else { throw ResolutionError.malformed("jsUrl") }
        let path = String(html[range].dropFirst(9).dropLast())
        let id = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? path
        checkedAt = Date()
        if let cached, cached.id == id { return cached }
        let file = URL.cachesDirectory.appending(path: "player-\(id).js")
        let source: String
        if let data = try? Data(contentsOf: file) {
            source = String(decoding: data, as: UTF8.self)
        } else {
            var request = URLRequest(url: URL(string: "https://music.youtube.com" + path)!)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            let data = try await URLSession.shared.data(for: request).0
            // Keep only the current version's copy.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: URL.cachesDirectory.path())) ?? []
            where name.hasPrefix("player-") && name.hasSuffix(".js") {
                try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: name))
            }
            try? data.write(to: file)
            source = String(decoding: data, as: UTF8.self)
        }
        guard let sts = source.range(of: #"signatureTimestamp:\d+"#, options: .regularExpression)
            .flatMap({ Int(source[$0].split(separator: ":").last ?? "") }) else { throw ResolutionError.malformed("sts") }
        let player = PlayerJS(id: id, signatureTimestamp: sts, source: source)
        cached = player
        return player
    }
}
