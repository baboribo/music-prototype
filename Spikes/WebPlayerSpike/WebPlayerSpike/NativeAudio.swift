import AVFoundation
import MediaPlayer
import SwiftUI

/// Native audio spike: a queue resolved by `PlaybackResolver`, one (queue) player, next-item
/// prefetch, the system Now Playing / remote commands, and system volume. Logs states and numbers only.
@MainActor
@Observable
final class NativeAudioPlayer {
    struct Entry: Identifiable, Equatable { let id: String; let label: String }
    /// Three ATV tracks this account can play (IDs from earlier /next responses).
    static let sample = [
        Entry(id: "NnRjwEhFU70", label: "밤편지"),
        Entry(id: "wh7j1uEpNsQ", label: "보라빛 밤"),
        Entry(id: "2C1Jg04INb4", label: "팔레트"),
    ]
    /// Pink Floyd, The Dark Side of the Moon (MPREb_nHbCAGX6uUL): tracks run into each other.
    static let album = [
        Entry(id: "CDko2ux1bkE", label: "1 Speak to Me"),
        Entry(id: "_396y7Vk9NA", label: "2 Breathe"),
        Entry(id: "0Qhjiz_Ceu4", label: "3 On the Run"),
        Entry(id: "80LhtHY_fHw", label: "4 Time"),
        Entry(id: "hOhTDRdcx4o", label: "5 The Great Gig in the Sky"),
        Entry(id: "q9NtWkikVAE", label: "6 Money"),
        Entry(id: "5wth9BScmGY", label: "7 Us and Them"),
        Entry(id: "e3n4fRYTc94", label: "8 Any Colour You Like"),
        Entry(id: "Rly0qaXeSPg", label: "9 Brain Damage"),
        Entry(id: "4wYd-sqzY-k", label: "10 Eclipse"),
    ]

    /// How the next track takes over: resolve at the boundary (the B3 baseline), a prefetched item
    /// swapped in with `replaceCurrentItem`, or a prefetched item already queued in `AVQueuePlayer`.
    enum Transition: String, CaseIterable, Identifiable { case off, replace, queue; var id: String { rawValue } }

    private(set) var queue: [Entry] = NativeAudioPlayer.sample
    private(set) var index = 0
    private(set) var current: ResolvedAudio?
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var lines: [String] = []
    private(set) var resolving = false
    private(set) var transition: Transition = .queue
    /// The listener's intent: a pause during resolution must hold when the item arrives.
    private var wantsPlayback = false
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume

    private let resolver = PlaybackResolver(session: WebKitCookieSource(), playerJS: WebPlayerJSProvider(),
                                            solver: JSCSolver(release: .ejs080))
    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private let file = URL.documentsDirectory.appending(path: "audio.log")
    private var loadTask: Task<Void, Never>?

    /// Every item this player made, with the queue slot and resolution it plays (held strongly,
    /// so an identifier is never reused while listed). Pruned when an item leaves the player.
    private struct Loaded { let item: AVPlayerItem; let index: Int; let audio: ResolvedAudio }
    private var loaded: [ObjectIdentifier: Loaded] = [:]
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// The one prepared next track: `/player` → sig/n → URL → item. Keyed by slot and video, so a
    /// reorder, shuffle or direct selection that changes the expected next drops it.
    private struct Prefetch {
        let index: Int
        let videoID: String
        var task: Task<Void, Never>?
        var audio: ResolvedAudio?
        var item: AVPlayerItem?
    }
    private var prefetch: Prefetch?
    /// A prepared URL is replaced this long before it expires (`expire` is about 6 h out).
    static let expiryMargin: TimeInterval = 600
    private(set) var prefetchState = "-"

    init() {
        log("launch", ["UIBackgroundModes": Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []]
            .merging(sessionState()) { a, _ in a })
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.position = time.seconds
                self?.checkPrefetchExpiry()
            }
        }
        // AVQueuePlayer advances on its own; the queue slot and Now Playing follow the item.
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
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
            // The reason is a string; read it by its key's value inside the main-actor block.
            let values = (note.userInfo ?? [:]).reduce(into: [String: String]()) { dict, pair in
                if let key = pair.key as? String, let value = pair.value as? String { dict[key] = value }
            }
            MainActor.assumeIsolated {
                let reason = values[AVPlayer.rateDidChangeReasonKey] ?? "?"
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
        if let mode = ProcessInfo.processInfo.environment["SPIKE_MODE"].flatMap(Transition.init(rawValue:)) { transition = mode }
        player.actionAtItemEnd = Self.endAction(transition)
        log("mode", ["transition": transition.rawValue])
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
        guard queue.indices.contains(index) else { return }
        self.index = index
        wantsPlayback = true
        loadTask?.cancel()
        mark("queueChanged")
        loadTask = Task { await load(index) }
    }

    /// Plays a queue slot: the prefetched item when it is for this slot (waiting for it if it is
    /// still resolving), otherwise a fresh resolution.
    private func load(_ index: Int) async {
        let entry = queue[index]
        if let pending = prefetch, pending.index == index, pending.videoID == entry.id {
            if pending.audio == nil {
                mark("prefetchWait")
                await pending.task?.value
                guard !Task.isCancelled else { return }
            }
            if let ready = prefetch, ready.index == index, ready.videoID == entry.id, let audio = ready.audio, let item = ready.item {
                if isFresh(audio, for: 120) {
                    prefetch = nil
                    mark("prefetchHit")
                    log("prefetch", ["step": "used", "index": index, "track": entry.label])
                    start(item)
                    return
                }
                discardPrefetch("expired at use")
            }
        }
        if prefetch != nil { discardPrefetch("selection is not the prepared next") }
        resolving = true
        defer { resolving = false }
        let started = Date()
        mark("resolveStart")
        do {
            let resolved = try await resolver.resolve(entry.id)
            guard !Task.isCancelled else { return }
            mark("resolveDone")
            log("resolved", ["index": index, "track": entry.label, "itag": resolved.itag,
                             "ms": Int(Date().timeIntervalSince(started) * 1000), "phases": resolved.timings,
                             "duration": rounded(resolved.duration), "expiresInMin": resolved.expiresAt.map { Int($0.timeIntervalSinceNow / 60) } ?? -1])
            start(makeItem(resolved, index: index))
        } catch {
            log("resolveFailed", ["index": index, "error": "\(error)", "cancelled": Task.isCancelled])
        }
    }

    private func makeItem(_ audio: ResolvedAudio, index: Int) -> AVPlayerItem {
        let item = AVPlayerItem(url: audio.url)
        // These fragmented MP4s carry the full length in mvhd as well as in their fragments;
        // AVPlayer adds both (2× duration) and would only end at twice the real length.
        // Ending the item at the service's length restores didPlayToEndTime.
        if let duration = audio.duration {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 44_100)
        }
        loaded[ObjectIdentifier(item)] = Loaded(item: item, index: index, audio: audio)
        observeStatus(item)
        return item
    }

    /// Makes `item` current. `currentItemChanged` then updates the slot, Now Playing and prefetch.
    private func start(_ item: AVPlayerItem) {
        activateSession("play")
        switch transition {
        case .queue:
            let items = player.items()
            if items.count > 1, items[1] === item {
                player.advanceToNextItem()
            } else {
                player.removeAllItems()
                player.insert(item, after: nil)
            }
        case .replace, .off:
            player.replaceCurrentItem(with: item)
        }
        if wantsPlayback { player.play() }
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, let info = loaded[ObjectIdentifier(item)] else { return }
        let changed = current?.videoID != info.audio.videoID || index != info.index
        index = info.index
        current = info.audio
        if prefetch?.item === item { prefetch = nil }
        pruneItems()
        if changed {
            log("current", ["index": info.index, "track": queue.indices.contains(info.index) ? queue[info.index].label : "?", "queued": player.items().count - 1])
            artwork = nil
            updateNowPlaying()
            loadArtwork(info.audio.artworkURL)
        }
        schedulePrefetch()
    }

    /// Drops bookkeeping for items that are neither in the player nor prefetched.
    private func pruneItems() {
        let live = Set(player.items().map(ObjectIdentifier.init)).union(prefetch?.item.map { [ObjectIdentifier($0)] } ?? [])
        for id in loaded.keys where !live.contains(id) {
            loaded[id] = nil
            itemObservations[id] = nil
        }
    }

    private func observeStatus(_ item: AVPlayerItem) {
        let id = ObjectIdentifier(item)
        itemObservations[id] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let duration = item.duration.seconds
            MainActor.assumeIsolated {
                guard let self, status == .readyToPlay else { return }
                let role = self.player.currentItem.map(ObjectIdentifier.init) == id ? "current" : (self.player.items().contains { ObjectIdentifier($0) == id } ? "queued" : "detached")
                if role == "current" { self.mark("itemReady") }
                self.log("itemReady", ["role": role, "index": self.loaded[id]?.index ?? -1,
                                       "avDuration": self.rounded(duration.isFinite ? duration : -1),
                                       "serviceDuration": self.rounded(self.loaded[id]?.audio.duration)])
            }
        }
    }

    // MARK: Prefetch (next item only)

    private var nextIndex: Int? { queue.isEmpty ? nil : (index + 1) % queue.count }

    /// Keeps exactly the expected next track prepared; anything else is dropped.
    private func schedulePrefetch() {
        guard transition != .off, current != nil, let next = nextIndex else { return }
        let entry = queue[next]
        if let p = prefetch {
            if p.index == next, p.videoID == entry.id { return }
            discardPrefetch("expected next changed")
        }
        var p = Prefetch(index: next, videoID: entry.id)
        p.task = Task { await runPrefetch(next, entry) }
        prefetch = p
        prefetchState = "resolving \(entry.label)"
    }

    private func runPrefetch(_ index: Int, _ entry: Entry) async {
        let started = Date()
        log("prefetch", ["step": "start", "index": index, "track": entry.label])
        do {
            let audio = try await resolver.resolve(entry.id)
            guard !Task.isCancelled, prefetch?.index == index, prefetch?.videoID == entry.id else {
                log("prefetch", ["step": "late result dropped", "index": index])
                return
            }
            let item = makeItem(audio, index: index)
            prefetch?.audio = audio
            prefetch?.item = item
            log("prefetch", ["step": "resolved", "index": index, "ms": Int(Date().timeIntervalSince(started) * 1000),
                             "phases": audio.timings, "expiresInMin": audio.expiresAt.map { Int($0.timeIntervalSinceNow / 60) } ?? -1])
            switch transition {
            case .queue:
                // Queued behind the current item: AVQueuePlayer buffers it and advances without a gap in our code.
                if let currentItem = player.currentItem, player.canInsert(item, after: currentItem) {
                    player.insert(item, after: currentItem)
                    prefetchState = "queued \(entry.label)"
                    log("prefetch", ["step": "queued", "index": index])
                }
            case .replace:
                // A detached item cannot buffer; load the asset's header so the swap has less to do.
                let assetStart = Date()
                _ = try? await item.asset.load(.tracks, .duration)
                prefetchState = "ready \(entry.label)"
                log("prefetch", ["step": "assetLoaded", "index": index, "ms": Int(Date().timeIntervalSince(assetStart) * 1000)])
            case .off:
                break
            }
        } catch {
            log("prefetch", ["step": "failed", "index": index, "error": "\(error)", "cancelled": Task.isCancelled])
            if prefetch?.index == index, prefetch?.videoID == entry.id { prefetch = nil; prefetchState = "failed" }
        }
    }

    private func discardPrefetch(_ reason: String) {
        guard let p = prefetch else { return }
        p.task?.cancel()
        if let item = p.item, item !== player.currentItem, player.items().contains(item) { player.remove(item) }
        prefetch = nil
        prefetchState = "-"
        pruneItems()
        log("prefetch", ["step": "discarded", "reason": reason, "index": p.index, "hadItem": p.item != nil])
    }

    /// Test hook: pretend this many seconds have passed when judging URL expiry.
    private var expirySkew: TimeInterval = 0

    private func isFresh(_ audio: ResolvedAudio, for seconds: TimeInterval) -> Bool {
        guard let expires = audio.expiresAt else { return true }
        return expires.timeIntervalSinceNow - expirySkew > seconds
    }

    /// A prepared URL close to expiry is replaced by a new resolution (checked each playback second and on resume).
    private func checkPrefetchExpiry() {
        guard let audio = prefetch?.audio, !isFresh(audio, for: Self.expiryMargin) else { return }
        discardPrefetch("expiring")
        schedulePrefetch()
    }

    func simulateExpiry(_ seconds: TimeInterval) {
        expirySkew = seconds
        checkPrefetchExpiry()
        expirySkew = 0
    }

    /// Only the queue mode lets the player advance by itself. Otherwise the player must hold at the end:
    /// with `.advance`, AVQueuePlayer's own advance removed an item swapped in from the end notification.
    private static func endAction(_ mode: Transition) -> AVPlayer.ActionAtItemEnd { mode == .queue ? .advance : .pause }

    // MARK: Queue edits (each re-checks the expected next)

    func setQueue(_ entries: [Entry]) {
        discardPrefetch("queue replaced")
        queue = entries
        index = 0
        log("queueEdit", ["op": "replace", "count": entries.count])
    }

    func setTransition(_ mode: Transition) {
        guard mode != transition else { return }
        discardPrefetch("transition mode changed")
        transition = mode
        player.actionAtItemEnd = Self.endAction(mode)
        log("mode", ["transition": mode.rawValue])
        schedulePrefetch()
    }

    func shuffleUpcoming(reversed: Bool = false) {
        guard index + 1 < queue.count else { return }
        let upcoming = Array(queue[(index + 1)...])
        queue.replaceSubrange((index + 1)..., with: reversed ? upcoming.reversed() : upcoming.shuffled())
        log("queueEdit", ["op": reversed ? "reverseUpcoming" : "shuffleUpcoming", "next": queue[nextIndex ?? 0].label])
        schedulePrefetch()
    }

    /// Reorders two upcoming slots (offsets from the current slot).
    func swapUpcoming(_ a: Int, _ b: Int) {
        let (i, j) = (index + a, index + b)
        guard queue.indices.contains(i), queue.indices.contains(j) else { return }
        queue.swapAt(i, j)
        log("queueEdit", ["op": "swap +\(a) +\(b)", "next": queue[nextIndex ?? 0].label])
        schedulePrefetch()
    }

    func pause(_ source: String = "app") { wantsPlayback = false; player.pause(); log("cmd", ["pause": rounded(player.currentTime().seconds), "source": source]) }
    func resume(_ source: String = "app") {
        wantsPlayback = true
        activateSession("resume")
        checkPrefetchExpiry()
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

    func next() { log("cmd", ["next": nextIndex ?? -1]); nextIndex.map(play(at:)) }

    /// Starts a latency chain for a command (remote or in-app).
    func beginCommand(_ name: String) { commandStart = Date(); log("latency", ["step": "command \(name)", "ms": 0]) }

    /// Apple's convention: restart when past 3 s, else the previous track.
    func previous() {
        if player.currentTime().seconds > 3 {
            log("cmd", ["previous": "restart"])
            Task { await seek(to: 0) }
        } else {
            log("cmd", ["previous": index - 1])
            play(at: (index - 1 + queue.count) % queue.count)
        }
    }

    private func itemEnded(_ id: ObjectIdentifier) {
        // AVQueuePlayer may already have advanced when this arrives: match by our own records.
        guard let ended = loaded[id], ended.index == index else { return }
        let nextItem = prefetch?.item
        log("ended", ["index": ended.index, "pos": rounded(ended.item.currentTime().seconds), "serviceDuration": rounded(ended.audio.duration),
                      "transition": transition.rawValue, "prefetch": prefetchState,
                      "nextStatus": nextItem.map { $0.status == .readyToPlay ? "ready" : ($0.status == .failed ? "failed" : "unknown") } ?? "none",
                      "nextBuffered": rounded(nextItem?.loadedTimeRanges.last.map { $0.timeRangeValue.end.seconds })])
        beginCommand("auto")
        measureGap(after: id)
        if transition == .queue, player.items().contains(where: { ObjectIdentifier($0) != id }) { return }  // advancing by itself
        if transition == .queue { log("prefetch", ["step": "miss at end", "state": prefetchState]) }
        next()
    }

    /// Estimates the silence between tracks: when the new item's time 0 played, relative to the end
    /// notification (observed wall time minus the new item's position). Log-based; the ear decides.
    private func measureGap(after ended: ObjectIdentifier) {
        let endedAt = Date()
        Task {
            while Date().timeIntervalSince(endedAt) < 10 {
                if let item = player.currentItem, ObjectIdentifier(item) != ended, player.timeControlStatus == .playing {
                    let pos = item.currentTime().seconds
                    if pos.isFinite, pos > 0 {
                        let observed = Date().timeIntervalSince(endedAt)
                        log("gap", ["transition": transition.rawValue, "to": index, "observedMs": Int(observed * 1000),
                                    "newPos": rounded(pos), "estimatedGapMs": Int((observed - pos) * 1000)])
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            log("gap", ["transition": transition.rawValue, "timeout": true])
        }
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

    // MARK: Latency measurement, SPIKE_LATENCYTEST=1 (SPIKE_CLEAR_PRE=1 drops the preprocessed cache first)

    func latencyTest() async {
        if ProcessInfo.processInfo.environment["SPIKE_CLEAR_PRE"] == "1" {
            let dir = URL.cachesDirectory.appending(path: "solver-0.8.0")
            let removed = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? [])
                .filter { $0.hasPrefix("preprocessed-") }
            removed.forEach { try? FileManager.default.removeItem(at: dir.appending(path: $0)) }
            log("latencyTest", ["cleared": removed.count])
        }
        log("latencyTest", ["step": "start"])
        beginCommand("first play")
        play(at: 0)
        _ = await waitUntil(30, { self.isPlaying && self.player.currentTime().seconds > 1 })
        for step in ["next", "next", "next", "previous", "previous"] {
            try? await Task.sleep(for: .seconds(4))
            let target = index
            beginCommand(step)
            if step == "next" { next() } else {
                // Two presses: restart, then the previous track (as on the lock screen).
                previous()
                try? await Task.sleep(for: .milliseconds(400))
                previous()
            }
            _ = await waitUntil(30, { self.index != target && self.isPlaying && self.player.currentTime().seconds > 0.3 })
        }
        try? await Task.sleep(for: .seconds(3))
        pause()
        log("latencyTest", ["step": "done"])
    }

    // MARK: Boundary test on a continuous album, SPIKE_GAPTEST=1 (SPIKE_MODE=off|replace|queue)

    /// Plays the last seconds before three album boundaries, and exercises prefetch invalidation
    /// (reorders, a direct selection, simulated expiry) in between.
    func gapTest() async {
        log("gapTest", ["step": "start", "transition": transition.rawValue])
        setQueue(Self.album)
        beginCommand("first play")
        play(at: 0)
        _ = await waitUntil(30, { self.isPlaying && self.player.currentTime().seconds > 1 })
        await boundary(from: 0)   // Speak to Me → Breathe
        await boundary(from: 1)   // Breathe → On the Run

        // Invalidation: a reorder that changes the expected next drops it; one that keeps it does not.
        shuffleUpcoming(reversed: true)   // next becomes Eclipse
        try? await Task.sleep(for: .seconds(2))
        shuffleUpcoming(reversed: true)   // back to Time
        try? await Task.sleep(for: .seconds(2))
        swapUpcoming(2, 3)                // next unchanged
        swapUpcoming(2, 3)
        _ = await waitUntil(15, { self.prefetch?.audio != nil })
        simulateExpiry(6 * 3600)          // prepared URL treated as expiring → replaced
        _ = await waitUntil(15, { self.prefetch?.audio != nil })

        // Direct selection of a slot that is not the prepared next.
        beginCommand("select 9")
        play(at: 8)
        _ = await waitUntil(20, { self.playingSlot == 8 && self.player.currentTime().seconds > 1 })
        await boundary(from: 8)   // Brain Damage → Eclipse
        pause()
        log("gapTest", ["step": "done"])
    }

    /// Seeks to 6 s before the end of `slot` (once the next is prepared) and waits into the next track.
    private func boundary(from slot: Int) async {
        _ = await waitUntil(20, { self.playingSlot == slot })
        if transition != .off { _ = await waitUntil(20, { self.prefetch?.audio != nil && self.prefetchState.hasPrefix(self.transition == .queue ? "queued" : "ready") }) }
        let duration = player.currentItem.flatMap { loaded[ObjectIdentifier($0)]?.audio.duration } ?? 0
        await seek(to: duration - 6)
        log("gapTest", ["step": "boundary", "from": slot, "prefetch": prefetchState])
        _ = await waitUntil(25, { self.playingSlot == slot + 1 && self.player.currentTime().seconds > 4 })
    }

    /// The queue slot of the item actually playing (`index` moves as soon as a command arrives).
    private var playingSlot: Int? {
        guard player.timeControlStatus == .playing, let item = player.currentItem else { return nil }
        return loaded[ObjectIdentifier(item)]?.index
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
            }
            .buttonStyle(.bordered)
            Picker("Transition", selection: Binding(get: { audio.transition }, set: { audio.setTransition($0) })) {
                ForEach(NativeAudioPlayer.Transition.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Album") { audio.setQueue(NativeAudioPlayer.album); audio.play(at: 0) }
                Button("Shuffle next") { audio.shuffleUpcoming() }
                Button("End-6") { Task { await audio.seek(to: (audio.current?.duration ?? 0) - 6) } }
            }
            .buttonStyle(.bordered)
            Text("\(audio.index + 1)/\(audio.queue.count) · next: \(audio.prefetchState)").font(.caption.monospaced())
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
            if ProcessInfo.processInfo.environment["SPIKE_LATENCYTEST"] == "1" { await audio.latencyTest() }
            if ProcessInfo.processInfo.environment["SPIKE_GAPTEST"] == "1" { await audio.gapTest() }
        }
    }
}

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
