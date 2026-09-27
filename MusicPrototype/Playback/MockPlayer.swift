import Observation
import Foundation

/// Local UI state only: no audio, network requests, timers, or system media session.
/// Selecting a fixture replaces this mock queue and starts at that fixture's index.
/// This prototype policy does not define the production YouTube Music queue behavior.
@MainActor
@Observable
final class MockPlayer {
    private(set) var currentTrack: Track?
    private(set) var isPlaying = false
    // User-controlled fixture values only; position never advances on its own.
    private(set) var position: Double = 0
    private(set) var volume: Double = 0.65

    private var queue: [Track] = []
    private var unshuffledOrder: [Track] = []
    private var selectedIndex = 0
    private var favoriteTrackIDs: Set<Track.ID> = []
    private(set) var isShuffling = false
    private(set) var isRepeating = false
    /// Where the current queue came from, shown in the Queue header
    /// (YouTube Music: "재생 중인 트랙 출처: <seed> 믹스").
    private(set) var queueSource: String?

    func isFavorite(_ id: Track.ID) -> Bool { favoriteTrackIDs.contains(id) }

    var isCurrentTrackFavorite: Bool {
        currentTrack.map { favoriteTrackIDs.contains($0.id) } ?? false
    }

    // Session-only fixture feedback; never writes to a service or device library.
    func toggleFavorite() {
        guard let id = currentTrack?.id else { return }
        if favoriteTrackIDs.contains(id) { favoriteTrackIDs.remove(id) }
        else { favoriteTrackIDs.insert(id) }
    }

    func toggleShuffle() {
        guard currentTrack != nil else { return }
        isShuffling.toggle()
        let remainder = upcomingTracks
        let reordered: [Track]
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
        var remainder = upcomingTracks
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
        selectedIndex + 1 < queue.count
    }

    /// Apple Music and YouTube Music keep Previous enabled: it restarts the
    /// current track (or steps back when already near the start).
    var canGoPrevious: Bool {
        currentTrack != nil
    }

    var upcomingTracks: [Track] {
        Array(queue.dropFirst(selectedIndex + 1))
    }

    /// YouTube Music starts a seed Mix for a song picked from a Home shelf; the
    /// queue is that Mix, not the neighbouring shelf items. Mock Mix: the seed
    /// followed by the rest of the local catalog in a stable order.
    func startMix(from track: Track) {
        let others = Catalog.tracks.filter { $0.id != track.id }
        let offset = (Catalog.tracks.firstIndex(of: track) ?? 0) % max(1, others.count)
        play(track, in: [track] + Array(others[offset...] + others[..<offset]), source: "\(track.title) 믹스")
    }

    /// YouTube Music "라디오 시작": same mock station order, labelled as a radio.
    func startRadio(from track: Track) {
        startMix(from: track)
        queueSource = "\(track.title) 라디오"
    }

    /// Artist page play: YouTube Music starts the artist's radio rather than an album.
    func startRadio(for artist: Artist) {
        let songs = artist.sections.compactMap { section -> [Track]? in
            if case .songs(let ids) = section.content { Catalog.tracks(ids) } else { nil }
        }.flatMap { $0 }
        guard let first = songs.first else { return }
        play(first, in: songs, source: "\(artist.name) 라디오")
    }

    func play(_ track: Track, in tracks: [Track], source: String? = nil) {
        queueSource = source
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            queue = tracks
            selectedIndex = index
        } else {
            queue = [track]
            selectedIndex = 0
        }

        unshuffledOrder = queue
        isShuffling = false

        selectCurrentTrack()
        isPlaying = true
    }

    func seek(position: Double) {
        guard position.isFinite, currentTrack != nil else { return }
        self.position = min(max(position, 0), duration)
    }

    // Selecting a visible Queue item retains the existing fixture context.
    func selectUpcoming(_ track: Track) {
        guard let index = queue.indices.dropFirst(selectedIndex + 1)
            .first(where: { queue[$0].id == track.id }) else { return }
        selectedIndex = index
        selectCurrentTrack()
        isPlaying = true
    }

    // This does not change device or audio-session volume.
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(max(value, 0), 1)
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        isPlaying.toggle()
    }

    // Manual navigation preserves the current play/pause state; nothing auto-advances.
    func next() {
        guard canGoNext else { return }
        selectedIndex += 1
        selectCurrentTrack()
    }

    func previous() {
        guard currentTrack != nil else { return }
        if selectedIndex == 0 || position > 3 {
            position = 0
        } else {
            selectedIndex -= 1
            selectCurrentTrack()
        }
    }

    private func selectCurrentTrack() {
        let track = queue[selectedIndex]
        if currentTrack?.id != track.id {
            position = 0
        }
        currentTrack = track
        position = min(position, duration)
    }
}
