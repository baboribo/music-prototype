import SwiftUI

struct PlayerControls: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var mode: PlayerMode

    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 0) {
            progress
            gap(PlayerMetrics.progressToTransport)
            transport.frame(height: PlayerMetrics.transportHeight)
            gap(PlayerMetrics.transportToVolume)
            volume.frame(height: PlayerMetrics.rowHeight)
            gap(PlayerMetrics.volumeToModes)
            modes.frame(height: PlayerMetrics.rowHeight)
            if isAX {
                gap(PlayerMetrics.accessibilityRowGap)
                mockNotice.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            gap(PlayerMetrics.modesToBottom)
        }
        // Where Apple Music shows the output route: centred on the controls' bottom edge.
        .overlay(alignment: .bottom) {
            if !isAX {
                // A zero-height box on the bottom edge: the caption's centre lands on that edge.
                mockNotice
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 0)
            }
        }
        .padding(.horizontal, PlayerMetrics.horizontalInset)
        .accessibilityElement(children: .contain)
    }

    private func gap(_ height: CGFloat) -> some View {
        Color.clear.frame(height: isAX ? min(height, PlayerMetrics.accessibilityRowGap) : height)
    }

    @ViewBuilder private var mockNotice: some View {
        if !player.isAudible { sampleNotice }
    }

    private var sampleNotice: some View {
        Text("샘플 재생 · 오디오 없음")
            .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .caption)
            .foregroundStyle(.white.opacity(0.65))
    }

    private var progress: some View { PlayerProgress() }

    private var transport: some View {
        HStack {
            transportButton("이전 곡", symbol: "backward.fill", identifier: "player.previous", enabled: player.canGoPrevious) { player.previous() }
            Spacer()
            transportButton(player.isPlaying ? "일시정지" : "재생", symbol: player.isPlaying ? "pause.fill" : "play.fill", identifier: "player.playPause", prominent: true) { player.togglePlayPause() }
            Spacer()
            transportButton("다음 곡", symbol: "forward.fill", identifier: "player.next", enabled: player.canGoNext) { player.next() }
        }
        .padding(.horizontal, PlayerMetrics.transportInset)
    }

    /// The same row for both sources: the device volume (hardware buttons and Control Center move it
    /// too) with real audio, the fixture value otherwise.
    private var volume: some View {
        HStack(spacing: PlayerMetrics.volumeIconGap) {
            Image(systemName: "speaker.fill").font(.system(size: PlayerMetrics.speakerGlyph))
                .accessibilityHidden(true)
            if player.isAudible {
                SystemVolumeSlider()
                    .accessibilityLabel("음량")
            } else {
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1) {
                    Text("샘플 음량")
                }
                .sliderThumbVisibility(.hidden)
                .accessibilityValue("\(Int(player.volume * 100))퍼센트")
            }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: PlayerMetrics.speakerGlyph))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityIdentifier("player.volume")
    }

    private var modes: some View {
        HStack {
            unavailableMode("가사", symbol: "quote.bubble", explanation: "가사는 아직 지원하지 않습니다")
            Spacer()
            unavailableMode("오디오 출력", symbol: "airplay.audio", explanation: "오디오 출력 선택은 아직 지원하지 않습니다")
            Spacer()
            Group {
                if mode == .queue {
                    queueToggle(labelEdge: 24)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .foregroundStyle(Color.black.opacity(0.75))
                } else {
                    queueToggle(labelEdge: PlayerMetrics.rowHeight)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            .frame(width: PlayerMetrics.rowHeight, height: PlayerMetrics.rowHeight)
            .contentShape(Circle())
            .tint(.white.opacity(0.8))
            .accessibilityValue(mode == .queue ? "대기열 표시 중" : "앨범 아트 표시 중")
            .accessibilityIdentifier("player.queue")
        }
        .padding(.horizontal, PlayerMetrics.modeInset)
    }

    private func queueToggle(labelEdge: CGFloat) -> some View {
        Toggle(isOn: Binding(get: { mode == .queue }, set: { mode = $0 ? .queue : .artwork })) {
            Label("다음 재생", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
                .font(.system(size: PlayerMetrics.modeGlyph))
                .frame(width: labelEdge, height: labelEdge)
                .contentShape(Circle())
        }
        .toggleStyle(.button)
    }

    private func unavailableMode(_ title: String, symbol: String, explanation: String) -> some View {
        Button {} label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: PlayerMetrics.modeGlyph))
                .frame(width: PlayerMetrics.rowHeight, height: PlayerMetrics.rowHeight)
        }
        .foregroundStyle(.white.opacity(0.5))
        .disabled(true)
        .accessibilityHint(explanation)
    }

    private func transportButton(_ title: String, symbol: String, identifier: String, enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: prominent ? PlayerMetrics.playPauseGlyph : PlayerMetrics.transportGlyph))
                .frame(width: PlayerMetrics.transportHeight, height: PlayerMetrics.transportHeight)
                .contentShape(Circle())
        }
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

}
