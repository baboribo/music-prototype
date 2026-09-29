import AVFoundation
import MediaPlayer
import SwiftUI

/// Native audio spike: a small queue resolved by `PlaybackResolver`, one AVPlayer, the
/// system Now Playing / remote commands, and system volume. Logs states and numbers only.
@MainActor
@Observable
final class NativeAudioPlayer {
    struct Entry: Identifiable { let id: String; let label: String }
    /// Three ATV tracks this account can play (IDs from earlier /next responses).
    static let queue = [
        Entry(id: "NnRjwEhFU70", label: "밤편지"),
        Entry(id: "wh7j1uEpNsQ", label: "보라빛 밤"),
        Entry(id: "2C1Jg04INb4", label: "팔레트"),
    ]

    private(set) var index = 0
    private(set) var current: ResolvedAudio?
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var lines: [String] = []
    private(set) var resolving = false
    /// The listener's intent: a pause during resolution must hold when the item arrives.
    private var wantsPlayback = false
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume

    private let resolver = PlaybackResolver(session: WebKitCookieSource(), playerJS: WebPlayerJSProvider(),
                                            solver: JSCSolver(release: .ejs080))
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private let file = URL.documentsDirectory.appending(path: "audio.log")
    private var loadTask: Task<Void, Never>?

    init() {
        log("launch", ["UIBackgroundModes": Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []]
            .merging(sessionState()) { a, _ in a })
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.position = time.seconds }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            MainActor.assumeIsolated {
                self?.isPlaying = status == .playing
                let name = switch status { case .playing: "playing"; case .paused: "paused"; default: "waiting" }
                self?.log("timeControl", ["status": name].merging(self?.playerState() ?? [:]) { a, _ in a })
                if status == .playing { self?.mark("playing") }
                self?.updateNowPlaying()
            }
        })
        observations.append(AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = session.outputVolume
            MainActor.assumeIsolated {
                self?.volume = value
                self?.log("volume", ["value": (Double(value) * 100).rounded() / 100])
            }
        })
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated { self?.itemEnded(ended) }
        })
        tokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "?"
            MainActor.assumeIsolated { self?.log("failedToEnd", ["error": error]) }
        })
        tokens.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("stalled", ["pos": self?.rounded(self?.player.currentTime().seconds) ?? -1]) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 99
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 99
            MainActor.assumeIsolated {
                self?.log("interruption", ["type": Int(type), "reason": Int(reason), "options": Int(options)].merging(self?.playerState() ?? [:]) { a, _ in a })
            }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            MainActor.assumeIsolated { self?.log("route", ["reason": Int(reason)].merging(self?.sessionState() ?? [:]) { a, _ in a }) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("mediaServicesReset", [:]) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("mediaServicesLost", [:]) }
        })
        // Why the rate changed (appBackgrounded, audioSessionInterrupted, setRateCalled, …).
        tokens.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason)?.rawValue ?? "?"
            MainActor.assumeIsolated {
                self?.log("rateChange", ["reason": reason.replacingOccurrences(of: "AVPlayerRateDidChangeReason", with: "")]
                    .merging(self?.playerState() ?? [:]) { a, _ in a })
            }
        })
        tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app", ["event": "willResignActive"].merging(self?.playerState() ?? [:]) { a, _ in a }) }
        })
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app", ["event": "didBecomeActive"].merging(self?.playerState() ?? [:]) { a, _ in a }) }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("app", ["event": "didEnterBackground", "bgTimeRemaining": Int(min(UIApplication.shared.backgroundTimeRemaining, 99999))]
                    .merging(self?.playerState() ?? [:]) { a, _ in a }.merging(self?.sessionState() ?? [:]) { a, _ in a })
            }
        })
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app", ["event": "foreground", "pos": self?.rounded(self?.player.currentTime().seconds) ?? -1]) }
        })
        tokens.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app", ["event": "locked", "pos": self?.rounded(self?.player.currentTime().seconds) ?? -1]) }
        })
        tokens.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("app", ["event": "unlocked", "pos": self?.rounded(self?.player.currentTime().seconds) ?? -1]) }
        })
        registerRemoteCommands()
    }

    // MARK: Diagnostics

    private var sessionActiveByUs = false

    /// Category/mode/options and what the session reports; "active" is our own last setActive result.
    func sessionState() -> [String: Any] {
        let s = AVAudioSession.sharedInstance()
        return ["category": s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
                "mode": s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
                "options": s.categoryOptions.rawValue, "activeByUs": sessionActiveByUs,
                "otherAudio": s.isOtherAudioPlaying, "output": s.currentRoute.outputs.first?.portType.rawValue ?? "?"]
    }

    func activateSession(_ reason: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActiveByUs = true
            log("session", ["call": "setActive(true)", "reason": reason, "ok": true].merging(sessionState()) { a, _ in a })
        } catch {
            log("session", ["call": "setActive(true)", "reason": reason, "error": "\((error as NSError).domain) \((error as NSError).code)"])
        }
    }

    func playerState() -> [String: Any] {
        let reason = player.reasonForWaitingToPlay.map { $0.rawValue.replacingOccurrences(of: "AVPlayerWaiting", with: "") } ?? "-"
        let control = switch player.timeControlStatus { case .playing: "playing"; case .paused: "paused"; default: "waiting" }
        return ["rate": player.rate.isFinite ? Double(player.rate) : -1, "control": control, "waitReason": reason, "pos": rounded(player.currentTime().seconds),
                "bgPolicy": player.audiovisualBackgroundPlaybackPolicy.rawValue]
    }

    /// Marks for the Next/Previous latency chain, relative to the remote/user command.
    private var commandStart: Date?
    func mark(_ step: String) {
        guard let start = commandStart else { return }
        log("latency", ["step": step, "ms": Int(Date().timeIntervalSince(start) * 1000)])
    }

    // MARK: Logging

    func log(_ kind: String, _ body: [String: Any]) {
        var entry = body
        entry["kind"] = kind
        entry["t"] = (Date().timeIntervalSince1970 * 10).rounded() / 10
        // Never let a diagnostic value crash the app.
        entry = entry.mapValues { value in
            if let f = value as? Float, !f.isFinite { return -1 }
            if let d = value as? Double, !d.isFinite { return -1 }
            return value
        }
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
        if !FileManager.default.fileExists(atPath: file.path()) { try? Data().write(to: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    /// Finite only: NaN/inf (no item yet) would make JSONSerialization throw.
    func rounded(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return -1 }
        return (value * 10).rounded() / 10
    }

    // MARK: Transport

    func play(at index: Int) {
        guard Self.queue.indices.contains(index) else { return }
        self.index = index
        wantsPlayback = true
        loadTask?.cancel()
        let entry = Self.queue[index]
        resolving = true
        mark("queueChanged")
        loadTask = Task {
            defer { resolving = false }
            let started = Date()
            mark("resolveStart")
            do {
                let resolved = try await resolver.resolve(entry.id)
                guard !Task.isCancelled else { return }
                current = resolved
                mark("resolveDone")
                log("resolved", ["index": index, "track": entry.label, "itag": resolved.itag,
                                 "ms": Int(Date().timeIntervalSince(started) * 1000), "phases": resolved.timings,
                                 "duration": rounded(resolved.duration), "expiresInMin": resolved.expiresAt.map { Int($0.timeIntervalSinceNow / 60) } ?? -1])
                activateSession("play")
                let item = AVPlayerItem(url: resolved.url)
                // These fragmented MP4s carry the full length in mvhd as well as in their fragments;
                // AVPlayer adds both (2× duration) and would only end at twice the real length.
                // Ending the item at the service's length restores didPlayToEndTime.
                if let duration = resolved.duration {
                    item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 44_100)
                }
                player.replaceCurrentItem(with: item)
                if wantsPlayback { player.play() }
                artwork = nil
                updateNowPlaying()
                loadArtwork(resolved.artworkURL)
                observeDuration(item)
            } catch {
                log("resolveFailed", ["index": index, "error": "\(error)", "cancelled": Task.isCancelled])
            }
        }
    }

    private func observeDuration(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let duration = item.duration.seconds
            MainActor.assumeIsolated {
                guard status == .readyToPlay else { return }
                self?.mark("itemReady")
                self?.log("itemReady", ["avDuration": self?.rounded(duration.isFinite ? duration : -1) ?? -1,
                                        "serviceDuration": self?.rounded(self?.current?.duration) ?? -1])
            }
        })
    }

    func pause(_ source: String = "app") { wantsPlayback = false; player.pause(); log("cmd", ["pause": rounded(player.currentTime().seconds), "source": source]) }
    func resume(_ source: String = "app") {
        wantsPlayback = true
        activateSession("resume")
        player.play()
        log("cmd", ["resume": rounded(player.currentTime().seconds), "source": source].merging(playerState()) { a, _ in a })
    }
    func toggle() { wantsPlayback ? pause() : resume() }

    func seek(to seconds: Double) async {
        let target = max(0, seconds)
        let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = player.currentTime().seconds
        log("seek", ["target": rounded(target), "finished": finished, "pos": rounded(position)])
        updateNowPlaying()
    }

    func next() { log("cmd", ["next": index + 1]); play(at: (index + 1) % Self.queue.count) }

    /// Starts a latency chain for a command (remote or in-app).
    func beginCommand(_ name: String) { commandStart = Date(); log("latency", ["step": "command \(name)", "ms": 0]) }

    /// Apple's convention: restart when past 3 s, else the previous track.
    func previous() {
        if player.currentTime().seconds > 3 {
            log("cmd", ["previous": "restart"])
            Task { await seek(to: 0) }
        } else {
            log("cmd", ["previous": index - 1])
            play(at: (index - 1 + Self.queue.count) % Self.queue.count)
        }
    }

    private func itemEnded(_ id: ObjectIdentifier) {
        guard let item = player.currentItem, ObjectIdentifier(item) == id else { return }
        log("ended", ["pos": rounded(item.currentTime().seconds), "serviceDuration": rounded(current?.duration),
                      "avDuration": rounded(item.duration.seconds.isFinite ? item.duration.seconds : -1)])
        next()
    }

    // MARK: Now Playing and remote commands

    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        // The service's length: AVPlayer misreads it for these fragmented MP4 streams.
        if let duration = current.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(_ url: URL?) {
        guard let url else { return }
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0, let image = UIImage(data: data) else { return }
            artwork = Self.makeArtwork(image)
            updateNowPlaying()
        }
    }

    /// MediaPlayer calls the image handler on its own queue, so it must not be main-actor isolated.
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ name: String, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log("remote", ["command": name])
                    action()
                }
                return .success
            }
        }
        handle(center.playCommand, "play") { [weak self] in self?.resume("remote") }
        handle(center.pauseCommand, "pause") { [weak self] in self?.pause("remote") }
        handle(center.togglePlayPauseCommand, "toggle") { [weak self] in self?.toggle() }
        handle(center.nextTrackCommand, "next") { [weak self] in self?.beginCommand("next"); self?.next() }
        handle(center.previousTrackCommand, "previous") { [weak self] in self?.beginCommand("previous"); self?.previous() }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let target = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            MainActor.assumeIsolated {
                self?.log("remote", ["command": "position", "target": self?.rounded(target) ?? -1])
                Task { await self?.seek(to: target) }
            }
            return .success
        }
    }

    // MARK: Scripted test (steps 1–3), SPIKE_AUDIOTEST=1

    func scriptedTest() async {
        log("test", ["step": "start"])
        play(at: 0)
        guard await waitUntil(20, { self.isPlaying }) else { log("test", ["step": "never played"]); return }
        try? await Task.sleep(for: .seconds(6))
        let beforePause = player.currentTime().seconds
        pause()
        try? await Task.sleep(for: .seconds(4))
        log("test", ["step": "paused 4s", "drift": rounded(player.currentTime().seconds - beforePause)])
        resume()
        try? await Task.sleep(for: .seconds(4))
        log("test", ["step": "resumed 4s", "pos": rounded(player.currentTime().seconds)])
        await seek(to: 120)
        try? await Task.sleep(for: .seconds(4))
        log("test", ["step": "after seek 120 +4s", "pos": rounded(player.currentTime().seconds)])
        let service = current?.duration ?? 0
        await seek(to: service - 8)
        let before = index
        let seekDone = Date()
        _ = await waitUntil(40, { self.index != before })
        log("test", ["step": "end/next", "secondsAfterSeek": rounded(Date().timeIntervalSince(seekDone)), "index": index,
                     "expectedSeconds": rounded(service - (service - 8))])
        _ = await waitUntil(20, { self.isPlaying && self.player.currentTime().seconds > 3 })
        log("test", ["step": "track 2 playing", "pos": rounded(player.currentTime().seconds)])
        previous()  // > 3 s: restart
        try? await Task.sleep(for: .seconds(2))
        previous()  // < 3 s: previous track
        _ = await waitUntil(20, { self.index == before && self.isPlaying })
        try? await Task.sleep(for: .seconds(3))
        log("test", ["step": "previous → track 1", "index": index, "pos": rounded(player.currentTime().seconds)])
        pause()
        log("test", ["step": "done"])
    }

    private func waitUntil(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }
}

struct NativeAudioView: View {
    @State private var audio = NativeAudioPlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(audio.current.map { "\($0.title) — \($0.artist)" } ?? (audio.resolving ? "resolving…" : "idle"))
                .font(.headline).lineLimit(1)
            Text(String(format: "%.1f / %.0f s (service) · %@", audio.position, audio.current?.duration ?? 0, audio.isPlaying ? "playing" : "paused"))
                .font(.caption.monospaced())
            HStack {
                Button("⏮") { audio.beginCommand("previous(app)"); audio.previous() }
                Button(audio.isPlaying ? "Pause" : "Play") { audio.current == nil ? audio.play(at: 0) : audio.toggle() }
                Button("⏭") { audio.beginCommand("next(app)"); audio.next() }
                Button("-10") { Task { await audio.seek(to: audio.position - 10) } }
                Button("+30") { Task { await audio.seek(to: audio.position + 30) } }
                Button("End-8") { Task { await audio.seek(to: (audio.current?.duration ?? 0) - 8) } }
            }
            .buttonStyle(.bordered)
            // The system volume slider (hardware buttons move it too).
            SystemVolumeSlider().frame(height: 34)
            Text(String(format: "outputVolume %.2f", audio.volume)).font(.caption.monospaced())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(audio.lines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onChange(of: scenePhase) { _, phase in
            let name = switch phase { case .active: "active"; case .inactive: "inactive"; case .background: "background"; @unknown default: "?" }
            audio.log("scenePhase", ["phase": name].merging(audio.playerState()) { a, _ in a })
        }
        .task {
            if ProcessInfo.processInfo.environment["SPIKE_AUDIOTEST"] == "1" { await audio.scriptedTest() }
        }
    }
}

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
