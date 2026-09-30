import SwiftUI

// AppShell owns the selected mode across collapse and reopening.
enum PlayerMode { case artwork, queue }

struct FullPlayer: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.interactivePlayerTransitionContext) private var transitionContext
    @Binding var mode: PlayerMode
    let closePlayer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: closePlayer) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 60, height: 3)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, minHeight: 33, alignment: .top)
                    // Reference content starts 24pt under the grabber; keep a 44pt hit target.
                    .contentShape(Rectangle().inset(by: -6))
            }
            .accessibilityLabel("플레이어 접기")
            .accessibilityIdentifier("player.close")
            .background {
                if let transitionContext {
                    InteractivePlayerDismissRegion(context: transitionContext, kind: .allowed)
                }
            }
            if let track = player.currentTrack {
                // The controls keep their reference geometry; artwork and queue take what remains
                // (Apple Music's art is what scales between screen sizes).
                PlayerUpperContent(track: track, mode: mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if let transitionContext {
                            InteractivePlayerDismissRegion(context: transitionContext, kind: .allowed)
                        }
                    }
                PlayerControls(mode: $mode)
                    .background {
                        if let transitionContext {
                            InteractivePlayerDismissRegion(context: transitionContext, kind: .excluded)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .tint(.white.opacity(0.8))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .background {
            PlayerBackdrop(theme: player.currentTrack?.artwork.backdropTheme ?? .midnight)
                .ignoresSafeArea()
        }
        .accessibilityAction(.escape, closePlayer)
    }
}
