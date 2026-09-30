import Foundation

/// One queue entry as the engine plays it. `key` is the queue entry's id (the same video can
/// appear twice in a queue); `videoID` is the media.
struct PlaybackRequest: Equatable, Sendable {
    let key: String
    let videoID: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    /// The service's length, for display until the media reports its own.
    let duration: Double?
}

/// What the queue tells the engine about, and hears back. The queue (`PlayerModel`) stays the
/// source of truth for order, shuffle, continuation and unplayable entries; the engine only plays
/// the current entry and prepares the one expected next.
@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    /// The engine moved on to the prepared next entry by itself (end of the current one).
    func engineAdvanced(to key: String)
    /// The current entry ended with nothing prepared after it.
    func engineReachedEnd(of key: String)
    /// The current entry can't play (resolution or media failure).
    func engineFailed(_ key: String, message: String)
    /// Remote commands (lock screen, Control Center, Dynamic Island, headphones).
    func engineRequestedNext()
    func engineRequestedPrevious()
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }
    /// The listener's intent (what the play/pause button shows).
    var isPlaying: Bool { get }
    var position: Double { get }
    /// The media's own length once known, else the request's.
    var duration: Double? { get }
    /// Whether Song ↔ Video may switch media (the native engine plays audio only for now).
    var supportsVariantSwitch: Bool { get }
    /// Whether this engine produces real audio (the player UI hides its sample notice).
    var isAudible: Bool { get }

    /// Plays `request` (the prepared next one immediately when it matches).
    func play(_ request: PlaybackRequest, autoplay: Bool)
    /// The entry expected after the current one; nil when there is none. A different value
    /// drops whatever was prepared.
    func setUpcoming(_ request: PlaybackRequest?)
    /// The current entry now has another key (the service's queue replaced a placeholder).
    func relabel(currentKey: String, to request: PlaybackRequest)
    func resume()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// Fixture transport: no audio or system media session. The position only moves when the
/// listener seeks (previous mock behaviour), for fixtures and recorded-response runs.
@MainActor
@Observable
final class SilentPlaybackEngine: PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double?
    let supportsVariantSwitch = true
    let isAudible = false

    func play(_ request: PlaybackRequest, autoplay: Bool) {
        position = 0
        duration = request.duration
        isPlaying = autoplay
    }

    func setUpcoming(_ request: PlaybackRequest?) {}
    func relabel(currentKey: String, to request: PlaybackRequest) { duration = request.duration }
    func resume() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        position = min(max(seconds, 0), duration ?? 0)
    }

    func stop() {
        isPlaying = false
        position = 0
    }
}
