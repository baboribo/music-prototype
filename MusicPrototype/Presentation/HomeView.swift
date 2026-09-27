import SwiftUI

// Section rhythm, list and tile geometry follow Apple Music's shelves (IMG_4060);
// the shelves, their order and their tap semantics are YouTube Music's.
struct HomeView: View {
    @Environment(MockPlayer.self) private var player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                quickPicks
                VStack(alignment: .leading, spacing: 8) {
                    ShelfHeader(title: "잊고 있던 좋은 음악")
                    VStack(spacing: 0) {
                        ForEach(Catalog.forgottenFavorites) { track in
                            // YouTube Music starts a mix from a Home song.
                            SongRow(track: track, leading: .artwork, subtitle: track.artist) { player.startMix(from: track) }
                        }
                    }
                }
                shelf("다시 듣기", Catalog.listenAgain)
                shelf("나만의 믹스", Catalog.mixesForYou)
                Text("샘플 음악 · 실제 오디오 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, BrowseMetrics.margin)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("home.scroll")
        .navigationTitle("Home")
        // Apple's tab roots put the large title on the toolbar row (IMG_4032, am-library).
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private func shelf(_ title: String, _ items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            Shelf(items: items)
        }
    }

    /// YouTube Music's 빠른 선곡 is a paged 3×3 grid of mixed items (songs,
    /// playlists, pinned items), row-major per page. Presented in Apple Music's
    /// grid grammar (square tile, one-line title below) with a shelf peek.
    private var quickPicks: some View {
        let pages = stride(from: 0, to: Catalog.quickPicks.count, by: 9).map {
            Array(Catalog.quickPicks[$0..<min($0 + 9, Catalog.quickPicks.count)])
        }
        return VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "빠른 선곡")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(pages.indices, id: \.self) { index in
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                            ForEach(0..<3, id: \.self) { row in
                                GridRow {
                                    ForEach(0..<3, id: \.self) { column in
                                        let slot = row * 3 + column
                                        if slot < pages[index].count {
                                            QuickPickTile(item: pages[index][slot])
                                        } else {
                                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                        }
                                    }
                                }
                            }
                        }
                        // Same 361pt page as Apple's shelves on a 430pt screen, so the next page peeks.
                        .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 29) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, BrowseMetrics.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("quickPicks.scroll")
        }
    }
}

private struct QuickPickTile: View {
    @Environment(MockPlayer.self) private var player
    let item: QuickPick

    var body: some View {
        switch item {
        case .track(let track):
            Button { player.startMix(from: track) } label: {
                tile(theme: track.artwork, title: track.title, pinned: false, playing: player.currentTrack?.id == track.id)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.title), \(track.artist)")
            .accessibilityHint("이 곡으로 믹스 재생")
            .accessibilityIdentifier("track.\(track.id)")
        case .playlist(let playlist, let pinned):
            NavigationLink(value: Route.playlist(playlist.id)) {
                tile(theme: playlist.artwork, title: playlist.title, pinned: pinned, playing: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(pinned ? "고정됨" : "")
            .accessibilityIdentifier("quickpick.playlist.\(playlist.id)")
        case .release(let release, let pinned):
            NavigationLink(value: Route.release(release.id)) {
                tile(theme: release.artwork, title: release.title, pinned: pinned, playing: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(pinned ? "고정됨" : "")
            .accessibilityIdentifier("quickpick.release.\(release.id)")
        }
    }

    private func tile(theme: ArtworkTheme, title: String, pinned: Bool, playing: Bool) -> some View {
        VStack(spacing: 6) {
            ArtworkView(theme: theme, cornerRadius: 6)
                .overlay(alignment: .topTrailing) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.white).padding(6).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if playing {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.caption).foregroundStyle(.white).padding(6).accessibilityHidden(true)
                    }
                }
            Text(title).font(.subheadline).foregroundStyle(.primary).lineLimit(1).frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }
}
