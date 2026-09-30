import AVFoundation
import MediaPlayer
import OSLog
import UIKit

/// Native audio for the signed-in session: `PlaybackResolver` → (`GaplessLoader` | direct URL) →
/// one `AVQueuePlayer`, with the next entry prepared and queued behind the current one so the
/// player moves on by itself (gapless for continuous albums). Also owns the audio session,
/// Now Playing and the remote commands. Verified in `Spikes/WebPlayerSpike` (B3–B3.3).
@MainActor
@Observable
final class NativeAudioEngine: PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double?
    let supportsVariantSwitch = false
    let isAudible = true

    /// A resolved entry and its item. The loader (when gapless) lives exactly as long as this value:
    /// AVAssetResourceLoader holds its delegate weakly.
    private struct Prepared {
        var request: PlaybackRequest
        let audio: ResolvedAudio
        let item: AVPlayerItem
        let loader: GaplessLoader?
        /// The exact presented length (gapless) or the service's (direct URL).
        let duration: Double?
    }

    /// A prepared URL is replaced this long before it expires (`expire` is about 6 h out).
    private static let expiryMargin: TimeInterval = 600
    private static let log = Logger(subsystem: "MusicPrototype", category: "Playback")

    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var wanted: PlaybackRequest?
    /// Identifies the newest `play` call; a relabel keeps it (same media, new key).
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var current: Prepared?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var upcomingRequest: PlaybackRequest?
    @ObservationIgnored private var upcoming: Prepared?
    @ObservationIgnored private var upcomingTask: (key: String, task: Task<Prepared?, Never>)?
    @ObservationIgnored private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var artwork: (url: URL, artwork: MPMediaItemArtwork)?
    @ObservationIgnored private var endedAt: Date?
    /// A seek in flight: the player still reports the old time until it completes.
    @ObservationIgnored private var seekTarget: Double?

    init(resolver: PlaybackResolver) {
        self.resolver = resolver
        player.actionAtItemEnd = .advance
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        // The one source of `position`: AVPlayer's own clock (callbacks land on media-time multiples).
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateNowPlaying() }
        })
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated { self?.itemEnded(ended) }
        })
        // Another app or a call took the session: the system paused; the button must follow.
        tokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionDeactivated() }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let shouldResume = (note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext)?.recommendation == .shouldResume
            MainActor.assumeIsolated { if shouldResume { self?.resumeAfterInterruption() } }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Headphones removed: the system pauses; the button must follow.
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.isPlaying = false; self?.updateNowPlaying() } }
        })
        registerRemoteCommands()
    }

    /// Only the entry being shown may move the position: not an item still playing out while
    /// another entry resolves, and not the pre-seek time while a seek is in flight.
    private func playerTimeChanged(_ time: CMTime) {
        guard time.seconds.isFinite, seekTarget == nil, let current,
              player.currentItem === current.item, wanted?.key == current.request.key else { return }
        position = time.seconds
        checkUpcomingExpiry()
    }

    // MARK: PlaybackEngine

    func play(_ request: PlaybackRequest, autoplay: Bool) {
        isPlaying = autoplay
        if let current, current.request.key == request.key, current.request.videoID == request.videoID {
            autoplay ? resume() : pause()
            return
        }
        loadTask?.cancel()
        wanted = request
        loadGeneration += 1
        let generation = loadGeneration
        position = 0
        duration = request.duration
        updateNowPlaying()
        // The prepared next entry: switch at once.
        if let prepared = upcoming, matches(prepared.request, request), prepared.audio.isFresh(for: 120) {
            start(prepared)
            return
        }
        // Another entry is resolving: the current one must stop sounding now, as the UI already moved on.
        player.pause()
        seekTarget = nil
        // Still being prepared: wait for that work instead of starting over.
        var pending: Task<Prepared?, Never>?
        if let task = upcomingTask, task.key == request.key { pending = task.task }
        if pending == nil { discardUpcoming("selection is not the prepared next") }
        let started = Date()
        loadTask = Task {
            do {
                var prepared = await pending?.value
                if let candidate = prepared, !candidate.audio.isFresh(for: 120) { prepared = nil }
                if prepared == nil { prepared = try await prepare(request) }
                guard !Task.isCancelled, var prepared, loadGeneration == generation else { return }
                // A relabel while resolving: same media under the service's entry.
                if let wanted { prepared.request = wanted }
                PlaybackDiagnostics.record("started", ["ms": Int(Date().timeIntervalSince(started) * 1000), "prefetched": pending != nil,
                                                       "gapless": prepared.loader != nil, "phases": prepared.audio.timings])
                start(prepared)
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                let label = (error as? ResolutionError)?.label ?? "\(type(of: error))"
                Self.log.error("resolve failed: \(label, privacy: .public)")
                PlaybackDiagnostics.record("failed", ["error": label])
                isPlaying = false
                updateNowPlaying()
                delegate?.engineFailed(wanted?.key ?? request.key, message: error.localizedDescription)
            }
        }
    }

    func setUpcoming(_ request: PlaybackRequest?) {
        upcomingRequest = request
        if let prepared = upcoming, !(request.map { matches(prepared.request, $0) } ?? false) {
            discardUpcoming("expected next changed")
        }
        if let task = upcomingTask, task.key != request?.key {
            task.task.cancel()
            upcomingTask = nil
        }
        schedulePrefetch()
    }

    func relabel(currentKey: String, to request: PlaybackRequest) {
        guard current?.request.key == currentKey || wanted?.key == currentKey else { return }
        current?.request = request
        wanted = request
        updateNowPlaying()
    }

    func resume() {
        isPlaying = true
        checkUpcomingExpiry()
        guard let current else {
            // Nothing loaded (a failure, or never started): try the wanted entry again.
            if let wanted, loadTask == nil || loadTask?.isCancelled == true { play(wanted, autoplay: true) }
            return
        }
        // After a long pause the current URL may have expired: prepare it again where it was.
        if !current.audio.isFresh(for: 60) {
            let at = position
            let request = current.request
            self.current = nil
            loadTask?.cancel()
            loadTask = Task {
                do {
                    let prepared = try await prepare(request)
                    guard !Task.isCancelled else { return }
                    start(prepared)
                    await player.seek(to: CMTime(seconds: at, preferredTimescale: 44_100))
                } catch {
                    isPlaying = false
                    delegate?.engineFailed(request.key, message: error.localizedDescription)
                }
            }
            return
        }
        activateSession()
        player.play()
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        player.pause()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, current != nil else { return }
        let target = min(max(seconds, 0), duration ?? seconds)
        position = target
        seekTarget = target
        Task {
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 44_100), toleranceBefore: .zero, toleranceAfter: .zero)
            // A newer seek owns the position until it completes.
            guard seekTarget == target else { return }
            seekTarget = nil
            updateNowPlaying()
        }
    }

    func stop() {
        loadTask?.cancel()
        discardUpcoming("stopped")
        upcomingRequest = nil
        player.removeAllItems()
        current = nil
        wanted = nil
        isPlaying = false
        position = 0
        duration = nil
        itemObservations = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: Preparing items

    private func matches(_ a: PlaybackRequest, _ b: PlaybackRequest) -> Bool { a.key == b.key && a.videoID == b.videoID }

    /// `/player` → sig/n → URL, then the gapless rewrite when the file has the verified layout,
    /// else the URL itself (ended at the service's length, the B3 path).
    private func prepare(_ request: PlaybackRequest) async throws -> Prepared {
        let audio = try await resolver.resolve(request.videoID)
        try Task.checkCancellation()
        let item: AVPlayerItem
        var loader: GaplessLoader?
        let length: Double?
        #if DEBUG
        let inspection: GaplessLoader.Inspection = ProcessInfo.processInfo.environment["YTM_GAPLESS"] == "0"
            ? .unsupported("disabled (YTM_GAPLESS=0)") : await GaplessLoader.inspect(audio.url, itag: audio.itag)
        #else
        let inspection = await GaplessLoader.inspect(audio.url, itag: audio.itag)
        #endif
        switch inspection {
        case .supported(let rewrite):
            let gapless = GaplessLoader(source: audio.url, videoID: request.videoID, rewrite: rewrite)
            item = AVPlayerItem(asset: gapless.makeAsset())
            loader = gapless
            length = rewrite.duration
        case .unsupported(let reason):
            Self.log.info("gapless unsupported: \(reason, privacy: .public)")
            PlaybackDiagnostics.record("gaplessFallback", ["reason": reason, "itag": audio.itag])
            item = AVPlayerItem(url: audio.url)
            // As served, AVFoundation reports about twice the length and would only end there.
            if let service = audio.duration {
                item.forwardPlaybackEndTime = CMTime(seconds: service, preferredTimescale: 44_100)
            }
            length = audio.duration ?? request.duration
        }
        observeStatus(item)
        return Prepared(request: request, audio: audio, item: item, loader: loader, duration: length)
    }

    /// Makes `prepared` current: the queued item advances, anything else replaces the queue.
    private func start(_ prepared: Prepared) {
        seekTarget = nil
        if upcoming?.item === prepared.item { upcoming = nil }
        if upcomingTask?.key == prepared.request.key { upcomingTask = nil }
        current = prepared
        wanted = prepared.request
        loadTask = nil
        duration = prepared.duration
        position = 0
        activateSession()
        let items = player.items()
        if items.count > 1, items[1] === prepared.item {
            player.advanceToNextItem()
        } else {
            player.removeAllItems()
            player.insert(prepared.item, after: nil)
        }
        if isPlaying { player.play() } else { player.pause() }
        queueUpcoming()
        pruneObservations()
        updateNowPlaying()
        loadArtwork(prepared.request.artworkURL)
        schedulePrefetch()
    }

    /// Keeps the prepared next item directly behind the current one (AVQueuePlayer then moves on by itself).
    private func queueUpcoming() {
        guard let prepared = upcoming, let current, let item = player.currentItem, item === current.item,
              !player.items().contains(prepared.item), player.canInsert(prepared.item, after: item) else { return }
        player.insert(prepared.item, after: item)
    }

    /// Prepares the expected next entry and queues it behind the current item.
    private func schedulePrefetch() {
        // Only behind the entry actually playing: while another entry resolves, the item it would
        // be queued behind is about to be replaced.
        guard let request = upcomingRequest, let current, current.request.key == wanted?.key,
              upcoming == nil, upcomingTask == nil, request.key != current.request.key else { return }
        let started = Date()
        let task = Task { () -> Prepared? in
            do {
                let prepared = try await prepare(request)
                guard !Task.isCancelled, upcomingTask?.key == request.key else { return prepared }
                upcomingTask = nil
                upcoming = prepared
                queueUpcoming()
                PlaybackDiagnostics.record("prefetched", ["ms": Int(Date().timeIntervalSince(started) * 1000), "gapless": prepared.loader != nil,
                                                          "phases": prepared.audio.timings])
                return prepared
            } catch {
                if upcomingTask?.key == request.key { upcomingTask = nil }
                let label = (error as? ResolutionError)?.label ?? "\(type(of: error))"
                // Not fatal: the entry is resolved again when it becomes current.
                PlaybackDiagnostics.record("prefetchFailed", ["error": label])
                return nil
            }
        }
        upcomingTask = (request.key, task)
    }

    private func discardUpcoming(_ reason: String) {
        upcomingTask?.task.cancel()
        upcomingTask = nil
        guard let prepared = upcoming else { return }
        if prepared.item !== player.currentItem, player.items().contains(prepared.item) { player.remove(prepared.item) }
        upcoming = nil
        PlaybackDiagnostics.record("prefetchDiscarded", ["reason": reason])
        pruneObservations()
    }

    /// A queued URL close to expiry is replaced by a new resolution.
    private func checkUpcomingExpiry() {
        guard let prepared = upcoming, !prepared.audio.isFresh(for: Self.expiryMargin) else { return }
        discardUpcoming("expiring")
        schedulePrefetch()
    }

    // MARK: Player events

    private func currentItemChanged() {
        guard let item = player.currentItem, item !== current?.item else { return }
        guard let prepared = upcoming, prepared.item === item else { return }
        // AVQueuePlayer moved on to the queued entry by itself.
        upcoming = nil
        current = prepared
        wanted = prepared.request
        duration = prepared.duration
        position = 0
        PlaybackDiagnostics.record("advanced", ["msAfterEnd": endedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1,
                                                "gapless": prepared.loader != nil])
        endedAt = nil
        pruneObservations()
        updateNowPlaying()
        loadArtwork(prepared.request.artworkURL)
        delegate?.engineAdvanced(to: prepared.request.key)
    }

    private func itemEnded(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current.item) == id else { return }
        endedAt = Date()
        // The queued next item takes over by itself.
        if let prepared = upcoming, player.items().contains(prepared.item) { return }
        PlaybackDiagnostics.record("endedWithoutNext", [:])
        delegate?.engineReachedEnd(of: current.request.key)
    }

    private func observeStatus(_ item: AVPlayerItem) {
        let id = ObjectIdentifier(item)
        itemObservations[id] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let error = item.error.map { error -> String in
                let ns = error as NSError
                let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " < \($0.domain) \($0.code)" } ?? ""
                return "\(ns.domain) \(ns.code)\(underlying)"
            } ?? "-"
            Task { @MainActor in
                guard failed, let self else { return }
                PlaybackDiagnostics.record("itemFailed", ["error": error])
                if let current = self.current, current.item === item {
                    self.isPlaying = false
                    self.updateNowPlaying()
                    // The entry's key now (a relabel may have replaced the one it was prepared with).
                    self.delegate?.engineFailed(current.request.key, message: "오디오를 재생하지 못했습니다.")
                } else if self.upcoming?.item === item {
                    self.discardUpcoming("item failed")
                }
            }
        }
    }

    private func pruneObservations() {
        let live = Set([current?.item, upcoming?.item].compactMap { $0 }.map(ObjectIdentifier.init))
        itemObservations = itemObservations.filter { live.contains($0.key) }
    }

    /// Set when the system deactivated the session while playing (an interruption).
    @ObservationIgnored private var interrupted = false

    private func sessionDeactivated() {
        guard isPlaying else { return }
        interrupted = true
        isPlaying = false
        updateNowPlaying()
    }

    private func resumeAfterInterruption() {
        guard interrupted else { return }
        interrupted = false
        resume()
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.log.error("audio session: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    #if DEBUG
    /// Verification only (PlayerSelfTest).
    var debugPlayerTime: Double { player.currentTime().seconds }
    var debugRate: Double { Double(player.rate) }
    var debugCurrentKey: String { current?.request.key ?? "-" }
    #endif

    // MARK: Now Playing and remote commands

    private func updateNowPlaying() {
        guard let request = current?.request ?? wanted else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.title,
            MPMediaItemPropertyArtist: request.artist,
            MPMediaItemPropertyAlbumTitle: request.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: current == nil ? 0 : max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : position),
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artwork.url == request.artworkURL { info[MPMediaItemPropertyArtwork] = artwork.artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        PlaybackDiagnostics.record("nowPlaying", ["elapsed": ((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1) * 100).rounded() / 100,
                                                  "rate": info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1,
                                                  "duration": ((duration ?? -1) * 100).rounded() / 100])
    }

    private func loadArtwork(_ url: URL?) {
        guard let url, artwork?.url != url else { return }
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0, let image = UIImage(data: data) else { return }
            artwork = (url, Self.makeArtwork(image))
            updateNowPlaying()
        }
    }

    /// MediaPlayer calls the image handler on its own queue: it must not inherit main-actor isolation
    /// (a Swift 6 isolation trap otherwise, seen in the B3 spike).
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NativeAudioEngine) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
                return .success
            }
        }
        handle(center.playCommand) { $0.resume() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.togglePlayPauseCommand) { $0.isPlaying ? $0.pause() : $0.resume() }
        handle(center.nextTrackCommand) { $0.delegate?.engineRequestedNext() }
        handle(center.previousTrackCommand) { $0.delegate?.engineRequestedPrevious() }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let target = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            MainActor.assumeIsolated { self?.seek(to: target) }
            return .success
        }
    }
}

/// Debug builds only: states and numbers for on-device verification (`Documents/playback.log`).
/// Never URLs, cookies, signatures or media identifiers beyond what is listed.
enum PlaybackDiagnostics {
    @MainActor static func record(_ kind: String, _ body: [String: Any]) {
        #if DEBUG
        var entry = body
        entry["kind"] = kind
        entry["t"] = (Date().timeIntervalSince1970 * 10).rounded() / 10
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let file = URL.documentsDirectory.appending(path: "playback.log")
        if !FileManager.default.fileExists(atPath: file.path()) { try? Data().write(to: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
        #endif
    }
}
