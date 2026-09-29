import CryptoKit
import Foundation
import JavaScriptCore
import WebKit

// Direct Format Resolver (spike): videoId → a playable audio URL for this session.
// UI, queue and player only see `ResolvedAudio`/`ResolutionError`; the solver, the player
// JS, their versions and caches are replaceable parts behind `PlaybackResolver`.
// Nothing here logs or persists URLs, signatures, n values or cookies.

/// A playable audio stream for one video, valid until `expiresAt`.
struct ResolvedAudio: Sendable {
    let videoID: String
    let url: URL
    let itag: Int
    let mimeType: String
    /// The service's length (`lengthSeconds` / `approxDurationMs`); AVPlayer's own can be wrong.
    let duration: Double?
    let title: String
    let artist: String
    let artworkURL: URL?
    let expiresAt: Date?
    /// Diagnostics: milliseconds per resolution phase.
    var timings: [String: Int] = [:]
}

enum ResolutionError: Error, CustomStringConvertible {
    case signedOut
    case unplayable(String)
    case noAudioFormat
    case solverUnavailable(String)
    case solverFailed(String)
    case unreachable(Int)
    case http(Int)
    case malformed(String)

    var description: String {
        switch self {
        case .signedOut: "signedOut"
        case .unplayable(let r): "unplayable(\(r))"
        case .noAudioFormat: "noAudioFormat"
        case .solverUnavailable(let r): "solverUnavailable(\(r))"
        case .solverFailed(let r): "solverFailed(\(r))"
        case .unreachable(let s): "unreachable(HTTP \(s))"
        case .http(let s): "http(\(s))"
        case .malformed(let r): "malformed(\(r))"
        }
    }
}

// MARK: Replaceable parts

/// Where signed-in cookies come from (WebKit store in the app; a file in development).
protocol SessionCookieSource: Sendable {
    func cookies() async -> [HTTPCookie]
}

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
    private let session: SessionCookieSource
    private let playerJS: PlayerJSProvider
    private let solver: SignatureSolver
    static let origin = "https://music.youtube.com"
    static let clientVersion = "1.20260927.17.00"
    /// AAC first: AVPlayer on iOS plays MP4/AAC; Opus is in WebM.
    static let preferredItags = [141, 140]

    init(session: SessionCookieSource, playerJS: PlayerJSProvider, solver: SignatureSolver) {
        self.session = session
        self.playerJS = playerJS
        self.solver = solver
    }

    private var phase: [String: Int] = [:]

    private func timed<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            phase[name, default: 0] += Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
        return try await body()
    }

    func resolve(_ videoID: String) async throws -> ResolvedAudio {
        phase = [:]
        let player = try await timed("playerJS") { try await playerJS.current() }
        let root = try await timed("player") { try await playerResponse(videoID, sts: player.signatureTimestamp) }
        let playability = root.dict("playabilityStatus")
        guard playability?["status"] as? String == "OK" else {
            throw ResolutionError.unplayable(playability?["status"] as? String ?? "?")
        }
        let formats = root.dict("streamingData")?["adaptiveFormats"] as? [[String: Any]] ?? []
        guard let format = Self.preferredItags.lazy.compactMap({ itag in formats.first { $0["itag"] as? Int == itag } }).first,
              let itag = format["itag"] as? Int else { throw ResolutionError.noAudioFormat }

        // Collect both challenges first; one solver call per resolve.
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
        let solved = try await timed("solve") {
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
        // A wrong transform shows up as 403 here, before the player sees the URL.
        let status = await timed("probe") { await Self.probe(url) }
        guard status == 206 || status == 200 else { throw ResolutionError.unreachable(status) }

        let details = root.dict("videoDetails")
        // The format's own length in ms is the precise end of the audio; lengthSeconds is rounded.
        let length = (format["approxDurationMs"] as? String).flatMap(Double.init).map { $0 / 1000 }
            ?? (details?["lengthSeconds"] as? String).flatMap(Double.init)
        let thumbs = (details?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expire" }?.value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return ResolvedAudio(
            videoID: videoID, url: url, itag: itag, mimeType: format["mimeType"] as? String ?? "?",
            duration: length, title: details?["title"] as? String ?? "", artist: details?["author"] as? String ?? "",
            artworkURL: (thumbs.last?["url"] as? String).flatMap(URL.init(string:)), expiresAt: expire, timings: phase)
    }

    private func playerResponse(_ videoID: String, sts: Int) async throws -> [String: Any] {
        let cookies = await session.cookies()
        guard !cookies.isEmpty else { throw ResolutionError.signedOut }
        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let auth = AuthProbe.sapisidHash(cookies, origin: Self.origin) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.clientVersion, "hl": "ko", "gl": "KR"]],
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": sts, "html5Preference": "HTML5_PREF_WANTS"]],
        ] as [String: Any])
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 { throw ResolutionError.signedOut }
        guard status == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolutionError.http(status)
        }
        if AuthE2E.trackingParams(data)["logged_in"] == "0" { throw ResolutionError.signedOut }
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

// MARK: Implementations used by the spike

/// The Auth tab's isolated WebKit store; kept referenced (a released identifier store returns no cookies).
@MainActor
final class WebKitCookieSource: SessionCookieSource {
    private var store: WKWebsiteDataStore?

    nonisolated func cookies() async -> [HTTPCookie] {
        await MainActor.run { self.storeRef() }?.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") } ?? []
    }

    private func storeRef() -> WKWebsiteDataStore? {
        if let store { return store }
        guard let text = UserDefaults.standard.string(forKey: "authE2E.storeID"), let id = UUID(uuidString: text) else { return nil }
        store = WKWebsiteDataStore(forIdentifier: id)
        return store
    }
}

/// Current web player JS from music.youtube.com, cached by player id in memory and Caches.
actor WebPlayerJSProvider: PlayerJSProvider {
    private var cached: PlayerJS?
    private var checkedAt: Date?
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    func current() async throws -> PlayerJS {
        // The page names the player version; re-check it at most every 30 minutes.
        if let cached, let checkedAt, Date().timeIntervalSince(checkedAt) < 1800 { return cached }
        var home = URLRequest(url: URL(string: "\(PlaybackResolver.origin)/")!)
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
            var request = URLRequest(url: URL(string: PlaybackResolver.origin + path)!)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            let data = try await URLSession.shared.data(for: request).0
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

/// A pinned solver release: exact files and sha256. Never "latest".
struct SolverRelease: Sendable {
    let name: String
    let version: String
    let baseURL: URL
    let files: [(name: String, sha256: String)]

    static let ejs080 = SolverRelease(
        name: "yt-dlp/ejs", version: "0.8.0",
        baseURL: URL(string: "https://github.com/yt-dlp/ejs/releases/download/0.8.0/")!,
        files: [("yt.solver.lib.js", "770831df5c46474fbff06732315b28f4fb090e427ca669a51da61e2457d41c82"),
                ("yt.solver.core.js", "ca259e4e3cdd37d92fc266d9af08d4fd66da8479e240f4d984f29da402c22ead")])
}

/// Runs a pinned ejs release in JavaScriptCore. Files come from Caches or the release URL,
/// and are used only if their hash matches; otherwise resolution fails.
///
/// One JSContext lives for the solver's lifetime (the actor serializes its use). The expensive
/// step — parsing the 2.6 MB player JS into ejs's preprocessed form — happens once per player
/// version; the result stays in the context as a JS global and in Caches for the next launch.
/// A new player version drops both and prepares again.
actor JSCSolver: SignatureSolver {
    nonisolated let identity: String
    private let release: SolverRelease
    private var context: JSContext?
    /// Player id whose preprocessed form is loaded in `context` (global `__pre`).
    private var loadedPlayerID: String?

    init(release: SolverRelease) {
        self.release = release
        identity = "\(release.name) \(release.version)"
    }

    func solve(_ player: PlayerJS, n: [String], sig: [String]) async throws -> Solved {
        var diagnostics: [String: Int] = [:]
        func ms(_ start: ContinuousClock.Instant) -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        let requests: [[String: Any]] = [["type": "n", "challenges": n], ["type": "sig", "challenges": sig]]

        var start = ContinuousClock.now
        let context = try await readyContext()
        diagnostics["context"] = ms(start)

        if loadedPlayerID == player.id {
            start = ContinuousClock.now
            if let solved = try? run(context, preprocessed: true, player: nil, requests: requests), solved.complete(n: n, sig: sig) {
                diagnostics["cachedRun"] = ms(start)
                diagnostics["path.memory"] = 1
                return Solved(n: solved.n, sig: solved.sig, diagnostics: diagnostics)
            }
            loadedPlayerID = nil  // unusable: prepare again below
        }

        // Another player version (or none yet): forget the old one, then try this version's disk copy.
        let file = preprocessedFile(player.id)
        if loadedPlayerID != player.id {
            loadedPlayerID = nil
            context.setObject(nil, forKeyedSubscript: "__pre" as NSString)
            removeOtherPreprocessed(keeping: file)
        }
        start = ContinuousClock.now
        if let data = try? Data(contentsOf: file) {
            context.setObject(String(decoding: data, as: UTF8.self), forKeyedSubscript: "__pre" as NSString)
            diagnostics["diskLoad"] = ms(start)
            start = ContinuousClock.now
            if let solved = try? run(context, preprocessed: true, player: nil, requests: requests), solved.complete(n: n, sig: sig) {
                loadedPlayerID = player.id
                diagnostics["cachedRun"] = ms(start)
                diagnostics["path.disk"] = 1
                return Solved(n: solved.n, sig: solved.sig, diagnostics: diagnostics)
            }
            try? FileManager.default.removeItem(at: file)  // stale or corrupt copy
        }

        // Full player: solve and keep the preprocessed form.
        start = ContinuousClock.now
        let solved = try run(context, preprocessed: false, player: player.source, requests: requests)
        diagnostics["fullRun"] = ms(start)
        diagnostics["path.full"] = 1
        guard solved.complete(n: n, sig: sig) else { throw ResolutionError.solverFailed("incomplete") }
        if let pre = context.objectForKeyedSubscript("__pre"), !pre.isUndefined, !pre.isNull, let text = pre.toString() {
            loadedPlayerID = player.id
            try? Data(text.utf8).write(to: file)
        }
        return Solved(n: solved.n, sig: solved.sig, diagnostics: diagnostics)
    }

    /// One `jsc(...)` call. The preprocessed player stays in JS (`__pre`); only small values cross the bridge.
    private func run(_ context: JSContext, preprocessed: Bool, player: String?, requests: [[String: Any]]) throws -> Solved {
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.setObject(requests, forKeyedSubscript: "__req" as NSString)
        let script: String
        if preprocessed {
            script = "JSON.stringify(jsc({type: 'preprocessed', preprocessed_player: __pre, requests: __req}).responses)"
        } else {
            context.setObject(player, forKeyedSubscript: "__player" as NSString)
            script = """
            (function () {
              const out = jsc({type: 'player', player: __player, requests: __req, output_preprocessed: true});
              __pre = out.preprocessed_player; __player = undefined;
              return JSON.stringify(out.responses);
            })()
            """
        }
        guard let output = context.evaluateScript(script)?.toString(), exception == nil,
              let responses = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], responses.count == 2 else {
            throw ResolutionError.solverFailed("run: \(exception?.prefix(80) ?? "no output")")
        }
        return Solved(n: responses[0]["data"] as? [String: String] ?? [:], sig: responses[1]["data"] as? [String: String] ?? [:])
    }

    /// The long-lived context with the verified solver loaded.
    private func readyContext() async throws -> JSContext {
        if let context { return context }
        let sources = try await load()
        guard let context = JSContext() else { throw ResolutionError.solverFailed("JSContext") }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(sources[0])
        context.evaluateScript("var meriyah = lib.meriyah, astring = lib.astring; var __pre;")
        context.evaluateScript(sources[1])
        if let exception { throw ResolutionError.solverFailed("load: \(exception.prefix(80))") }
        self.context = context
        return context
    }

    private func preprocessedFile(_ playerID: String) -> URL {
        URL.cachesDirectory.appending(path: "solver-\(release.version)").appending(path: "preprocessed-\(playerID).js")
    }

    private func removeOtherPreprocessed(keeping file: URL) {
        let dir = file.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
        where name.hasPrefix("preprocessed-") && name != file.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    private func load() async throws -> [String] {
        let dir = URL.cachesDirectory.appending(path: "solver-\(release.version)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String] = []
        for file in release.files {
            let local = dir.appending(path: file.name)
            var data = try? Data(contentsOf: local)
            if data.map(Self.sha256) != file.sha256 {
                data = try? await URLSession.shared.data(from: release.baseURL.appending(path: file.name)).0
                guard let fetched = data, Self.sha256(fetched) == file.sha256 else {
                    throw ResolutionError.solverUnavailable("hash mismatch \(file.name)")
                }
                try? fetched.write(to: local)
            }
            out.append(String(decoding: data!, as: UTF8.self))
        }
        return out
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private extension Solved {
    func complete(n: [String], sig: [String]) -> Bool {
        n.allSatisfy { self.n[$0] != nil } && sig.allSatisfy { self.sig[$0] != nil }
    }
}
