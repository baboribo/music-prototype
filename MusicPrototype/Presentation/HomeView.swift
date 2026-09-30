import SwiftUI

// Section rhythm, list and tile geometry follow Apple Music's shelves (IMG_4060);
// the shelves, their order and their tap semantics are YouTube Music's.
struct HomeView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.musicCatalog) private var catalog
    @Environment(CatalogChanges.self) private var changes
    @Environment(AccountSession.self) private var account
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var loadedRevision = 0

    private enum Phase {
        case loading
        case loaded(HomeFeed)
        case failed(LoadFailure)
    }

    var body: some View {
        content
            .accessibilityIdentifier("home.scroll")
            .navigationTitle("Home")
            // Apple's tab roots put the large title on the toolbar row (IMG_4032, am-library).
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if account.canSignIn {
                    ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
                }
            }
            .task(id: attempt) { await load() }
            .task(id: changes.revision(.home)) { await reloadIfChanged() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            LoadFailureView(title: "Home을 불러오지 못했습니다", failure: failure) { phase = .loading; attempt += 1 }
        case .loaded(let feed):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(feed.sections) { section in
                        self.section(section)
                    }
                    if feed.isSample {
                        Text("샘플 음악 · 실제 오디오 없음")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, BrowseMetrics.margin)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    /// Runs on first appearance and on retry; returning to the tab keeps the loaded feed.
    private func load() async {
        guard case .loading = phase else { return }
        let revision = changes.revision(.home)
        do {
            let feed = try await catalog.home()
            phase = .loaded(feed)
            loadedRevision = revision
        } catch {
            // Leaving the tab cancels the request; the next appearance retries.
            guard !Task.isCancelled else { return }
            phase = .failed(LoadFailure(error))
        }
    }

    /// After a write changed Home (a pin): replace in place, keep the shown feed on failure.
    private func reloadIfChanged() async {
        let revision = changes.revision(.home)
        guard case .loaded = phase, revision != loadedRevision,
              let feed = try? await catalog.home(), !Task.isCancelled else { return }
        phase = .loaded(feed)
        loadedRevision = revision
    }

    private var pins: [String: ServiceToggle] {
        if case .loaded(let feed) = phase { feed.pins } else { [:] }
    }

    @ViewBuilder private func section(_ section: HomeSection) -> some View {
        switch section.content {
        case .quickPicks(let picks):
            quickPicks(title: section.title, picks)
        case .songs(let tracks, nil):
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(title: section.title)
                VStack(spacing: 0) {
                    ForEach(tracks) { track in
                        // YouTube Music starts a mix from a Home song.
                        SongRow(track: track, leading: .artwork, subtitle: track.artist) { player.startMix(from: track) }
                    }
                }
            }
        case .songs(let tracks, let rowsPerPage?):
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(title: section.title)
                pagedSongs(tracks, rowsPerPage: rowsPerPage)
            }
        case .items(let items):
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: section.title)
                Shelf(items: items, pins: pins)
            }
        }
    }

    /// The service pages long song shelves into columns; each page is one
    /// column of rows, with the next page peeking like the grid below.
    private func pagedSongs(_ tracks: [Track], rowsPerPage: Int) -> some View {
        let pages = stride(from: 0, to: tracks.count, by: rowsPerPage).map {
            Array(tracks[$0..<min($0 + rowsPerPage, tracks.count)])
        }
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        ForEach(pages[index]) { track in
                            SongRow(track: track, leading: .artwork, subtitle: track.artist) { player.startMix(from: track) }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 29) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }

    /// YouTube Music's 빠른 선곡 is a paged grid of mixed items (songs,
    /// playlists, pinned items), row-major per page. Presented in Apple Music's
    /// grid grammar (square tile, one-line title below) with a shelf peek.
    private func quickPicks(title: String, _ picks: [QuickPick]) -> some View {
        let pages = stride(from: 0, to: picks.count, by: 9).map {
            Array(picks[$0..<min($0 + 9, picks.count)])
        }
        return VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(pages.indices, id: \.self) { index in
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                            ForEach(0..<3, id: \.self) { row in
                                GridRow {
                                    ForEach(0..<3, id: \.self) { column in
                                        let slot = row * 3 + column
                                        if slot < pages[index].count {
                                            QuickPickTile(item: pages[index][slot], toggle: pins[pages[index][slot].id])
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

/// Tap plays or opens; long press offers 다시 듣기 고정 when the service does.
private struct QuickPickTile: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryActions.self) private var actions
    let item: QuickPick
    let toggle: ServiceToggle?

    var body: some View {
        content.pinContextMenu(itemID: item.id, toggle: toggle)
    }

    /// The data's pin state, or this session's pin write.
    private func shown(_ pinned: Bool) -> Bool {
        actions.value(.pin(itemID: item.id), given: pinned) ?? pinned
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .track(let track, let pinned):
            Button { player.startMix(from: track) } label: {
                tile(artwork: track.artwork, title: track.title, pinned: shown(pinned), playing: player.currentTrack?.id == track.id)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.title), \(track.artist)")
            .accessibilityValue(shown(pinned) ? "고정됨" : "")
            .accessibilityHint("이 곡으로 믹스 재생")
            .accessibilityIdentifier("track.\(track.id)")
        case .playlist(let playlist, let pinned):
            NavigationLink(value: Route.playlist(playlist.id)) {
                tile(artwork: playlist.artwork, title: playlist.title, pinned: shown(pinned), playing: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(shown(pinned) ? "고정됨" : "")
            .accessibilityIdentifier("quickpick.playlist.\(playlist.id)")
        case .release(let release, let pinned):
            NavigationLink(value: Route.release(release.id)) {
                tile(artwork: release.artwork, title: release.title, pinned: shown(pinned), playing: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(shown(pinned) ? "고정됨" : "")
            .accessibilityIdentifier("quickpick.release.\(release.id)")
        case .artist(let artist, let pinned):
            NavigationLink(value: Route.artist(artist.id)) {
                tile(artwork: artist.artwork, title: artist.name, pinned: shown(pinned), playing: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(shown(pinned) ? "고정됨" : "")
            .accessibilityIdentifier("quickpick.artist.\(artist.id)")
        }
    }

    private func tile(artwork: Artwork, title: String, pinned: Bool, playing: Bool) -> some View {
        VStack(spacing: 6) {
            ArtworkView(artwork: artwork, cornerRadius: 6)
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
