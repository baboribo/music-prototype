import AVFoundation
import CryptoKit
import JavaScriptCore
import SwiftUI
import WebKit

/// B2 on-device smoke test (spike only, temporary): signed-in /player from the Auth tab's
/// isolated WebKit store → yt-dlp/ejs 0.8.0 solver run in JavaScriptCore on the device →
/// AVPlayer on the transformed itag 141 URL. The solver is downloaded at run time (pinned
/// release, sha256-checked) into Caches; it is not part of the repository or the main app.
/// Logs carry numbers and states only — never URLs, signatures, n values or cookies.
@MainActor
@Observable
final class PlaybackSmoke {
    private(set) var lines: [String] = []
    private(set) var running = false
    private var player: AVPlayer?
    private var sampler: Task<Void, Never>?
    /// Kept alive while in use: a released identifier store answers cookie queries with nothing.
    private var authStore: WKWebsiteDataStore?
    private let file = URL.documentsDirectory.appending(path: "playback.log")

    static let videoID = "NnRjwEhFU70"  // 밤편지 (ATV), the track used in every B2 step
    static let solverFiles: [(name: String, sha256: String)] = [
        ("yt.solver.lib.js", "770831df5c46474fbff06732315b28f4fb090e427ca669a51da61e2457d41c82"),
        ("yt.solver.core.js", "ca259e4e3cdd37d92fc266d9af08d4fd66da8479e240f4d984f29da402c22ead"),
    ]
    private static let origin = "https://music.youtube.com"
    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    func log(_ kind: String, _ body: [String: Any]) {
        var entry = body
        entry["kind"] = kind
        entry["t"] = (Date().timeIntervalSince1970 * 10).rounded() / 10
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        if !FileManager.default.fileExists(atPath: file.path()) { try? Data().write(to: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        stop()
        log("run", ["video": Self.videoID])
        do {
            let solverSources = try await loadSolver()
            let (playerJS, sts, playerID) = try await loadPlayerJS()
            log("playerJS", ["id": playerID, "sts": sts, "bytes": playerJS.utf8.count])
            let format = try await playerRequest(sts: sts)
            let started = Date()
            let solved = try await Self.solve(solverSources, player: playerJS, n: format.n.map { [$0] } ?? [], sig: [format.s])
            log("solver", ["ms": Int(Date().timeIntervalSince(started) * 1000), "nSolved": solved.n.count, "sigSolved": solved.sig.count,
                           "nChanged": format.n.map { solved.n[$0] != $0 } ?? false, "errors": solved.errors])
            guard let sig = solved.sig[format.s] else { throw SmokeError.step("sig unsolved") }
            var comps = format.base
            comps.queryItems = (comps.queryItems ?? []).map { item in
                if item.name == "n", let n = format.n, let t = solved.n[n] { URLQueryItem(name: "n", value: t) } else { item }
            } + [URLQueryItem(name: format.sp, value: sig)]
            guard let url = comps.url else { throw SmokeError.step("url") }
            await reach(url)
            play(url, expectedSeconds: format.approxSeconds)
        } catch {
            log("error", ["step": "\(error)"])
        }
    }

    enum SmokeError: Error, CustomStringConvertible {
        case step(String)
        var description: String { if case .step(let s) = self { s } else { "?" } }
    }

    // MARK: Solver (pinned release, verified)

    private func loadSolver() async throws -> [String] {
        let dir = URL.cachesDirectory.appending(path: "ejs-0.8.0")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sources: [String] = []
        for (name, sha) in Self.solverFiles {
            let local = dir.appending(path: name)
            var data = try? Data(contentsOf: local)
            if data.map(Self.sha256) != sha {
                let remote = URL(string: "https://github.com/yt-dlp/ejs/releases/download/0.8.0/\(name)")!
                data = try await URLSession.shared.data(from: remote).0
                guard let fetched = data, Self.sha256(fetched) == sha else { throw SmokeError.step("solver hash mismatch \(name)") }
                try fetched.write(to: local)
            }
            sources.append(String(decoding: data!, as: UTF8.self))
        }
        log("solverFiles", ["version": "0.8.0", "verified": true])
        return sources
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: Player JS (public)

    private func loadPlayerJS() async throws -> (String, Int, String) {
        var home = URLRequest(url: URL(string: "\(Self.origin)/")!)
        home.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        let html = String(decoding: try await URLSession.shared.data(for: home).0, as: UTF8.self)
        guard let range = html.range(of: #""jsUrl":"([^"]+)""#, options: .regularExpression) else { throw SmokeError.step("jsUrl") }
        let path = String(html[range].dropFirst(9).dropLast())
        var request = URLRequest(url: URL(string: Self.origin + path)!)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        let js = String(decoding: try await URLSession.shared.data(for: request).0, as: UTF8.self)
        guard let stsRange = js.range(of: #"signatureTimestamp:\d+"#, options: .regularExpression),
              let sts = Int(js[stsRange].split(separator: ":").last ?? "") else { throw SmokeError.step("sts") }
        let playerID = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? "?"
        return (js, sts, playerID)
    }

    // MARK: Signed-in /player with the Auth tab's store

    struct Format {
        let base: URLComponents
        let sp: String
        let s: String
        let n: String?
        let approxSeconds: Double?
    }

    private func playerRequest(sts: Int) async throws -> Format {
        guard let text = UserDefaults.standard.string(forKey: "authE2E.storeID"), let id = UUID(uuidString: text) else {
            throw SmokeError.step("no auth store (sign in on the Auth tab first)")
        }
        let store = authStore ?? WKWebsiteDataStore(forIdentifier: id)
        authStore = store
        let cookies = await store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") }
        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(WebController.remix.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let auth = AuthProbe.sapisidHash(cookies, origin: Self.origin) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "videoId": Self.videoID, "contentCheckOk": true, "racyCheckOk": true,
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": WebController.remix.version, "hl": "ko", "gl": "KR"]],
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": sts, "html5Preference": "HTML5_PREF_WANTS"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let status = (root["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let params = AuthE2E.trackingParams(data)
        let formats = ((root["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]) ?? []
        log("player", ["http": (response as? HTTPURLResponse)?.statusCode ?? -1, "playability": status,
                       "logged_in": params["logged_in"] ?? "?", "premium": params["has_unlimited_entitlement"] ?? "?",
                       "adaptiveFormats": formats.count, "cookiesSent": cookies.count])
        guard let f = formats.first(where: { ($0["itag"] as? Int) == 141 }), let cipher = f["signatureCipher"] as? String else {
            throw SmokeError.step("no ciphered itag 141")
        }
        let q = URLComponents(string: "x:?" + cipher)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        guard let s = v("s"), let raw = v("url"), let base = URLComponents(string: raw) else { throw SmokeError.step("cipher fields") }
        let approx = (f["approxDurationMs"] as? String).flatMap(Double.init).map { $0 / 1000 }
        return Format(base: base, sp: v("sp") ?? "signature", s: s, n: base.queryItems?.first { $0.name == "n" }?.value, approxSeconds: approx)
    }

    // MARK: JavaScriptCore

    struct Solved: Sendable { let n: [String: String]; let sig: [String: String]; let errors: [String] }

    /// Runs the solver off the main actor in a fresh JSContext (nothing leaves this function but results).
    nonisolated static func solve(_ sources: [String], player: String, n: [String], sig: [String]) async throws -> Solved {
        try await Task.detached(priority: .userInitiated) {
            guard let context = JSContext() else { throw SmokeError.step("JSContext") }
            var exception: String?
            context.exceptionHandler = { _, value in exception = value?.toString() }
            context.evaluateScript(sources[0])
            context.evaluateScript("var meriyah = lib.meriyah, astring = lib.astring;")
            context.evaluateScript(sources[1])
            if let exception { throw SmokeError.step("solver load: \(exception.prefix(120))") }
            let input: [String: Any] = ["type": "player", "player": player,
                                        "requests": [["type": "n", "challenges": n], ["type": "sig", "challenges": sig]]]
            context.setObject(input, forKeyedSubscript: "__input" as NSString)
            guard let output = context.evaluateScript("JSON.stringify(jsc(__input))")?.toString(), exception == nil,
                  let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let responses = root["responses"] as? [[String: Any]] else {
                throw SmokeError.step("solver run: \(exception?.prefix(120) ?? "no output")")
            }
            var result: [[String: String]] = [[:], [:]]
            var errors: [String] = []
            for (i, r) in responses.enumerated() where i < 2 {
                if let data = r["data"] as? [String: String] { result[i] = data } else { errors.append(String("\(r["error"] ?? "?")".prefix(120))) }
            }
            return Solved(n: result[0], sig: result[1], errors: errors)
        }.value
    }

    // MARK: Reachability and playback

    private func reach(_ url: URL) async {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (data, response) = (try? await URLSession(configuration: .ephemeral).data(for: request)) ?? (Data(), URLResponse())
        log("reach", ["http": (response as? HTTPURLResponse)?.statusCode ?? -1, "bytes": data.count])
    }

    private func play(_ url: URL, expectedSeconds: Double?) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        let start = Date()
        player.play()
        log("play", ["expectedSeconds": expectedSeconds.map { Int($0) } ?? -1])
        sampler = Task { @MainActor [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let status = switch item.status { case .readyToPlay: "ready"; case .failed: "failed"; default: "unknown" }
                let control = switch player.timeControlStatus { case .playing: "playing"; case .paused: "paused"; default: "waiting" }
                let access = item.accessLog()?.events ?? []
                self.log("sample", [
                    "wall": Int(Date().timeIntervalSince(start)), "pos": (player.currentTime().seconds * 10).rounded() / 10,
                    "item": status, "control": control,
                    "duration": item.duration.seconds.isFinite ? Int(item.duration.seconds) : -1,
                    "requests": access.reduce(0) { $0 + $1.numberOfMediaRequests },
                    "kib": access.reduce(0) { $0 + $1.numberOfBytesTransferred } / 1024,
                    "stalls": access.reduce(0) { $0 + $1.numberOfStalls },
                    "error": item.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "",
                ])
            }
            self?.stop()
            self?.log("done", [:])
        }
    }

    func stop() {
        sampler?.cancel()
        sampler = nil
        player?.pause()
        player = nil
    }
}

struct PlaybackSmokeView: View {
    @State private var smoke = PlaybackSmoke()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Run smoke test") { Task { await smoke.run() } }.accessibilityIdentifier("smoke.run")
                Button("Stop") { smoke.stop() }.accessibilityIdentifier("smoke.stop")
            }
            .buttonStyle(.borderedProminent)
            .disabled(smoke.running)
            Text("밤편지 · itag 141 · on-device solver (temporary)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(smoke.lines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task {
            // SPIKE_AUTOSMOKE=1 (devicectl launch): run once without a tap.
            if ProcessInfo.processInfo.environment["SPIKE_AUTOSMOKE"] == "1" { await smoke.run() }
        }
    }
}
