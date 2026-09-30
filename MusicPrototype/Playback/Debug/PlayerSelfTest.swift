#if DEBUG
import Foundation

/// Debug builds only: a scripted Player run on a real continuous album for on-device
/// verification (`YTM_PLAYER_TEST=1`). Samples each layer's position at one timestamp:
/// AVPlayer → engine → PlayerModel → the value the Full Player last rendered.
@MainActor
enum PlayerSelfTest {
    /// The position the progress view last rendered (set by the view in debug builds).
    static var renderedPosition: Double = -1
    static var renderedDuration: Double = -1
    /// Set by AppShell: opens the Full Player.
    static var openPlayer: (() -> Void)?

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["YTM_PLAYER_TEST"] == "1" }

    /// namitape megamix! (MPREb_f7GB3pYR5s6): tracks run into each other.
    private static let album = "OLAK5uy_myG69tRsrQD1-LcUvBjMffaipMJ-tZovU"
    private static let firstTrack = Track(id: "QsJ-_kJhkeU", title: "nawatobi drive(megamix)", artist: "Namitape", artistID: nil,
                                          album: "namitape megamix!", releaseID: nil, artwork: .theme(.midnight), duration: 151)

    static func run(_ player: PlayerModel) async {
        let sampler = Task { await sample(player) }
        defer { sampler.cancel() }
        func step(_ name: String, _ extra: [String: Any] = [:]) {
            PlaybackDiagnostics.record("step", extra.merging(["name": name]) { a, _ in a })
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func until(_ seconds: Double, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !condition() { try? await Task.sleep(for: .milliseconds(100)) }
        }

        await wait(3)
        step("start")
        player.play(firstTrack, in: [firstTrack], source: "namitape megamix!", playlistID: album)
        openPlayer?()
        await until(20) { player.position > 1 && player.upcomingItems.count > 2 }
        await wait(4)
        step("pause"); player.togglePlayPause(); await wait(3)
        step("resume"); player.togglePlayPause(); await wait(3)
        step("seek 60"); player.seek(position: 60); await wait(3)
        step("next (prefetched)"); player.next(); await wait(4)
        step("previous (restart)"); player.previous(); await wait(1)
        step("previous (track)"); player.previous(); await wait(4)
        if let target = player.upcomingItems.dropFirst(2).first {
            step("queue select"); player.selectUpcoming(target); await wait(4)
        }
        step("seek end-6", ["duration": player.duration]); player.seek(position: player.duration - 6)
        await wait(10)
        step("done")
        player.togglePlayPause()
    }

    /// 10 Hz: every layer's view of the current time, at one timestamp.
    private static func sample(_ player: PlayerModel) async {
        while !Task.isCancelled {
            let engine = player.engine as? NativeAudioEngine
            PlaybackDiagnostics.record("sync", [
                "av": round(engine?.debugPlayerTime ?? -1), "engine": round(player.engine.position), "model": round(player.position),
                "shown": round(renderedPosition), "dur": round(player.duration), "shownDur": round(renderedDuration),
                "playing": player.isPlaying, "avRate": engine?.debugRate ?? -1,
                "item": player.currentItem?.id.suffix(6).description ?? "-", "engineKey": engine?.debugCurrentKey.suffix(6).description ?? "-",
            ])
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func round(_ value: Double) -> Double { value.isFinite ? (value * 100).rounded() / 100 : -1 }
}
#endif
