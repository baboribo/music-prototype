import SwiftUI

/// Position and times. Its own view: it is the only part of the controls that changes as the track plays.
struct PlayerProgress: View {
    @Environment(PlayerModel.self) private var player
    /// While the listener drags: the bar follows the finger; one seek happens on release.
    @State private var scrubValue: Double?

    var body: some View {
        let shown = scrubValue ?? player.position
        let total = Int(player.duration.rounded())
        let elapsed = min(Int(shown), total)
        VStack(spacing: -PlayerMetrics.progressLabelOverlap) {
            PlaybackProgressSlider(value: shown, duration: player.duration,
                                   began: { scrubValue = player.position },
                                   changed: { scrubValue = $0 },
                                   ended: {
                                       if let target = scrubValue { player.seek(position: target) }
                                       scrubValue = nil
                                   },
                                   adjusted: { player.seek(position: $0) })
                .frame(height: PlayerMetrics.progressSliderHeight)
                .accessibilityLabel(player.isAudible ? "재생 위치" : "샘플 재생 위치")
                .accessibilityValue("\(Self.time(elapsed)) / \(Self.time(total))")
                .accessibilityIdentifier("player.progress")
            // Elapsed and remaining come from the same whole seconds, so they always add up to the length.
            HStack {
                Text(Self.time(elapsed))
                Spacer()
                Text("−\(Self.time(total - elapsed))")
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityHidden(true)
        }
        #if DEBUG
        .onChange(of: shown, initial: true) { _, value in PlayerSelfTest.renderedPosition = value }
        .onChange(of: player.duration, initial: true) { _, value in PlayerSelfTest.renderedDuration = value }
        #endif
    }

    static func time(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// The playback position bar: UIKit's thumbless media slider (`UISlider.Style.thumbless`), the look
/// of the SwiftUI slider with a hidden thumb.
///
/// A plain value input: the parent passes the position and duration and handles the interaction
/// callbacks; the slider holds no playback state of its own.
private struct PlaybackProgressSlider: UIViewRepresentable {
    let value: Double
    let duration: Double
    let began: () -> Void
    let changed: (Double) -> Void
    let ended: () -> Void
    /// A change without a drag (accessibility increment/decrement).
    let adjusted: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.sliderStyle = .thumbless
        slider.minimumTrackTintColor = .white.withAlphaComponent(0.8)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        guard !slider.isTracking else { return }
        slider.maximumValue = Float(max(1, duration))
        slider.setValue(Float(value), animated: false)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PlaybackProgressSlider?

        @objc func touchDown(_ slider: UISlider) { parent?.began() }
        @objc func valueChanged(_ slider: UISlider) {
            slider.isTracking ? parent?.changed(Double(slider.value)) : parent?.adjusted(Double(slider.value))
        }
        @objc func touchUp(_ slider: UISlider) { parent?.ended() }
    }
}
