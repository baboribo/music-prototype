import SwiftUI

/// Player geometry measured on the Apple Music reference (iPhone 15 Pro Max, 430×932 pt,
/// IMG_4039): progress track centre y 617, transport centre 715, volume centre 814, mode
/// controls centre 866, output-route caption centred on the safe-area bottom (898). The gaps
/// below are those centres converted to spacing between rows of the stated heights.
enum PlayerMetrics {
    /// Leading/trailing edge of controls and the title block.
    static let horizontalInset: CGFloat = 32
    static let progressSliderHeight: CGFloat = 36
    /// The time labels sit 2pt into the slider's frame.
    static let progressLabelOverlap: CGFloat = 2
    static let transportHeight: CGFloat = 64
    static let transportInset: CGFloat = 45
    static let transportGlyph: CGFloat = 28
    static let playPauseGlyph: CGFloat = 46
    /// Volume and mode rows.
    static let rowHeight: CGFloat = 44
    static let speakerGlyph: CGFloat = 14
    /// Speaker glyph to volume track, both ends.
    static let volumeIconGap: CGFloat = 12
    static let modeInset: CGFloat = 46
    static let modeGlyph: CGFloat = 20

    static let progressToTransport: CGFloat = 34
    static let transportToVolume: CGFloat = 45
    static let volumeToModes: CGFloat = 8
    static let modesToBottom: CGFloat = 10
    /// Large accessibility text: rows stack with a uniform gap instead.
    static let accessibilityRowGap: CGFloat = 8

    /// Paused artwork shrinks about its centre (IMG_4045 vs IMG_4047).
    static let pausedArtworkScale: CGFloat = 0.73
}
