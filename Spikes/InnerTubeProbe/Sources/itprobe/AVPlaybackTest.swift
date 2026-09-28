import AVFoundation
import Foundation

/// Engine-level check of one stream URL in AVPlayer. Muted: this verifies
/// fetching, decoding and seeking, not audible output or system audio.
@MainActor
enum AVPlaybackTest {
    static func run(_ url: URL, label: String) async {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        let start = Date()
        func t() -> String { String(format: "%5.1fs", Date().timeIntervalSince(start)) }
        func state() -> String {
            let status = switch item.status { case .readyToPlay: "ready"; case .failed: "FAILED"; default: "unknown" }
            let control = switch player.timeControlStatus { case .playing: "playing"; case .paused: "paused"; default: "waiting" }
            let dur = item.duration.seconds.isFinite ? String(format: "%.0f", item.duration.seconds) : "?"
            return "\(t()) item \(status) \(control) pos \(String(format: "%.1f", player.currentTime().seconds))/\(dur)s"
                + (item.error.map { " error: \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "")
        }
        func sample(_ seconds: Int, every: Int = 15) async {
            var waited = 0
            while waited < seconds {
                try? await Task.sleep(for: .seconds(min(every, seconds - waited)))
                waited += every
                print("  " + state())
            }
        }

        print("[\(label)] play")
        player.play()
        await sample(95)

        print("[\(label)] pause 5s")
        player.pause()
        let pausedAt = player.currentTime().seconds
        await sample(5, every: 5)
        print("  paused drift \(String(format: "%.2f", player.currentTime().seconds - pausedAt))s")
        player.play()
        await sample(5, every: 5)

        for target in [150.0, 10.0] {
            let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
            print("[\(label)] seek \(Int(target))s finished=\(finished)")
            await sample(10, every: 5)
        }

        let access = item.accessLog()?.events ?? []
        let errors = item.errorLog()?.events ?? []
        let bytes = access.reduce(0) { $0 + $1.numberOfBytesTransferred }
        let requests = access.reduce(0) { $0 + $1.numberOfMediaRequests }
        print("[\(label)] accessLog: \(access.count) events, \(requests) media requests, \(bytes / 1024) KiB, indicated \(Int(access.last?.indicatedBitrate ?? 0) / 1000)k, stalls \(access.reduce(0) { $0 + $1.numberOfStalls })")
        print("[\(label)] errorLog: \(errors.count) events" + errors.prefix(5).map { " [\($0.errorStatusCode) \($0.errorDomain)]" }.joined())
        player.pause()
    }
}
