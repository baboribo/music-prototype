import SwiftUI

// AppShell owns the selected mode across collapse and reopening.
enum PlayerMode { case artwork, queue }

struct FullPlayer: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.interactivePlayerTransitionContext) private var transitionContext
    @Binding var mode: PlayerMode
    let closePlayer: () -> Void
    @State private var accessibilityControlsHeight: CGFloat = 360

    var body: some View {
        GeometryReader { geometry in
            let footerHeight = dynamicTypeSize.isAccessibilitySize
                ? accessibilityControlsHeight
                : max(274, geometry.size.height * 0.36)
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
                    PlayerUpperContent(track: track, mode: mode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if let transitionContext {
                                InteractivePlayerDismissRegion(context: transitionContext, kind: .allowed)
                            }
                        }
                    PlayerControls(mode: $mode) { height in
                        accessibilityControlsHeight = height.rounded(.up)
                    }
                        .frame(height: footerHeight)
                        .background {
                            if let transitionContext {
                                InteractivePlayerDismissRegion(context: transitionContext, kind: .excluded)
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .tint(.white.opacity(0.8))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .background {
            PlayerBackdrop(theme: player.currentTrack?.artwork ?? .midnight)
                .ignoresSafeArea()
        }
        .accessibilityAction(.escape, closePlayer)
    }
}

private struct PlayerControls: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var mode: PlayerMode
    let onAccessibilityHeightChange: (CGFloat) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    progress
                    transport.frame(height: 64)
                    volume.frame(height: 44)
                    modes.frame(height: 44)
                    mockNotice
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height > 0 { onAccessibilityHeightChange(height) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                GeometryReader { geometry in
                    let height = geometry.size.height
                    ZStack(alignment: .top) {
                        progress.frame(maxWidth: .infinity).offset(y: 3)
                        transport.position(x: geometry.size.width / 2, y: height * 0.40)
                        volume.frame(height: 44)
                            .position(x: geometry.size.width / 2, y: height * 0.72)
                        modes.position(x: geometry.size.width / 2, y: height * 0.90)
                        mockNotice
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .position(x: geometry.size.width / 2, y: height + 2)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
    }

    private var mockNotice: some View {
        Text("샘플 재생 · 오디오 없음")
            .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .caption)
            .foregroundStyle(.white.opacity(0.65))
    }

    private var progress: some View {
        VStack(spacing: -2) {
            Slider(value: Binding(get: { player.position }, set: { player.seek(position: $0) }), in: 0...max(1, player.duration)) {
                Text("샘플 재생 위치")
            }
            .sliderThumbVisibility(.hidden)
            .frame(height: 36)
            .accessibilityValue("\(time(player.position)) / \(time(player.duration))")
            .accessibilityIdentifier("player.progress")
            HStack {
                Text(time(player.position))
                Spacer()
                Text("−\(time(max(0, player.duration - player.position)))")
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack {
            transportButton("이전 곡", symbol: "backward.fill", identifier: "player.previous", enabled: player.canGoPrevious) { player.previous() }
            Spacer()
            transportButton(player.isPlaying ? "일시정지" : "재생", symbol: player.isPlaying ? "pause.fill" : "play.fill", identifier: "player.playPause", prominent: true) { player.togglePlayPause() }
            Spacer()
            transportButton("다음 곡", symbol: "forward.fill", identifier: "player.next", enabled: player.canGoNext) { player.next() }
        }
        .padding(.horizontal, 45)
    }

    private var volume: some View {
        Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1) {
            Text("샘플 음량")
        } minimumValueLabel: {
            Image(systemName: "speaker.fill").font(.system(size: 14))
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 14))
        }
        .sliderThumbVisibility(.hidden)
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityValue("\(Int(player.volume * 100))퍼센트")
        .accessibilityIdentifier("player.volume")
    }

    private var modes: some View {
        HStack {
            unavailableMode("가사", symbol: "quote.bubble", explanation: "샘플에는 가사가 없습니다")
            Spacer()
            unavailableMode("오디오 출력", symbol: "airplay.audio", explanation: "샘플은 오디오를 출력하지 않습니다")
            Spacer()
            Group {
                if mode == .queue {
                    queueToggle(labelEdge: 24)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .foregroundStyle(Color.black.opacity(0.75))
                } else {
                    queueToggle(labelEdge: 44)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .tint(.white.opacity(0.8))
            .accessibilityValue(mode == .queue ? "대기열 표시 중" : "앨범 아트 표시 중")
            .accessibilityIdentifier("player.queue")
        }
        .padding(.horizontal, 46)
    }

    private func queueToggle(labelEdge: CGFloat) -> some View {
        Toggle(isOn: Binding(get: { mode == .queue }, set: { mode = $0 ? .queue : .artwork })) {
            Label("다음 재생", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
                .font(.system(size: 20))
                .frame(width: labelEdge, height: labelEdge)
                .contentShape(Circle())
        }
        .toggleStyle(.button)
    }

    private func unavailableMode(_ title: String, symbol: String, explanation: String) -> some View {
        Button {} label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: 20)).frame(width: 44, height: 44)
        }
        .foregroundStyle(.white.opacity(0.5))
        .disabled(true)
        .accessibilityHint(explanation)
    }

    private func transportButton(_ title: String, symbol: String, identifier: String, enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: prominent ? 46 : 28))
                .frame(width: 64, height: 64).contentShape(Circle())
        }
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}
