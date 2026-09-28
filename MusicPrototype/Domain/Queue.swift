import Foundation

/// What a playback queue is built from. The local tracks are the fallback
/// order when the source has no service playlist (fixtures, unknown lists).
enum QueueSeed: Hashable, Sendable {
    /// A song's radio/mix (`RDAMVM<videoId>` on the service).
    case radio(Track)
    /// A release or playlist started at `start`.
    case list(playlistID: String?, tracks: [Track], start: Track)
    /// An artist's 믹스 (`RDEM…`) or 셔플 (`RDAO…`) queue; `songs` is the fallback.
    case artist(playlistID: String?, songs: [Track])
}

/// The service's kind for a queue entry's media; Song ↔ Video switching pairs a
/// song with its video.
enum MediaKind: Hashable, Sendable {
    /// Art track (`MUSIC_VIDEO_TYPE_ATV`): audio with still artwork.
    case song
    /// Official music video (`OMV`).
    case officialVideo
    /// User-generated video (`UGC`).
    case userVideo
    case other
}

/// One playable media item within a queue entry.
struct QueueVariant: Hashable, Sendable {
    let track: Track
    let kind: MediaKind
}

/// How positions line up between an entry's primary and counterpart media.
/// Each segment says: `duration` ms starting at `primaryStart` in the primary
/// correspond to the same span starting at `counterpartStart` in the counterpart.
struct SegmentMap: Hashable, Sendable {
    struct Segment: Hashable, Sendable {
        let primaryStart: Double
        let counterpartStart: Double
        let duration: Double
    }

    let segments: [Segment]

    /// The counterpart position (seconds) for a primary position, if it falls in a segment.
    func counterpartPosition(forPrimary position: Double) -> Double? {
        segments.first { position >= $0.primaryStart && position < $0.primaryStart + $0.duration }
            .map { $0.counterpartStart + (position - $0.primaryStart) }
    }

    /// The primary position (seconds) for a counterpart position, if it falls in a segment.
    func primaryPosition(forCounterpart position: Double) -> Double? {
        segments.first { position >= $0.counterpartStart && position < $0.counterpartStart + $0.duration }
            .map { $0.primaryStart + (position - $0.counterpartStart) }
    }
}

/// One entry in a queue: the media the service put there, and optionally its
/// song/video counterpart with the position mapping between them.
struct QueueItem: Identifiable, Hashable, Sendable {
    /// Unique per entry (the service's `playlistSetVideoId`); the same video can appear twice.
    let id: String
    let primary: QueueVariant
    let counterpart: QueueVariant?
    let segmentMap: SegmentMap?
    /// The service's reason when the entry can't play here ("거주 국가에서 차단된 동영상").
    let unplayableReason: String?

    var isPlayable: Bool { unplayableReason == nil }

    /// A local entry for a track (fixtures, and the seed while the service queue loads).
    init(track: Track, id: String? = nil) {
        self.id = id ?? "local.\(track.id)"
        primary = QueueVariant(track: track, kind: .song)
        counterpart = nil
        segmentMap = nil
        unplayableReason = track.isPlayable ? nil : ""
    }

    init(id: String, primary: QueueVariant, counterpart: QueueVariant?, segmentMap: SegmentMap?, unplayableReason: String?) {
        self.id = id
        self.primary = primary
        self.counterpart = counterpart
        self.segmentMap = segmentMap
        self.unplayableReason = unplayableReason
    }
}

/// One page of a queue in the service's order.
struct QueuePage: Sendable {
    let items: [QueueItem]
    /// The entry the service marked as current (`selected`), if any.
    var selectedIndex: Int? = nil
    var next: CatalogContinuation? = nil
    /// Radio/mix queues keep producing pages.
    var isInfinite = false
}
