import SwiftUI

/// One persistent artwork moves between the large stage and the scrolling Queue header.
struct PlayerUpperContent: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPrefersCrossFadeTransitions) private var prefersCrossFade
    @Environment(\.interactivePlayerTransitionContext) private var transitionContext
    let track: Track
    let mode: PlayerMode

    @State private var largeIdentityHeight: CGFloat = 52
    @State private var artworkScrollOffset: CGFloat = 0
    @State private var queueScrollOffset: CGFloat = 0

    private static let compactEdge: CGFloat = 72
    private static let compactLeading: CGFloat = 32
    // Measured on the 430pt reference: large art top sits 30pt below the
    // upper region, and the title block starts 28pt below the art.
    private static let largeArtTop: CGFloat = 30
    private static let identityGap: CGFloat = 28

    private var showingQueue: Bool { mode == .queue }
    private var usesCrossFade: Bool { reduceMotion || prefersCrossFade }
    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    // Fitted to the reference recording: art size progress 25/61/84/95% at
    // 50ms steps, a critically damped spring with ~0.3s response.
    private var geometryAnimation: Animation? { usesCrossFade ? nil : .smooth(duration: 0.3) }

    // Fades from the same recording: outgoing content leaves while the art is
    // still moving, incoming content resolves only as the art settles.
    private func fade(appearing: Bool, inDelay: Double, inDuration: Double, outDuration: Double) -> Animation {
        if usesCrossFade { return .easeInOut(duration: 0.2) }
        return appearing ? .easeOut(duration: inDuration).delay(inDelay) : .easeOut(duration: outDuration)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(0, geometry.size.height)
            let availableArtWidth = max(0, width - 48)
            let largeEdge = isAX
                ? min(200, availableArtWidth)
                : max(0, min(availableArtWidth, height - largeIdentityHeight - Self.identityGap - 8))
            let largeTop = isAX ? 8 : max(0, min(Self.largeArtTop, height - largeIdentityHeight - Self.identityGap - largeEdge))
            let largeRect = CGRect(x: (width - largeEdge) / 2, y: largeTop - artworkScrollOffset, width: largeEdge, height: largeEdge)
            let compactRect = CGRect(x: Self.compactLeading, y: -queueScrollOffset, width: Self.compactEdge, height: Self.compactEdge)
            let artRect = showingQueue ? compactRect : largeRect
            // Paused art shrinks about its own center; the title block does not move.
            let artScale: CGFloat = showingQueue ? 1 : (player.isPlaying ? 1 : 0.73)
            let identityTop = artRect.maxY + (showingQueue ? 12 : Self.identityGap)
            // Queue content hangs below whichever header is showing, so the
            // growing artwork pushes it down and the shrinking one pulls it up.
            let queuePush = showingQueue ? 0 : (largeRect.maxY + Self.identityGap + largeIdentityHeight + 16) - compactRect.maxY

            ZStack(alignment: .topLeading) {
                queueContent
                    .offset(y: usesCrossFade ? 0 : queuePush)
                    .animation(geometryAnimation, value: mode)
                    .animation(fade(appearing: showingQueue, inDelay: 0.16, inDuration: 0.2, outDuration: 0.15)) {
                        $0.opacity(showingQueue ? 1 : 0)
                    }
                    .allowsHitTesting(showingQueue)
                    .accessibilityHidden(!showingQueue)

                largeIdentity(top: usesCrossFade ? largeRect.maxY + Self.identityGap : identityTop, viewportHeight: height)
                    .animation(geometryAnimation, value: mode)
                    .animation(fade(appearing: !showingQueue, inDelay: 0.12, inDuration: 0.14, outDuration: 0.12)) {
                        $0.opacity(showingQueue ? 0 : 1)
                    }
                    .allowsHitTesting(!showingQueue)
                    .accessibilityHidden(showingQueue)

                if !isAX {
                    compactIdentity(anchor: usesCrossFade ? compactRect : artRect, width: width)
                        .animation(geometryAnimation, value: mode)
                        .animation(fade(appearing: showingQueue, inDelay: 0.18, inDuration: 0.16, outDuration: 0.08)) {
                            $0.opacity(showingQueue ? 1 : 0)
                        }
                        .allowsHitTesting(showingQueue)
                        .accessibilityHidden(!showingQueue)
                }

                if usesCrossFade {
                    artwork(rect: largeRect, scale: player.isPlaying ? 1 : 0.73, compact: false, viewport: geometry.size)
                        .animation(.easeInOut(duration: 0.2)) { $0.opacity(showingQueue ? 0 : 1) }
                    artwork(rect: compactRect, scale: 1, compact: true, viewport: geometry.size)
                        .animation(.easeInOut(duration: 0.2)) { $0.opacity(showingQueue ? 1 : 0) }
                } else {
                    artwork(rect: artRect, scale: artScale, compact: showingQueue, viewport: geometry.size)
                        .animation(geometryAnimation, value: mode)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .animation(usesCrossFade ? nil : .smooth(duration: 0.35), value: player.isPlaying)
        }
    }

    private func artwork(rect: CGRect, scale: CGFloat, compact: Bool, viewport: CGSize) -> some View {
        let edge = rect.width * scale
        let visible = CGRect(x: rect.midX - edge / 2, y: rect.midY - edge / 2, width: edge, height: edge)
        // Apple Music's large art uses a small continuous radius; compact art a slightly smaller one.
        let radius: CGFloat = compact ? 6 : 8
        // Keep the fixture's internal GeometryReader and SF Symbol at a fixed size.
        // Scaling one rendered shape avoids waveform deformation during layout interpolation.
        return InteractivePlayerElement(role: .fullArtwork, context: transitionContext,
                                 isActive: compact == showingQueue,
                                 isFullyVisible: CGRect(origin: .zero, size: viewport).insetBy(dx: -1, dy: -1).contains(visible),
                                 cornerRadius: radius) {
            ArtworkView(artwork: track.artwork)
                .frame(width: 400, height: 400)
        }
            .frame(width: 400, height: 400)
            .scaleEffect(edge / 400)
            .frame(width: edge, height: edge)
            .clipShape(.rect(cornerRadius: radius))
            .shadow(color: .black.opacity(compact ? 0 : 0.2), radius: 18, y: 12)
            .position(x: visible.midX, y: visible.midY)
            .allowsHitTesting(false)
    }

    /// The title block rides the artwork's bottom edge, as in the reference recording.
    @ViewBuilder
    private func largeIdentity(top: CGFloat, viewportHeight: CGFloat) -> some View {
        let identity = PlayerTrackIdentity(track: track, compact: false)
            .padding(.leading, 32)
            .padding(.trailing, 27)
            .background {
                if let transitionContext {
                    InteractivePlayerDismissRegion(context: transitionContext, kind: .excluded)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { largeIdentityHeight = $0 }
        if isAX {
            // Large text can outgrow the region; only then is the stage scrollable.
            let contentHeight = max(viewportHeight, top + largeIdentityHeight + artworkScrollOffset)
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(0, top + artworkScrollOffset))
                        .accessibilityHidden(true)
                    identity
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: contentHeight, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                artworkScrollOffset = offset
            }
        } else {
            // A plain positioned row: a full-height scroll view here would swallow the dismissal drag.
            identity
                .frame(maxWidth: .infinity)
                .offset(y: top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Bottom-anchored to the moving artwork so it tracks its right edge while the art grows.
    private func compactIdentity(anchor: CGRect, width: CGFloat) -> some View {
        let leading = Self.compactLeading + Self.compactEdge + 12
        let rowWidth = max(0, width - leading - 24)
        return PlayerTrackIdentity(track: track, compact: true)
            .frame(width: rowWidth, height: Self.compactEdge)
            .offset(x: anchor.maxX + 12, y: anchor.maxY - Self.compactEdge)
    }

    private var queueContent: some View {
        List {
            VStack(alignment: .leading, spacing: 16) {
                if isAX {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(width: 72, height: 72).accessibilityHidden(true)
                        PlayerTrackIdentity(track: track, compact: true)
                    }
                } else {
                    // The compact identity is drawn outside the List, attached to the artwork.
                    Color.clear.frame(height: Self.compactEdge).accessibilityHidden(true)
                }
                queueOptions
                VStack(alignment: .leading, spacing: 2) {
                    Text("다음 재생")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    // Apple Music: "계속 재생 / 제공: 馬"; YouTube Music: "재생 중인 트랙 출처: … 믹스".
                    if let source = player.queueSource {
                        Text("출처: \(source)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 12, trailing: 19))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)

            if player.upcomingItems.isEmpty && player.queueStatus == .idle {
                Text("다음 곡이 없습니다")
                    .foregroundStyle(.white.opacity(0.65))
                    .listRowInsets(EdgeInsets(top: 12, leading: 32, bottom: 12, trailing: 32))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(player.upcomingItems) { item in
                    let upcoming = item.primary.track
                    Button {
                        player.selectUpcoming(item)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: upcoming.artwork).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(upcoming.title.isEmpty ? (item.unplayableReason ?? "") : upcoming.title).font(.body)
                                Text(upcoming.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                            }
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isPlayable)
                    .opacity(item.isPlayable ? 1 : 0.4)
                    .accessibilityLabel("\(upcoming.title), \(upcoming.artist)")
                    .accessibilityValue(item.isPlayable ? "" : "재생할 수 없음")
                    .accessibilityHint("이 곡부터 샘플 재생")
                    .accessibilityIdentifier("queue.track.\(item.id)")
                    .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 4, trailing: 19))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // Radio/mix queues continue as the list reaches its end.
                    .onAppear { if item.id == player.upcomingItems.last?.id { player.loadMoreQueue() } }
                }
                .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
            }
            queueStatusRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The reorder accessory ignores row insets; the reference keeps it 46pt from the edge.
        .padding(.trailing, 13)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
        .environment(\.editMode, .constant(.active))
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            queueScrollOffset = offset
        }
        .accessibilityIdentifier("player.queueList")
    }

    @ViewBuilder private var queueStatusRow: some View {
        switch player.queueStatus {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .moveDisabled(true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("대기열을 불러오지 못했습니다").font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.65))
                Button("다시 시도") { player.retryQueue() }.buttonStyle(.bordered).tint(.white)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 32, bottom: 12, trailing: 32))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
        }
    }

    private var queueOptions: some View {
        HStack(spacing: 13) {
            queueOption("임의 재생", symbol: "shuffle", selected: player.isShuffling, action: player.toggleShuffle)
            queueOption("반복", symbol: "repeat", selected: player.isRepeating, action: player.toggleRepeat)
                .accessibilityHint("샘플 반복 설정만 변경하며 오디오는 자동 재생되지 않습니다")
            queueOption("자동 재생", symbol: "infinity", selected: false, action: {})
                .disabled(true)
                .accessibilityHint("샘플에서는 네트워크 추천을 이어 재생할 수 없습니다")
            // Song ↔ Video on entries the service pairs; switches the queue state only (no audio yet).
            queueOption("곡 전환", symbol: "circle.lefthalf.filled", selected: player.isShowingCounterpart, action: player.switchVariant)
                .disabled(!player.canSwitchVariant)
                .accessibilityValue(player.canSwitchVariant ? (player.currentKind == .song ? "노래" : "동영상") : "")
                .accessibilityHint("같은 항목의 노래와 동영상 사이를 전환합니다. 샘플에는 오디오 엔진이 없습니다")
        }
    }

    private func queueOption(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        QueueOptionToggle(title: title, symbol: symbol, selected: selected, action: action)
    }
}

/// Reads the environment's enabled state so disabled options look disabled on the glass.
private struct QueueOptionToggle: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { selected }, set: { _ in action() })) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 20))
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .toggleStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white.opacity(0.8))
        .foregroundStyle(selected ? Color.black.opacity(0.75) : Color.white.opacity(0.8))
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct PlayerTrackIdentity: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let track: Track
    let compact: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    HStack(spacing: 4) {
                        favorite
                        more
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    identity
                    favorite
                    more
                }
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(compact ? .headline : .title3.weight(.semibold))
                .accessibilityIdentifier("player.title")
            Text(track.artist)
                .font(compact ? .body : .title3)
                .foregroundStyle(.white.opacity(0.7))
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var favorite: some View {
        Button(action: player.toggleFavorite) {
            Image(systemName: player.isCurrentTrackFavorite ? "star.fill" : "star")
                .font(.system(size: 20)).frame(width: 44, height: 44)
        }
        .accessibilityLabel(player.isCurrentTrackFavorite ? "즐겨찾기에서 제거" : "즐겨찾기에 추가")
        .accessibilityIdentifier("player.favorite")
    }

    private var more: some View {
        Menu {
            Button(player.isCurrentTrackFavorite ? "즐겨찾기에서 제거" : "즐겨찾기에 추가", systemImage: player.isCurrentTrackFavorite ? "star.slash" : "star") {
                player.toggleFavorite()
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("곡 옵션")
        .accessibilityIdentifier("player.more")
    }
}
