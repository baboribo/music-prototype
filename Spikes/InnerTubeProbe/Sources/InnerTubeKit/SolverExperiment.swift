import Foundation

/// B2.2: apply the player's own sig/n transforms (computed by an external solver process)
/// to this session's media URLs and report HTTP status only. URLs, signatures and n values
/// stay in memory and in the solver's stdin/stdout pipe; nothing is printed or dumped.
public enum SolverExperiment {
    public struct Report: Sendable {
        public var lines: [String] = []
    }

    /// `solver`: node script reading {player_path, n, sig} on stdin, writing {n, sig, errors} on stdout.
    public static func run(_ transport: InnerTubeTransport, videoID: String, playerPath: String, solver: String) async -> [String] {
        await runReturningURL(transport, videoID: videoID, playerPath: playerPath, solver: solver).lines
    }

    /// Also returns the sig+n URL of itag 141 (in memory only) for an AVPlayer smoke test.
    public static func runReturningURL(_ transport: InnerTubeTransport, videoID: String, playerPath: String, solver: String) async -> (lines: [String], playable: URL?) {
        var playable: URL?
        var out: [String] = []
        // WEB_REMIX: ciphered adaptive audio.
        var remixItems: [(itag: Int, base: URLComponents, sp: String, s: String, n: String?, length: Int?)] = []
        if let (response, _) = try? await PlayerProbe.request(transport, client: .webRemix, videoID: videoID), let json = response.json {
            out.append("WEB_REMIX /player: \(json.at("playabilityStatus.status")?.string ?? "?")")
            for f in json.at("streamingData.adaptiveFormats")?.array ?? [] {
                guard let itag = f["itag"]?.number.map(Int.init), [140, 141, 251, 774].contains(itag),
                      let cipher = f["signatureCipher"]?.string else { continue }
                let q = URLComponents(string: "x:?" + cipher)?.queryItems ?? []
                func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
                guard let s = v("s"), let raw = v("url"), let comps = URLComponents(string: raw) else { continue }
                let n = comps.queryItems?.first { $0.name == "n" }?.value
                remixItems.append((itag, comps, v("sp") ?? "signature", s, n, f["contentLength"]?.string.flatMap(Int.init)))
            }
        }
        // WEB_SAFARI: HLS, server-signed segments carrying n in the path.
        var segment: URL?
        if let (_, summary) = try? await PlayerProbe.request(transport, client: .webSafari, videoID: videoID), let master = summary?.hlsManifest {
            segment = await firstSegment(master)
        }
        let segN = segment.flatMap { pathValue($0, key: "n") }

        let challengesN = Array(Set(remixItems.compactMap(\.n) + (segN.map { [$0] } ?? [])))
        let challengesSig = Array(Set(remixItems.map(\.s)))
        out.append("challenges: n \(challengesN.count), sig \(challengesSig.count)")
        guard let solved = solve(solver: solver, playerPath: playerPath, n: challengesN, sig: challengesSig) else {
            out.append("solver failed to run"); return (out, nil)
        }
        out.append("solver: n solved \(solved.n.count)/\(challengesN.count), sig solved \(solved.sig.count)/\(challengesSig.count)\(solved.errors.isEmpty ? "" : ", errors: \(solved.errors.joined(separator: " | "))")")
        let changedN = challengesN.filter { solved.n[$0] != nil && solved.n[$0] != $0 }.count
        out.append("n changed by transform: \(changedN)/\(challengesN.count)")

        let session = URLSession(configuration: .ephemeral)
        func status(_ url: URL, range: String?, ua: String) async -> (Int, Int) {
            var r = URLRequest(url: url)
            r.setValue(ua, forHTTPHeaderField: "User-Agent")
            if let range { r.setValue(range, forHTTPHeaderField: "Range") }
            guard let (d, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return (-1, 0) }
            return (h.statusCode, d.count)
        }
        // HLS segment: untransformed vs n transformed.
        if let segment, let n = segN {
            let ua = ClientIdentity.webSafari.userAgent
            let before = await status(segment, range: nil, ua: ua)
            out.append("HLS segment, n as served: HTTP \(before.0), \(before.1) B")
            if let t = solved.n[n], let replaced = replacePath(segment, key: "n", value: t) {
                let after = await status(replaced, range: nil, ua: ua)
                out.append("HLS segment, n transformed: HTTP \(after.0), \(after.1) B")
            }
        } else {
            out.append("HLS segment: none")
        }
        // WEB_REMIX audio: sig only, then sig + n.
        let ua = ClientIdentity.webRemix.userAgent
        for item in remixItems {
            guard let sig = solved.sig[item.s] else { out.append("itag \(item.itag): sig unsolved"); continue }
            var withSig = item.base
            withSig.queryItems = (withSig.queryItems ?? []) + [URLQueryItem(name: item.sp, value: sig)]
            var both = withSig
            if let n = item.n, let t = solved.n[n] {
                both.queryItems = both.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: t) : $0 }
            }
            guard let u1 = withSig.url, let u2 = both.url else { continue }
            if item.itag == 141 { playable = u2 }
            let a = await status(u1, range: "bytes=0-65535", ua: ua)
            let b = await status(u2, range: "bytes=0-65535", ua: ua)
            var mid = ""
            if let len = item.length, len > 1_200_000 {
                let m = await status(u2, range: "bytes=1100000-1165535", ua: ua)
                mid = ", sig+n mid-range HTTP \(m.0) \(m.1) B"
            }
            out.append("itag \(item.itag): sig only HTTP \(a.0) \(a.1) B; sig+n HTTP \(b.0) \(b.1) B\(mid)")
        }
        return (out, playable)
    }

    struct Solved { var n: [String: String]; var sig: [String: String]; var errors: [String] }

    static func solve(solver: String, playerPath: String, n: [String], sig: [String]) -> Solved? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", solver]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard let input = try? JSONSerialization.data(withJSONObject: ["player_path": playerPath, "n": n, "sig": sig]),
              (try? process.run()) != nil else { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Solved(n: root["n"] as? [String: String] ?? [:], sig: root["sig"] as? [String: String] ?? [:],
                      errors: root["errors"] as? [String] ?? [])
    }

    static func firstSegment(_ master: URL) async -> URL? {
        let session = URLSession(configuration: .ephemeral)
        guard let (md, _) = try? await session.data(from: master) else { return nil }
        let lines = String(decoding: md, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let i = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }), i + 1 < lines.count,
              let variant = URL(string: lines[i + 1], relativeTo: master)?.absoluteURL,
              let (pd, _) = try? await session.data(from: variant) else { return nil }
        return String(decoding: pd, as: UTF8.self).split(separator: "\n").map(String.init)
            .first { !$0.hasPrefix("#") && !$0.isEmpty }.flatMap { URL(string: $0, relativeTo: variant)?.absoluteURL }
    }

    /// Path-encoded parameters: /key/value/…
    static func pathValue(_ url: URL, key: String) -> String? {
        let parts = url.path(percentEncoded: true).split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
        return parts[i + 1].removingPercentEncoding
    }

    static func replacePath(_ url: URL, key: String, value: String) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var parts = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
        parts[i + 1] = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        comps.percentEncodedPath = parts.joined(separator: "/")
        return comps.url
    }
}
