import Observation
import Foundation

/// The playback queue and its transport as the UI sees them. The queue (current entry, the
/// service's order, shuffle/reorder, continuation, unplayable entries) is the source of truth;
/// a `PlaybackEngine` plays the current entry and prepares the one expected next.
@MainActor
@Observable
final class PlayerModel {
    enum QueueStatus: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// Fixture volume (silent engine only); the native engine uses the system volume.
    private(set) var volume: Double = 0.65
    /// A playback failure to tell the listener about once.
    var playbackFailure: String?

    /// Entries in play order (after any shuffle or reorder).
    private var queue: [QueueItem] = []
    /// The service's order, for turning shuffle off.
    private var unshuffledOrder: [QueueItem] = []
    private var selectedIndex = 0
    /// Whether the current entry is showing its counterpart (song ↔ video).
    private(set) var isShowingCounterpart = false
    /// Likes as the service last reported them (queue rows); writes go through `actions`.
    private var likes: [Track.ID: Bool] = [:]
    private(set) var isShuffling = false
    private(set) var isRepeating = false
    /// Where the current queue came from, shown in the Queue header
    /// (YouTube Music: "재생 중인 트랙 출처: <seed> 믹스").
    private(set) var queueSource: String?
    private(set) var queueStatus: QueueStatus = .idle
    private var continuation: CatalogContinuation?
    private var lastSeed: QueueSeed?
    /// Only the newest request may apply its result.
    private var loadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?

    private let catalog: any MusicCatalog
    private let actions: LibraryActions
    @ObservationIgnored let engine: any PlaybackEngine

    init(catalog: any MusicCatalog, actions: LibraryActions, engine: any PlaybackEngine) {
        self.catalog = catalog
        self.actions = actions
        self.engine = engine
        engine.delegate = self
    }

    var isPlaying: Bool { engine.isPlaying }
    var position: Double { engine.position }
    /// Whether the transport produces real audio.
    var isAudible: Bool { engine.isAudible }

    // MARK: Current entry

    var currentItem: QueueItem? { queue.indices.contains(selectedIndex) ? queue[selectedIndex] : nil }

    /// The media now shown: the entry's primary, or its counterpart after a switch.
    var currentTrack: Track? {
        guard let item = currentItem else { return nil }
        return (isShowingCounterpart ? item.counterpart?.track : nil) ?? item.primary.track
    }

    var currentKind: MediaKind? {
        guard let item = currentItem else { return nil }
        return (isShowingCounterpart ? item.counterpart?.kind : nil) ?? item.primary.kind
    }

    /// Song ↔ Video media switching waits for native video; the native engine plays audio only.
    var canSwitchVariant: Bool { currentItem?.counterpart != nil && engine.supportsVariantSwitch }

    /// Song ↔ Video on the same entry: the position carries over through the
    /// segment map (or restarts when it falls outside every segment).
    func switchVariant() {
        guard let item = currentItem, canSwitchVariant else { return }
        let mapped = isShowingCounterpart
            ? item.segmentMap?.primaryPosition(forCounterpart: position)
            : item.segmentMap?.counterpartPosition(forPrimary: position)
        isShowingCounterpart.toggle()
        playCurrent(autoplay: isPlaying)
        engine.seek(to: mapped ?? 0)
    }

    func isFavorite(_ id: Track.ID) -> Bool { actions.value(.like(id), given: likes[id]) == true }

    var isCurrentTrackFavorite: Bool {
        currentTrack.map { isFavorite($0.id) } ?? false
    }

    /// The star is the service's like (see `LibraryActions` for the write's lifecycle).
    func toggleFavorite() {
        guard let id = currentTrack?.id else { return }
        let liked = isFavorite(id)
        actions.perform(.like(id, !liked), showing: !liked, for: .like(id), from: liked,
                        failureTitle: liked ? "좋아요를 취소하지 못했습니다" : "좋아요를 표시하지 못했습니다")
    }

    /// Takes the service's like state for the rows it reported.
    private func recordLikes(_ items: [QueueItem]) {
        for variant in items.flatMap({ [$0.primary] + ($0.counterpart.map { [$0] } ?? []) }) {
            if let liked = variant.isLiked { likes[variant.track.id] = liked }
        }
    }

    // MARK: Queue order

    var upcomingItems: [QueueItem] {
        Array(queue.dropFirst(selectedIndex + 1))
    }

    var hasMoreQueue: Bool { continuation != nil }

    func toggleShuffle() {
        guard currentItem != nil else { return }
        isShuffling.toggle()
        let remainder = upcomingItems
        let reordered: [QueueItem]
        if isShuffling {
            reordered = remainder.shuffled()
        } else {
            let remainingIDs = Set(remainder.map(\.id))
            reordered = unshuffledOrder.filter { remainingIDs.contains($0.id) }
        }
        queue.replaceSubrange((selectedIndex + 1)..<queue.count, with: reordered)
        syncUpcoming()
    }

    // A fixture repeat setting; there is no timer or automatic playback engine.
    func toggleRepeat() { isRepeating.toggle() }

    func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var remainder = upcomingItems
        guard !offsets.isEmpty, offsets.allSatisfy({ remainder.indices.contains($0) }),
              (0...remainder.count).contains(destination) else { return }
        let moved = offsets.sorted().map { remainder[$0] }
        for index in offsets.sorted(by: >) { remainder.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        remainder.insert(contentsOf: moved, at: insertion)
        queue.replaceSubrange((selectedIndex + 1)..<queue.count, with: remainder)
        unshuffledOrder = queue
        isShuffling = false
        syncUpcoming()
    }

    /// The media's own length once playing, else the service's listing.
    var duration: Double {
        guard let value = engine.duration ?? currentTrack?.duration, value.isFinite else { return 0 }
        return max(0, value)
    }

    var canGoNext: Bool {
        queue.indices.dropFirst(selectedIndex + 1).contains { queue[$0].isPlayable }
    }

    /// Apple Music and YouTube Music keep Previous enabled: it restarts the
    /// current track (or steps back when already near the start).
    var canGoPrevious: Bool {
        currentItem != nil
    }

    // MARK: Starting a queue

    /// YouTube Music starts a seed Mix for a song picked from a Home shelf; the
    /// queue is that Mix, not the neighbouring shelf items.
    func startMix(from track: Track) {
        start(.radio(track), showing: track, source: "\(track.title) 믹스")
    }

    /// YouTube Music "라디오 시작".
    func startRadio(from track: Track) {
        start(.radio(track), showing: track, source: "\(track.title) 라디오")
    }

    /// Artist page play: YouTube Music starts the artist's radio (믹스) rather than an album.
    func startRadio(for artist: Artist, songs: [Track], playlistID: String? = nil) {
        guard let first = songs.first else { return }
        start(.artist(playlistID: playlistID, songs: songs), showing: playlistID == nil ? first : nil,
              source: "\(artist.name) 라디오")
    }

    /// A release or playlist from `track`; `playlistID` is the service list its queue comes from.
    func play(_ track: Track, in tracks: [Track], source: String? = nil, playlistID: String? = nil) {
        start(.list(playlistID: playlistID, tracks: tracks, start: track), showing: track, source: source)
    }

    /// Shows `track` at once, then replaces the queue with the catalog's when it arrives.
    private func start(_ seed: QueueSeed, showing track: Track?, source: String?) {
        loadTask?.cancel()
        pageTask?.cancel()
        queueSource = source
        lastSeed = seed
        continuation = nil
        isShuffling = false
        isShowingCounterpart = false
        if let track {
            queue = [QueueItem(track: track)]
            unshuffledOrder = queue
            selectedIndex = 0
            playCurrent(autoplay: true)
            syncUpcoming()
        }
        load(seed)
    }

    /// Re-request the last queue after a failure.
    func retryQueue() {
        guard let seed = lastSeed else { return }
        load(seed)
    }

    private func load(_ seed: QueueSeed) {
        queueStatus = .loading
        loadTask = Task { [catalog] in
            do {
                let page = try await catalog.queue(seed)
                guard !Task.isCancelled else { return }
                apply(page)
            } catch {
                guard !Task.isCancelled else { return }
                queueStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// The service's queue replaces the placeholder; the entry it marks current becomes
    /// current, and the position stays when that is still the same media.
    private func apply(_ page: QueuePage) {
        let previous = currentTrack?.id
        let previousKey = currentItem?.id
        guard !page.items.isEmpty else { queueStatus = .idle; return }
        recordLikes(page.items)
        if let selected = page.selectedIndex, page.items[selected].isPlayable {
            queue = page.items
            selectedIndex = selected
        } else if let first = page.items.firstIndex(where: \.isPlayable) {
            queue = page.items
            selectedIndex = first
        } else {
            // Nothing the service returned can play here: keep the chosen track current
            // and list the service's entries after it, marked unplayable.
            queue = Array(queue.prefix(selectedIndex + 1)) + page.items
        }
        unshuffledOrder = queue
        isShowingCounterpart = false
        continuation = page.next
        queueStatus = .idle
        // The same media keeps playing under the service's entry; other media starts over.
        if let previousKey, currentTrack?.id == previous, let request = currentRequest {
            engine.relabel(currentKey: previousKey, to: request)
        } else {
            playCurrent(autoplay: true)
        }
        syncUpcoming()
    }

    /// Next page of an infinite (radio/mix) queue; called when the list reaches its end.
    func loadMoreQueue() {
        guard let token = continuation, pageTask == nil, queueStatus != .loading else { return }
        pageTask = Task { [catalog] in
            defer { pageTask = nil }
            do {
                let page = try await catalog.queuePage(token)
                guard !Task.isCancelled, continuation == token else { return }
                let known = Set(queue.map(\.id))
                let added = page.items.filter { !known.contains($0.id) }
                recordLikes(added)
                queue += added
                unshuffledOrder += added
                continuation = page.next
                syncUpcoming()
            } catch {
                guard !Task.isCancelled else { return }
                queueStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Transport

    func seek(position: Double) {
        guard position.isFinite, currentTrack != nil else { return }
        engine.seek(to: min(max(position, 0), duration))
    }

    // Selecting a visible Queue entry keeps the queue; unplayable entries can't be selected.
    func selectUpcoming(_ item: QueueItem) {
        guard item.isPlayable,
              let index = queue.indices.dropFirst(selectedIndex + 1).first(where: { queue[$0].id == item.id }) else { return }
        select(index, autoplay: true)
    }

    // Fixture volume only: this does not change device or audio-session volume.
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(max(value, 0), 1)
    }

    func togglePlayPause() {
        guard currentItem != nil else { return }
        isPlaying ? engine.pause() : engine.resume()
    }

    // Manual navigation preserves the current play/pause state. Unplayable entries are skipped.
    func next() {
        guard let index = queue.indices.dropFirst(selectedIndex + 1).first(where: { queue[$0].isPlayable }) else { return }
        select(index)
        if queue.count - selectedIndex < 5 { loadMoreQueue() }
    }

    func previous() {
        guard currentItem != nil else { return }
        if selectedIndex == 0 || position > 3 {
            engine.seek(to: 0)
        } else if let index = queue.indices.prefix(selectedIndex).last(where: { queue[$0].isPlayable }) {
            select(index)
        } else {
            engine.seek(to: 0)
        }
    }

    private func select(_ index: Int, autoplay: Bool? = nil) {
        let changed = index != selectedIndex
        selectedIndex = index
        if changed {
            isShowingCounterpart = false
            playCurrent(autoplay: autoplay ?? isPlaying)
        } else if autoplay == true {
            engine.resume()
        }
        syncUpcoming()
    }

    /// A sign-out or a new session: nothing from the previous session keeps playing.
    func reset() {
        loadTask?.cancel()
        pageTask?.cancel()
        engine.stop()
        queue = []
        unshuffledOrder = []
        selectedIndex = 0
        continuation = nil
        lastSeed = nil
        queueSource = nil
        queueStatus = .idle
        isShuffling = false
        isShowingCounterpart = false
    }

    // MARK: Engine

    private func request(for item: QueueItem, showingCounterpart: Bool = false) -> PlaybackRequest {
        let track = (showingCounterpart ? item.counterpart?.track : nil) ?? item.primary.track
        let artworkURL: URL? = if case .remote(let url) = track.artwork { url } else { nil }
        return PlaybackRequest(key: showingCounterpart ? item.id + ".counterpart" : item.id, videoID: track.id,
                               title: track.title, artist: track.artist, album: track.album,
                               artworkURL: artworkURL, duration: track.duration)
    }

    private var currentRequest: PlaybackRequest? {
        currentItem.map { request(for: $0, showingCounterpart: isShowingCounterpart) }
    }

    private func playCurrent(autoplay: Bool) {
        guard let request = currentRequest else { return }
        engine.play(request, autoplay: autoplay)
    }

    /// The next playable entry after the current one (what Next and the end of a track move to).
    private var nextPlayableIndex: Int? {
        queue.indices.dropFirst(selectedIndex + 1).first { queue[$0].isPlayable }
    }

    /// Tells the engine which entry to prepare; called after anything that can change it
    /// (selection, shuffle, reorder, a new or longer queue).
    private func syncUpcoming() {
        engine.setUpcoming(nextPlayableIndex.map { request(for: queue[$0]) })
    }
}

extension PlayerModel: PlaybackEngineDelegate {
    func engineAdvanced(to key: String) {
        // The prepared next entry is playing: follow it in the queue.
        guard let index = queue.indices.dropFirst(selectedIndex + 1).first(where: { queue[$0].id == key }) else { return }
        selectedIndex = index
        isShowingCounterpart = false
        if queue.count - selectedIndex < 5 { loadMoreQueue() }
        syncUpcoming()
    }

    func engineReachedEnd(of key: String) {
        guard currentItem?.id == key || currentRequest?.key == key else { return }
        if let index = nextPlayableIndex {
            select(index, autoplay: true)
            if queue.count - selectedIndex < 5 { loadMoreQueue() }
        } else {
            engine.pause()
            engine.seek(to: 0)
        }
    }

    func engineFailed(_ key: String, message: String) {
        guard currentRequest?.key == key else { return }
        playbackFailure = message
    }

    func engineRequestedNext() { next() }
    func engineRequestedPrevious() { previous() }
}
