import Foundation

/// V0 Native Video feasibility: what `/player` (WEB_REMIX, signed-in session) offers for a
/// video, and whether the simplest candidate's bytes are reachable with the audio path's own
/// sig/n transform. Prints structure and HTTP statuses only; URLs, signatures and n values
/// stay in memory and in the solver's stdin/stdout pipe.
public enum VideoProbe {
    public static func run(_ transport: InnerTubeTransport, videoID: String, playerPath: String, solver: String) async -> (lines: [String], muxed: URL?) {
        var out: [String] = []
        guard let (response, _) = try? await PlayerProbe.request(transport, client: .webRemix, videoID: videoID),
              let json = response.json else { return (["WEB_REMIX /player: no response"], nil) }
        let sd = json["streamingData"]
        out.append("WEB_REMIX /player HTTP \(response.status) auth=\(response.auth ?? "none") playability \(json.at("playabilityStatus.status")?.string ?? "?") type \(json.at("videoDetails.musicVideoType")?.string ?? "-") length \(json.at("videoDetails.lengthSeconds")?.string ?? "-")s")
        out.append("streamingData: formats \(sd?["formats"]?.array.count ?? 0), adaptive \(sd?["adaptiveFormats"]?.array.count ?? 0), HLS \(sd?["hlsManifestUrl"] != nil), DASH \(sd?["dashManifestUrl"] != nil), SABR-url \(sd?["serverAbrStreamingUrl"] != nil), expiresIn \(sd?["expiresInSeconds"]?.string ?? "-")")
        out.append("protection: attestation \(json["playerAttestationRenderer"] != nil), licenseInfos \(sd?["licenseInfos"] != nil), drmParams \(sd?["drmParams"] != nil)")

        struct Item { let kind: String; let itag: Int; let mime: String; let quality: String; let size: String
                      let hasURL: Bool; let cipher: (base: URLComponents, sp: String, s: String)?; let direct: URL?; let n: String?
                      let pot: Bool; let drm: Bool; let length: Int? }
        var items: [Item] = []
        for (kind, list) in [("muxed", sd?["formats"]?.array ?? []), ("adaptive", sd?["adaptiveFormats"]?.array ?? [])] {
            for f in list {
                let itag = Int(f["itag"]?.number ?? 0)
                let direct = f["url"]?.string.flatMap(URL.init(string:))
                var cipher: (URLComponents, String, String)?
                var base: URLComponents? = direct.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                if let c = f["signatureCipher"]?.string ?? f["cipher"]?.string {
                    let q = URLComponents(string: "x:?" + c)?.queryItems ?? []
                    func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
                    if let s = v("s"), let raw = v("url"), let comps = URLComponents(string: raw) {
                        cipher = (comps, v("sp") ?? "signature", s); base = comps
                    }
                }
                let keys = base?.queryItems?.map(\.name) ?? []
                items.append(Item(kind: kind, itag: itag, mime: f["mimeType"]?.string ?? "?",
                                  quality: f["qualityLabel"]?.string ?? f["audioQuality"]?.string ?? "-",
                                  size: f["width"].map { "\(Int($0.number ?? 0))x\(Int(f["height"]?.number ?? 0))" } ?? "-",
                                  hasURL: direct != nil, cipher: cipher, direct: direct,
                                  n: base?.queryItems?.first { $0.name == "n" }?.value,
                                  pot: keys.contains("pot"), drm: f["drmFamilies"] != nil,
                                  length: f["contentLength"]?.string.flatMap(Int.init)))
            }
        }
        for i in items where i.kind == "muxed" || i.mime.hasPrefix("video/") {
            out.append("  \(i.kind) itag \(i.itag) \(i.mime) \(i.quality) \(i.size) url \(i.hasURL) cipher \(i.cipher != nil) n \(i.n != nil) pot \(i.pot) drm \(i.drm)")
        }
        let audio = items.filter { $0.mime.hasPrefix("audio/") }
        out.append("  adaptive audio: \(audio.count) (cipher \(audio.filter { $0.cipher != nil }.count), url \(audio.filter(\.hasURL).count)), itags \(audio.map(\.itag))")

        // Candidates in V0 priority: muxed mp4, then one adaptive avc1 video.
        let muxed = items.first { $0.kind == "muxed" && $0.mime.hasPrefix("video/mp4") }
        let adaptive = items.filter { $0.kind == "adaptive" && $0.mime.hasPrefix("video/mp4") && $0.mime.contains("avc1") }
            .max { ($0.length ?? 0) < ($1.length ?? 0) }
        let candidates = [muxed, adaptive].compactMap { $0 }
        guard !candidates.isEmpty else { out.append("no mp4 candidate"); return (out, nil) }

        let ns = Array(Set(candidates.compactMap(\.n))), sigs = Array(Set(candidates.compactMap { $0.cipher?.s }))
        guard let solved = SolverExperiment.solve(solver: solver, playerPath: playerPath, n: ns, sig: sigs) else {
            out.append("solver failed to run"); return (out, nil)
        }
        out.append("solver: n \(solved.n.count)/\(ns.count), sig \(solved.sig.count)/\(sigs.count)\(solved.errors.isEmpty ? "" : ", errors \(solved.errors.count)")")

        let session = URLSession(configuration: .ephemeral)
        func status(_ url: URL, _ range: String) async -> (Int, Int, String) {
            var r = URLRequest(url: url)
            r.setValue(ClientIdentity.webRemix.userAgent, forHTTPHeaderField: "User-Agent")
            r.setValue(range, forHTTPHeaderField: "Range")
            guard let (d, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return (-1, 0, "-") }
            return (h.statusCode, d.count, h.value(forHTTPHeaderField: "Content-Type") ?? "-")
        }
        var muxedURL: URL?
        for c in candidates {
            var comps = c.cipher?.base ?? c.direct.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if let cipher = c.cipher {
                guard let sig = solved.sig[cipher.s] else { out.append("itag \(c.itag): sig unsolved"); continue }
                let query = comps?.queryItems ?? []
                comps?.queryItems = query + [URLQueryItem(name: cipher.sp, value: sig)]
            }
            let asServedN = comps?.url
            if let n = c.n, let t = solved.n[n] {
                let query = comps?.queryItems ?? []
                comps?.queryItems = query.map { $0.name == "n" ? URLQueryItem(name: "n", value: t) : $0 }
            }
            guard let url = comps?.url else { continue }
            if c.n != nil, let asServedN {
                let a = await status(asServedN, "bytes=0-65535")
                out.append("itag \(c.itag) (\(c.kind)): n untransformed HTTP \(a.0) \(a.1) B")
            }
            let b = await status(url, "bytes=0-65535")
            var mid = ""
            if let len = c.length, len > 2_000_000 {
                let m = await status(url, "bytes=\(len / 2)-\(len / 2 + 65535)")
                mid = ", mid-range HTTP \(m.0) \(m.1) B"
            }
            out.append("itag \(c.itag) (\(c.kind)): \(c.cipher != nil ? "sig+n" : "n") HTTP \(b.0) \(b.1) B \(b.2)\(mid), length \(c.length.map(String.init) ?? "-")")
            if c.kind == "muxed", b.0 == 206 || b.0 == 200 { muxedURL = url }
        }
        return (out, muxedURL)
    }
}
