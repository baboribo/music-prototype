import SwiftUI

struct MiniPlayer: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.interactivePlayerTransitionContext) private var transitionContext
    let openPlayer: () -> Void

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 4) {
                Button(action: openPlayer) {
                    HStack(spacing: 10) {
                        InteractivePlayerElement(role: .miniArtwork, context: transitionContext, cornerRadius: 8) {
                            ArtworkView(artwork: track.artwork)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("플레이어 열기, \(track.title), \(track.artist)")
                .accessibilityIdentifier("mini.open")

                Button {
                    player.togglePlayPause()
                } label: {
                    Label(player.isPlaying ? "일시정지" : "재생", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("mini.playPause")

                if placement != .inline {
                    Button { player.next() } label: {
                        Label("다음 곡", systemImage: "forward.end.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!player.canGoNext)
                    .accessibilityIdentifier("mini.next")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}
