import CryptoKit
import Foundation
import JavaScriptCore

// Signature/n solver for direct audio formats. Replaceable behind `SignatureSolver`; only a
// pinned release whose files match their sha256 ever runs. Extracted from the B3 spike
// (`Spikes/WebPlayerSpike`), which stays as the reference.

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
        // Another solve may have finished loading while this one waited.
        if let context { return context }
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
