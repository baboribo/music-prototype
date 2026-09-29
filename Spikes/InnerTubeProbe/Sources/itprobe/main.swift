import Foundation
import InnerTubeKit

// Usage: itprobe <command> [args]; redacted dumps go to $PROBE_OUT.
setvbuf(stdout, nil, _IONBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "probe-out")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func save(_ name: String, _ json: JSON?) throws {
    guard let json else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Redactor.redact(json)).write(to: outDir.appendingPathComponent("\(name).json"))
}

func parseBody(_ s: String) throws -> [String: JSON] {
    try JSONDecoder().decode(JSON.self, from: Data(s.utf8)).object
}

func describe(_ item: NItem) -> String {
    switch item {
    case .track(let t): "track \(t.title) — \(t.artist.isEmpty ? "(album artist)" : t.artist) · \(t.album?.name ?? "-") · \(t.durationSeconds.map { "\($0)s" } ?? "-")\(t.isExplicit ? " E" : "")\(t.unplayableReason.map { " UNPLAYABLE \($0)" } ?? "")"
    case .release(let id, let title, let kind, let artist, let year, let art): "release[\(kind.map { "\($0)" } ?? "?")] \(title) — \(artist ?? "-") · \(year.map(String.init) ?? "-") · \(id) art:\(art != nil)"
    case .playlist(let id, let title, let owner, _): "playlist \(title) — \(owner ?? "-") · \(id)"
    case .artist(let id, let name, _): "artist \(name) · \(id)"
    case .other(let kind, let title): "other[\(kind)] \(title)"
    }
}

// normalize <kind> <dump.json> works offline on saved (redacted) dumps.
if args.first == "normalize" {
    let root = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    switch args[1] {
    case "release":
        guard let r = Normalize.release(root, id: "?") else { print("no release header"); break }
        print("Release \(r.title) kind=\(r.kind.map { "\($0)" } ?? "nil") artist=\(r.artist?.name ?? "-")(\(r.artist?.browseID ?? "-")) year=\(r.year.map(String.init) ?? "-") audioPlaylist=\(r.audioPlaylistID ?? "-") art=\(r.artworkURL != nil)")
        r.tracks.forEach { print("  \($0.index.map(String.init) ?? "-"). \(describe(.track($0))) [\($0.id)]") }
        for shelf in r.shelves { print("  § \(shelf.title) (\(shelf.items.count))"); shelf.items.prefix(3).forEach { print("    \(describe($0))") } }
    case "artist":
        guard let a = Normalize.artist(root, id: "?") else { print("no artist header"); break }
        print("Artist \(a.name) subscribers=\(a.subscribers ?? "-") radio=\(a.radioPlaylistID ?? "-") shuffle=\(a.shufflePlaylistID ?? "-") description=\(a.description == nil ? "nil" : "yes") art=\(a.artworkURL != nil)")
        for s in a.sections {
            print("  § \(s.title) (\(s.items.count)) more=\(s.moreBrowseID ?? "-")")
            s.items.prefix(2).forEach { print("      \(describe($0))") }
        }
    case "search":
        let s = Normalize.search(root)
        print("filters: \(s.filters)"); print("top: \(s.top.map(describe) ?? "-")")
        s.items.forEach { print("  \(describe($0))") }
    case "suggest":
        let s = Normalize.suggestions(root)
        print("queries: \(s.queries)"); s.items.forEach { print("  \(describe($0))") }
    case "queue":
        let q = Normalize.queue(root)
        print("queue playlist=\(q.playlistID ?? "-") tracks=\(q.tracks.count) continuation=\(q.hasContinuation) lyrics=\(q.lyricsBrowseID ?? "-") related=\(q.relatedBrowseID ?? "-")")
        q.tracks.forEach { print("  \(describe(.track($0))) [\($0.id)] album=\($0.album?.browseID ?? "-")") }
    default: print("kinds: release artist search suggest queue")
    }
    exit(0)
}

// Credentials: a file the user creates outside the repository (ITPROBE_AUTH).
let authPath = ProcessInfo.processInfo.environment["ITPROBE_AUTH"]
if let authPath {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    guard !URL(fileURLWithPath: authPath).standardizedFileURL.path.hasPrefix(repo) else {
        fatalError("ITPROBE_AUTH must live outside the repository")
    }
}

if args.first == "oauth-device" {
    let env = ProcessInfo.processInfo.environment
    guard let authPath, let id = env["ITPROBE_OAUTH_CLIENT_ID"], let secret = env["ITPROBE_OAUTH_CLIENT_SECRET"] else {
        fatalError("set ITPROBE_AUTH, ITPROBE_OAUTH_CLIENT_ID, ITPROBE_OAUTH_CLIENT_SECRET")
    }
    try await DeviceFlow.run(clientID: id, clientSecret: secret, writeTo: authPath)
    exit(0)
}

let anonymous = try await InnerTubeTransport.bootstrap()
let auth = try authPath.map(AuthMaterial.load)
let useAuth = args.contains("--auth")
let transport = useAuth ? anonymous.authenticated(auth) : anonymous
print("bootstrap: visitorData \(anonymous.visitorData == nil ? "missing" : "ok"), signatureTimestamp \(anonymous.signatureTimestamp.map(String.init) ?? "missing"), auth \(useAuth ? (auth?.label ?? "requested but ITPROBE_AUTH unset") : "off")")

func sessionLine(_ r: InnerTubeResponse) -> String {
    "HTTP \(r.status) auth=\(r.auth ?? "none") logged_in=\(r.tracking("logged_in") ?? "?") unlimited=\(r.tracking("has_unlimited_entitlement") ?? "?") \(r.byteCount)B"
}

switch args.first {
case "raw":
    // raw <name> <endpoint> <client> '<json body>'
    let (name, endpoint, clientLabel, body) = (args[1], args[2], args[3], args[4])
    guard let client = ClientIdentity.named(clientLabel) else { fatalError("unknown client \(clientLabel)") }
    let response = try await transport.post(endpoint, client: client, body: try parseBody(body))
    try save(name, response.json)
    print("\(endpoint) [\(client.label)] \(sessionLine(response)), top keys: \(response.json?.keys ?? [])")
    if let error = response.json?["error"] { print("error:", error["message"]?.string ?? "?") }
case "matrix":
    // matrix <videoId>... [--clients A,B]
    var ids = Array(args.dropFirst()).filter { $0 != "--auth" }
    var clients = ClientIdentity.all
    if let i = ids.firstIndex(of: "--clients") {
        clients = ids[i + 1].split(separator: ",").compactMap { ClientIdentity.named(String($0)) }
        ids.removeSubrange(i...(i + 1))
    }
    for id in ids {
        for client in clients {
            let (response, summary) = try await PlayerProbe.request(transport, client: client, videoID: id)
            try save("player_\(id)_\(client.label)\(response.auth.map { "_" + $0 } ?? "")", response.json)
            guard let s = summary else { print("\(id) \(client.label): HTTP \(response.status), no JSON"); continue }
            let audio = s.audio
            print("""
            \(id) \(client.label)\(client.versionIsGuess ? "(guessed ver)" : "") auth=\(response.auth ?? "none"): HTTP \(response.status) \(s.status)\(s.reason.map { " — \($0)" } ?? "") \
            | type \(s.musicVideoType ?? "-") | streamingData \(s.hasStreamingData) exp \(s.expiresInSeconds.map(String.init) ?? "-") \
            | formats \(s.formatCount) noURL/cipher \(s.formatsWithoutURLOrCipher) | audio \(audio.count) direct \(audio.filter(\.hasURL).count) cipher \(audio.filter(\.hasCipher).count) drm \(audio.filter(\.drm).count) \
            | HLS \(s.hlsManifest != nil) DASH \(s.hasDASHManifest) SABR-url \(s.hasSABRURL) | n-param \(s.needsNChallenge)
            """)
            for f in audio.prefix(6) {
                print("    itag \(f.itag) \(f.mimeType) \(f.bitrate)bps \(f.audioQuality) len \(f.contentLength.map(String.init) ?? "-") url \(f.hasURL) cipher \(f.hasCipher) pot-param \(f.urlParamKeys.contains("pot"))")
            }
            if let best = s.directAudio, let r = await PlayerProbe.reach(best, userAgent: client.userAgent) {
                print("    reach itag \(best.itag): \(r)")
            }
            if let hls = s.hlsManifest {
                print("    HLS: \(await PlayerProbe.inspectHLS(hls, userAgent: client.userAgent))")
            }
        }
    }
case "hls":
    // hls <videoId>... [--auth] [--play] : WEB_SAFARI manifest walk, optional AVPlayer run.
    let ids = args.dropFirst().filter { !$0.hasPrefix("--") }
    for id in ids {
        let (response, summary) = try await PlayerProbe.request(transport, client: .webSafari, videoID: id)
        print("\(id) WEB_SAFARI auth=\(response.auth ?? "none"): \(summary?.status ?? "?") exp \(summary?.expiresInSeconds.map(String.init) ?? "-") HLS \(summary?.hlsManifest != nil)")
        guard let master = summary?.hlsManifest else { continue }
        let (report, _) = await PlayerProbe.walkHLS(master, userAgent: ClientIdentity.webSafari.userAgent)
        report.forEach { print("  " + $0) }
        if args.contains("--play") { await AVPlaybackTest.run(master, label: id) }
        if args.contains("--headers") {
            let lines = await PlayerProbe.segmentHeaderMatrix(master, userAgent: ClientIdentity.webSafari.userAgent, cookie: auth?.cookieHeader)
            lines.forEach { print("  seg " + $0) }
        }
    }
case "authcheck":
    // Same requests anonymous vs. authenticated; only session state and shape are printed.
    let authed = anonymous.authenticated(auth)
    let checks: [(String, String, ClientIdentity, [String: JSON])] = [
        ("home", "browse", .webRemix, ["browseId": "FEmusic_home"]),
        ("library_playlists", "browse", .webRemix, ["browseId": "FEmusic_liked_playlists"]),
        ("history", "browse", .webRemix, ["browseId": "FEmusic_history"]),
        ("liked_songs", "browse", .webRemix, ["browseId": "VLLM"]),
        ("editorial_playlist", "browse", .webRemix, ["browseId": "VLRDCLAK5uy_nZ6WXehjm55VXBlKYrJLcR-gY5MkpzUIM"]),
        ("artist", "browse", .webRemix, ["browseId": "UCTUR0sVEkD8T5MlSHqgaI_Q"]),
        ("search", "search", .webRemix, ["query": "아이유"]),
        ("radio", "next", .webRemix, ["videoId": "NnRjwEhFU70", "playlistId": "RDAMVMNnRjwEhFU70", "isAudioOnly": true]),
    ]
    for (name, endpoint, client, body) in checks {
        for (mode, t) in [("anon", anonymous), ("auth", authed)] {
            let r = try await t.post(endpoint, client: client, body: body)
            try save("check_\(name)_\(mode)", r.json)
            var shape = ""
            if let json = r.json {
                switch name {
                case "search":
                    let s = Normalize.search(json)
                    let songs = s.items.filter { if case .track = $0 { true } else { false } }.count
                    shape = "filters \(s.filters.count) (\(s.filters.contains("노래") ? "has 노래" : "no 노래")), items \(s.items.count), songs \(songs)"
                case "radio":
                    let q = Normalize.queue(json)
                    shape = "queue \(q.tracks.count) continuation \(q.hasContinuation)"
                case "artist":
                    shape = "sections \(Normalize.artist(json, id: "")?.sections.map(\.title) ?? [])"
                default:
                    let shelves = json.all("musicCarouselShelfRenderer").count + json.all("musicShelfRenderer").count
                        + json.all("gridRenderer").count + json.all("musicPlaylistShelfRenderer").count
                    let message = json.first("messageRenderer")?["text"]?.text
                    shape = "shelves \(shelves), items \(json.all("musicResponsiveListItemRenderer").count + json.all("musicTwoRowItemRenderer").count)\(message.map { ", message: \($0)" } ?? "")"
                }
            }
            if let error = r.json?["error"] { shape += " error: \(error["message"]?.string ?? "?")" }
            print("\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(mode) \(sessionLine(r)) | \(shape)")
        }
    }
default:
    print("commands: raw, matrix [--auth], authcheck, oauth-device, normalize")
}
