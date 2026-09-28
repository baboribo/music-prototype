import Foundation

/// A fixture's local placeholder, or the service's own image.
enum Artwork: Hashable, Sendable {
    case theme(ArtworkTheme)
    case remote(URL)

    /// The player backdrop is still fixture-colored; remote art gets a neutral theme
    /// until colors are sampled from the image.
    var backdropTheme: ArtworkTheme {
        if case .theme(let theme) = self { theme } else { .midnight }
    }
}
