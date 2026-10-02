import AVFoundation
import SwiftUI

/// V0 Native Video smoke (spike only): the audio path's resolver, the muxed itag 18
/// (avc1 + AAC, 360p) of one known counterpart, plain `AVPlayer` → `AVPlayerLayer`.
/// Log `Documents/video.log`: states and numbers only (no URL, sig, n or cookie).
@MainActor @Observable
final class VideoSmoke {
    /// 밤편지 official video, the counterpart of ATV `NnRjwEhFU70` (HANDOFF §5).
    static let videoID = "BzYnNdJhZQw"
    let player = AVPlayer()
    private(set) var lines: [String] = []
    private let resolver = PlaybackResolver(session: WebKitCookieSource(), playerJS: WebPlayerJSProvider(),
                                            solver: JSCSolver(release: .ejs080))
    private let file = URL.documentsDirectory.appending(path: "video.log")
    private var sampler: Task<Void, Never>?

    func start() {
        guard sampler == nil else { return }
        try? Data().write(to: file)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        sampler = Task {
            let begin = ContinuousClock.now
            do {
                let resolved = try await resolver.resolve(Self.videoID, itags: [18])
                log("resolved", ["itag": resolved.itag, "mime": resolved.mimeType, "ms": resolved.timings])
                let item = AVPlayerItem(url: resolved.url)
                player.replaceCurrentItem(with: item)
                player.play()
                for _ in 0..<40 {
                    try await Task.sleep(for: .seconds(1.5))
                    let elapsed = ContinuousClock.now - begin
                    log("sample", [
                        "t": Double(elapsed.components.seconds),
                        "status": item.status.rawValue,
                        "rate": Double(player.rate),
                        "position": (player.currentTime().seconds * 10).rounded() / 10,
                        "duration": item.duration.seconds.isFinite ? item.duration.seconds.rounded() : -1,
                        "presentation": [item.presentationSize.width, item.presentationSize.height],
                        "route": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue),
                        "error": (item.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "-",
                    ])
                }
                let access = item.accessLog()?.events ?? []
                log("done", ["requests": access.reduce(0) { $0 + $1.numberOfMediaRequests },
                             "kib": access.reduce(0) { $0 + $1.numberOfBytesTransferred } / 1024,
                             "stalls": access.reduce(0) { $0 + $1.numberOfStalls },
                             "errors": item.errorLog()?.events.count ?? 0])
            } catch {
                log("failed", ["error": "\(error)"])
            }
        }
    }

    private func log(_ kind: String, _ body: [String: Any]) {
        var entry = body
        entry["kind"] = kind
        lines.append("\(kind) \(body.keys.sorted().map { "\($0)=\(body[$0]!)" }.joined(separator: " "))")
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
        try? handle.close()
    }
}

struct VideoSmokeView: View {
    @State private var smoke = VideoSmoke()

    var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: smoke.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
            Button("Play \(VideoSmoke.videoID) (itag 18)") { smoke.start() }
                .buttonStyle(.borderedProminent)
            List(smoke.lines.suffix(6), id: \.self) { Text($0).font(.caption2.monospaced()) }
        }
        .task { if ProcessInfo.processInfo.environment["VIDEO_SMOKE"] == "1" { smoke.start() } }
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}
}
