import Observation
import Foundation
import OSLog

/// Queue state from the catalog with mock transport: no audio, timers, or system
/// media session. The queue is the service's (`/next`) when the catalog is live,
/// the fixtures' otherwise; playback itself stays local until the native player exists.
@MainActor
@Observable
final class MockPlayer {
    enum QueueStatus: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private(set) var isPlaying = false
    // User-controlled fixture values only; position never advances on its own.
    private(set) var position: Double = 0
    private(set) var volume: Double = 0.65

    /// Entries in play order (after any shuffle or reorder).
    private var queue: [QueueItem] = []
    /// The service's order, for turning shuffle off.
    private var unshuffledOrder: [QueueItem] = []
    private var selectedIndex = 0
    /// Whether the current entry is showing its counterpart (song ↔ video).
    private(set) var isShowingCounterpart = false
    /// Likes as the service last reported them (queue rows) or as this session set them.
    private var likes: [Track.ID: Bool] = [:]
    /// Likes with a write in flight; queue pages don't overwrite them meanwhile.
    private var pendingLikes: Set<Track.ID> = []
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
    private let changes: CatalogChanges
    private static let log = Logger(subsystem: "MusicPrototype", category: "Player")

    init(catalog: any MusicCatalog, changes: CatalogChanges) {
        self.catalog = catalog
        self.changes = changes
    }

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

    var canSwitchVariant: Bool { currentItem?.counterpart != nil }

    /// Song ↔ Video on the same entry: the position carries over through the
    /// segment map (or restarts when it falls outside every segment).
    func switchVariant() {
        guard let item = currentItem, item.counterpart != nil else { return }
        let mapped = isShowingCounterpart
            ? item.segmentMap?.primaryPosition(forCounterpart: position)
            : item.segmentMap?.counterpartPosition(forPrimary: position)
        isShowingCounterpart.toggle()
        position = min(mapped ?? 0, duration)
    }

    func isFavorite(_ id: Track.ID) -> Bool { likes[id] == true }

    var isCurrentTrackFavorite: Bool {
        currentTrack.map { isFavorite($0.id) } ?? false
    }

    /// The star is the service's like. It changes at once and reverts if the write fails;
    /// a second tap waits for the first write.
    func toggleFavorite() {
        guard let id = currentTrack?.id, !pendingLikes.contains(id) else { return }
        let liked = !isFavorite(id)
        likes[id] = liked
        pendingLikes.insert(id)
        Task { [catalog] in
            defer { pendingLikes.remove(id) }
            do {
                changes.invalidate(try await catalog.apply(.like(id, liked)))
            } catch {
                likes[id] = !liked
                Self.log.error("like write failed, reverted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Takes the service's like state for rows it reported, except likes being written.
    private func recordLikes(_ items: [QueueItem]) {
        for variant in items.flatMap({ [$0.primary] + ($0.counterpart.map { [$0] } ?? []) }) {
            guard let liked = variant.isLiked, !pendingLikes.contains(variant.track.id) else { continue }
            likes[variant.track.id] = liked
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
    }

    var duration: Double {
        guard let value = currentTrack?.duration, value.isFinite else { return 0 }
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
        position = 0
        if let track {
            queue = [QueueItem(track: track)]
            unshuffledOrder = queue
            selectedIndex = 0
            isPlaying = true
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
        if currentTrack?.id != previous { position = 0 }
        isPlaying = true
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
            } catch {
                guard !Task.isCancelled else { return }
                queueStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Transport (mock)

    func seek(position: Double) {
        guard position.isFinite, currentTrack != nil else { return }
        self.position = min(max(position, 0), duration)
    }

    // Selecting a visible Queue entry keeps the queue; unplayable entries can't be selected.
    func selectUpcoming(_ item: QueueItem) {
        guard item.isPlayable,
              let index = queue.indices.dropFirst(selectedIndex + 1).first(where: { queue[$0].id == item.id }) else { return }
        select(index)
        isPlaying = true
    }

    // This does not change device or audio-session volume.
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(max(value, 0), 1)
    }

    func togglePlayPause() {
        guard currentItem != nil else { return }
        isPlaying.toggle()
    }

    // Manual navigation preserves the current play/pause state; nothing auto-advances.
    // Unplayable entries are skipped.
    func next() {
        guard let index = queue.indices.dropFirst(selectedIndex + 1).first(where: { queue[$0].isPlayable }) else { return }
        select(index)
        if queue.count - selectedIndex < 5 { loadMoreQueue() }
    }

    func previous() {
        guard currentItem != nil else { return }
        if selectedIndex == 0 || position > 3 {
            position = 0
        } else if let index = queue.indices.prefix(selectedIndex).last(where: { queue[$0].isPlayable }) {
            select(index)
        } else {
            position = 0
        }
    }

    private func select(_ index: Int) {
        let changed = index != selectedIndex
        selectedIndex = index
        if changed {
            isShowingCounterpart = false
            position = 0
        }
        position = min(position, duration)
    }
}
