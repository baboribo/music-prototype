import Foundation

/// What one /player response offers, with every signed value dropped.
/// `audio` keeps the resolvable URL in memory only for reachability tests.
public struct PlayerSummary: Sendable {
    public struct AudioFormat: Sendable {
        public let itag: Int
        public let mimeType: String
        public let bitrate: Int
        public let audioQuality: String
        public let contentLength: Int?
        public let hasURL: Bool
        public let hasCipher: Bool
        public let urlParamKeys: [String]
        public let drm: Bool
        let url: URL?
    }

    public let client: String
    public let videoID: String
    public let status: String
    public let reason: String?
    public let hasStreamingData: Bool
    public let expiresInSeconds: Int?
    public let hlsManifest: URL?
    public let hasDASHManifest: Bool
    public let hasSABRURL: Bool
    public let formatCount: Int
    public let formatsWithoutURLOrCipher: Int
    public let audio: [AudioFormat]
    public let musicVideoType: String?
    public let lengthSeconds: Int?

    public init(client: String, videoID: String, json: JSON) {
        self.client = client
        self.videoID = videoID
        let ps = json["playabilityStatus"]
        status = ps?["status"]?.string ?? "?"
        reason = ps?["reason"]?.string ?? ps?.at("errorScreen.playerErrorMessageRenderer.reason")?.text
        let sd = json["streamingData"]
        hasStreamingData = sd != nil
        expiresInSeconds = sd?["expiresInSeconds"]?.string.flatMap(Int.init)
        hlsManifest = sd?["hlsManifestUrl"]?.string.flatMap(URL.init(string:))
        hasDASHManifest = sd?["dashManifestUrl"] != nil
        hasSABRURL = sd?["serverAbrStreamingUrl"] != nil
        let all = (sd?["formats"]?.array ?? []) + (sd?["adaptiveFormats"]?.array ?? [])
        formatCount = all.count
        formatsWithoutURLOrCipher = all.filter { $0["url"] == nil && $0["signatureCipher"] == nil && $0["cipher"] == nil }.count
        audio = all.filter { $0["mimeType"]?.string?.hasPrefix("audio/") == true }.map { f in
            let url = f["url"]?.string.flatMap(URL.init(string:))
            return AudioFormat(
                itag: Int(f["itag"]?.number ?? 0),
                mimeType: f["mimeType"]?.string ?? "?",
                bitrate: Int(f["bitrate"]?.number ?? 0),
                audioQuality: f["audioQuality"]?.string ?? "?",
                contentLength: f["contentLength"]?.string.flatMap(Int.init),
                hasURL: url != nil,
                hasCipher: f["signatureCipher"] != nil || f["cipher"] != nil,
                urlParamKeys: Self.paramKeys(url: url, cipher: f["signatureCipher"]?.string ?? f["cipher"]?.string),
                drm: f["drmFamilies"] != nil,
                url: url)
        }
        musicVideoType = json.at("videoDetails.musicVideoType")?.string
        lengthSeconds = json.at("videoDetails.lengthSeconds")?.string.flatMap(Int.init)
    }

    /// Parameter names only: of the direct URL, or of the URL inside a cipher blob.
    static func paramKeys(url: URL?, cipher: String?) -> [String] {
        var target = url
        if target == nil, let cipher {
            var c = URLComponents(); c.percentEncodedQuery = cipher
            target = c.queryItems?.first { $0.name == "url" }?.value.flatMap(URL.init(string:))
        }
        return target.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) } ?? []
    }

    /// Needs the web player's n-parameter transform before the URL is usable at full speed.
    public var needsNChallenge: Bool { audio.contains { $0.urlParamKeys.contains("n") } }
    public var directAudio: AudioFormat? {
        audio.filter { $0.hasURL && !$0.drm }.max { $0.bitrate < $1.bitrate }
    }
}

public enum PlayerProbe {
    public static func request(_ transport: InnerTubeTransport, client: ClientIdentity, videoID: String) async throws -> (InnerTubeResponse, PlayerSummary?) {
        var body: [String: JSON] = [
            "videoId": .string(videoID), "contentCheckOk": true, "racyCheckOk": true,
        ]
        if client.isWeb, let sts = transport.signatureTimestamp {
            body["playbackContext"] = ["contentPlaybackContext": [
                "signatureTimestamp": .number(Double(sts)), "html5Preference": "HTML5_PREF_WANTS",
            ]]
        }
        let response = try await transport.post("player", client: client, body: body)
        return (response, response.json.map { PlayerSummary(client: client.label, videoID: videoID, json: $0) })
    }

    public struct Reachability: Sendable, CustomStringConvertible {
        public let firstRange: Int
        public let laterRange: Int?
        public let bytes: Int
        public let contentType: String?
        public var description: String {
            "range0 HTTP \(firstRange)" + (laterRange.map { ", mid-range HTTP \($0)" } ?? "") + ", \(bytes) B, \(contentType ?? "?")"
        }
    }

    /// Two small ranged GETs: the start of the file and a point past the first
    /// megabyte, which is where throttled or token-less URLs typically fail.
    public static func reach(_ format: PlayerSummary.AudioFormat, userAgent: String) async -> Reachability? {
        guard let url = format.url else { return nil }
        let session = URLSession(configuration: .ephemeral)
        func get(_ range: String) async -> (Int, Int, String?) {
            var r = URLRequest(url: url)
            r.setValue(range, forHTTPHeaderField: "Range")
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: r), let http = resp as? HTTPURLResponse else { return (-1, 0, nil) }
            return (http.statusCode, data.count, http.value(forHTTPHeaderField: "Content-Type"))
        }
        let first = await get("bytes=0-65535")
        var later: Int?
        if let length = format.contentLength, length > 1_200_000 {
            later = await get("bytes=1100000-1165535").0
        }
        return Reachability(firstRange: first.0, laterRange: later, bytes: first.1, contentType: first.2)
    }

    /// Master → lowest-bandwidth variant → media playlist → first/middle/last
    /// segment. Returns the variant URL (in memory only) for an AVPlayer test.
    public static func walkHLS(_ master: URL, userAgent: String) async -> (report: [String], variant: URL?) {
        let session = URLSession(configuration: .ephemeral)
        func get(_ url: URL, range: String? = nil) async -> (Int, Data) {
            var r = URLRequest(url: url)
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let range { r.setValue(range, forHTTPHeaderField: "Range") }
            guard let (d, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return (-1, Data()) }
            return (h.statusCode, d)
        }
        var report: [String] = []
        let (ms, md) = await get(master)
        let lines = String(decoding: md, as: UTF8.self).split(separator: "\n").map(String.init)
        var variants: [(bw: Int, codecs: String, res: String, url: URL)] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            let bw = line.firstCapture(#"BANDWIDTH=(\d+)"#).flatMap(Int.init) ?? 0
            if let u = URL(string: lines[i + 1], relativeTo: master)?.absoluteURL {
                variants.append((bw, line.firstCapture(#"CODECS="([^"]+)""#) ?? "?", line.firstCapture(#"RESOLUTION=(\S+?)(,|$)"#) ?? "?", u))
            }
        }
        variants.sort { $0.bw < $1.bw }
        report.append("master HTTP \(ms), variants (bw/res/codecs): " + variants.map { "\($0.bw/1000)k/\($0.res)/\($0.codecs)" }.joined(separator: " | "))
        guard let low = variants.first else { return (report, nil) }
        let (ps, pd) = await get(low.url)
        let media = String(decoding: pd, as: UTF8.self).split(separator: "\n").map(String.init)
        let durations = media.compactMap { $0.firstCapture(#"#EXTINF:([\d.]+)"#).flatMap(Double.init) }
        let segments = media.filter { !$0.hasPrefix("#") && !$0.isEmpty }.compactMap { URL(string: $0, relativeTo: low.url)?.absoluteURL }
        if let first = segments.first {
            // Segment URLs are path-encoded (/key/value/…); keep only the key names.
            let parts = first.path.split(separator: "/").map(String.init)
            let keys = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
            report.append("segment URL path keys: \(keys.joined(separator: ","))")
        }
        report.append("master URL path keys: \(stride(from: 1, to: master.path.split(separator: "/").count, by: 2).map { String(master.path.split(separator: "/")[$0]) }.joined(separator: ","))")
        report.append("lowest variant playlist HTTP \(ps): \(segments.count) segments, \(Int(durations.reduce(0, +)))s total, endlist \(media.contains("#EXT-X-ENDLIST")), map \(media.contains { $0.hasPrefix("#EXT-X-MAP") })")
        for (label, index) in [("first", 0), ("middle", segments.count / 2), ("last", segments.count - 1)] where segments.indices.contains(index) {
            let (s, d) = await get(segments[index])
            report.append("segment \(label) #\(index): HTTP \(s), \(d.count) B")
        }
        return (report, low.url)
    }

    /// Fetches the HLS master playlist and reports its audio-only renditions.
    public static func inspectHLS(_ url: URL, userAgent: String) async -> String {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession(configuration: .ephemeral).data(for: r),
              let http = resp as? HTTPURLResponse else { return "fetch failed" }
        let text = String(decoding: data, as: UTF8.self)
        let audioGroups = text.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }.count
        let variants = text.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF") }.count
        let codecs = Set(text.split(separator: "\n").compactMap { String($0).firstCapture(#"CODECS="([^"]+)""#) })
        return "HTTP \(http.statusCode), \(variants) variants, \(audioGroups) audio renditions, codecs \(codecs.sorted().prefix(4))"
    }
}
