import MediaPlayer
import SwiftUI

/// The system volume slider (`MPVolumeView`), styled like the player's other sliders.
///
/// Layout contract: it fills the row it is given (full-height hit area), and its slider is centred
/// vertically in those bounds — so the track lines up with the speaker glyphs like any centred row
/// content. MPVolumeView otherwise places its slider at the top of its bounds.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> CenteredVolumeView {
        let view = CenteredVolumeView(frame: .zero)
        view.setVolumeThumbImage(UIImage(), for: .normal)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: CenteredVolumeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CenteredVolumeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: proposal.height ?? PlayerMetrics.rowHeight)
    }
}

/// MPVolumeView with its slider centred in its bounds (`volumeSliderRect(forBounds:)` is MediaPlayer's
/// supported layout override).
final class CenteredVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        let slider = super.volumeSliderRect(forBounds: bounds)
        return CGRect(x: slider.minX, y: bounds.midY - slider.height / 2, width: slider.width, height: slider.height)
    }

    #if DEBUG
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        let system = super.volumeSliderRect(forBounds: bounds)
        let used = volumeSliderRect(forBounds: bounds)
        PlaybackDiagnostics.record("volumeLayout", ["bounds": [bounds.width, bounds.height].map { ($0 * 10).rounded() / 10 },
                                                    "systemSlider": [system.minY, system.height].map { ($0 * 10).rounded() / 10 },
                                                    "centred": [used.minY, used.height].map { ($0 * 10).rounded() / 10 }])
    }
    #endif
}
