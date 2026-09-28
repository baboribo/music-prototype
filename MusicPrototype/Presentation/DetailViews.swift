import SwiftUI

/// Loads a catalog page by id with loading, failure and retry states. When a write
/// changes `scope`, the page reloads in place (keeping what it shows if that fails).
struct CatalogPage<Value: Sendable, Content: View>: View {
    @Environment(CatalogChanges.self) private var changes
    var scope: CatalogScope? = nil
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    /// The scope revision the shown value was loaded at.
    @State private var loadedRevision = 0

    private enum Phase {
        case loading
        case loaded(Value)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let value):
                // A reloaded value starts its content fresh (paging state included).
                content(value).id(loadedRevision)
            case .failed(let message):
                ContentUnavailableView {
                    Label("페이지를 불러오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("다시 시도") { phase = .loading; attempt += 1 }.buttonStyle(.bordered)
                }
            }
        }
        .task(id: attempt) {
            guard case .loading = phase else { return }
            let revision = currentRevision
            do {
                phase = .loaded(try await load())
                loadedRevision = revision
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
        .task(id: currentRevision) {
            let revision = currentRevision
            guard case .loaded = phase, revision != loadedRevision,
                  let value = try? await load(), !Task.isCancelled else { return }
            phase = .loaded(value)
            loadedRevision = revision
        }
    }

    private var currentRevision: Int { scope.map(changes.revision) ?? 0 }
}

/// Album, Single and EP share Apple Music's release page; only the kind label differs.
struct ReleaseDetailView: View {
    @Environment(MockPlayer.self) private var player
    let detail: ReleaseDetail

    private var release: Release { detail.release }
    private var tracks: [Track] { detail.tracks }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DetailHeader(artwork: release.artwork, title: release.displayTitle, subtitle: release.artistName,
                             subtitleRoute: release.artistID.map(Route.artist), meta: release.meta)
                PlaybackActions(shuffle: { play(shuffled: true) }, play: { play(shuffled: false) }) {
                    if let membership = detail.membership { LibrarySaveButton(membership: membership) }
                }
                .padding(.top, 18)
                .padding(.bottom, 23)

                VStack(spacing: 0) {
                    Divider().padding(.leading, BrowseMetrics.margin).padding(.trailing, BrowseMetrics.margin)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        SongRow(track: track, leading: .number(index + 1),
                                subtitle: track.artist == release.artistName ? nil : track.artist,
                                hideAlbumLink: true) {
                            player.play(track, in: tracks, source: release.displayTitle, playlistID: detail.queuePlaylistID)
                        }
                    }
                }
                .padding(.bottom, 24)

                DetailFooter(lines: [release.year.map { "\(String($0))년" }, durationSummary(tracks)].compactMap(\.self)) {
                    ForEach(detail.shelves) { shelf in
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: shelf.title, route: shelf.route)
                            Shelf(items: shelf.items)
                        }
                    }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(release.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Apple's release page keeps the bar title-less; the title stays for the back menu.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let artistID = release.artistID {
                        NavigationLink(value: Route.artist(artistID)) {
                            Label("아티스트로 이동", systemImage: "music.microphone")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .accessibilityLabel("\(release.displayTitle) 옵션")
            }
        }
        .accessibilityIdentifier("release.\(release.id)")
    }

    private func play(shuffled: Bool) {
        let list = shuffled ? tracks.shuffled() : tracks
        guard let first = list.first else { return }
        player.play(first, in: list, source: release.displayTitle, playlistID: shuffled ? nil : detail.queuePlaylistID)
    }
}

extension Release {
    /// "앨범 · 2017년"; either part may be unknown for service listings.
    var meta: String? {
        let parts = [kind?.label, year.map { "\(String($0))년" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Same header grammar as releases; rows carry artwork because items differ in origin.
struct PlaylistDetailView: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.musicCatalog) private var catalog
    let detail: PlaylistDetail
    /// Rows fetched after the first page, as the list scrolls to its end.
    @State private var more: [Track] = []
    @State private var next: PlaylistDetail.Continuation?
    @State private var loadingMore = false
    @State private var loadFailed = false

    init(detail: PlaylistDetail) {
        self.detail = detail
        _next = State(initialValue: detail.next)
    }

    private var playlist: Playlist { detail.playlist }
    private var tracks: [Track] { detail.tracks + more }
    /// The service playlist behind a `VL…` browse id, which its queue is built from.
    private var queuePlaylistID: String? { playlist.id.hasPrefix("VL") ? String(playlist.id.dropFirst(2)) : nil }

    /// YouTube Music's page line for each source; shown in the footer, not the header.
    private var kindLine: String {
        switch playlist.kind {
        // The page names no owner for user playlists; don't assume it's the listener's.
        case .user:
            playlist.isListenersOwn ? "재생목록 · 나" : playlist.owner.isEmpty ? "재생목록" : "재생목록 · \(playlist.owner)"
        case .editorial: "재생목록 · \(playlist.owner)"
        case .mix: "믹스 · 매일 업데이트"
        case .radio: "라디오"
        case .automatic: "자동 재생목록"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DetailHeader(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.owner)
                PlaybackActions(shuffle: { play(shuffled: true) }, play: { play(shuffled: false) }) {
                    if playlist.isListenersOwn {
                        // Own lists are already in the library; Apple shows download here.
                        Image(systemName: "arrow.down").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityLabel("다운로드 (샘플에서는 사용할 수 없음)")
                    } else if let membership = detail.membership {
                        LibrarySaveButton(membership: membership)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 23)

                // Lazy so the last row appears (and fetches the next page) only when scrolled to.
                LazyVStack(spacing: 0) {
                    Divider().padding(.horizontal, BrowseMetrics.margin)
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        SongRow(track: track, leading: .artwork, subtitle: track.artist) {
                            player.play(track, in: tracks, source: playlist.title, playlistID: queuePlaylistID)
                        }
                        .onAppear { if index == tracks.count - 1 { Task { await loadMore() } } }
                    }
                    if next != nil {
                        Group {
                            if loadFailed {
                                Button("나머지 곡 다시 불러오기") { Task { await loadMore() } }.buttonStyle(.bordered)
                            } else {
                                ProgressView()
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
                .padding(.bottom, 24)

                DetailFooter(lines: [playlist.description, kindLine, detail.summary ?? durationSummary(tracks)].compactMap { $0 }) { EmptyView() }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        .accessibilityIdentifier("playlist.\(playlist.id)")
    }

    private func loadMore() async {
        guard let token = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await catalog.playlistPage(token)
            more += page.tracks
            next = page.next
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func play(shuffled: Bool) {
        let list = (shuffled ? tracks.shuffled() : tracks).filter(\.isPlayable)
        guard let first = list.first else { return }
        player.play(first, in: list, source: playlist.title, playlistID: shuffled ? nil : queuePlaylistID)
    }
}

/// Full-bleed hero, then the sections the artist page returned, in order.
struct ArtistDetailView: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @State private var subscribed = false
    @State private var showingAbout = false
    let detail: ArtistDetail

    private var artist: Artist { detail.artist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(detail.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        .sheet(isPresented: $showingAbout) {
            NavigationStack {
                Text(artist.description ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(BrowseMetrics.margin)
                    .navigationTitle(artist.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .accessibilityIdentifier("artist.\(artist.id)")
    }

    /// Reference: name centred at 395pt, 72pt play at 465pt, image fading out by ~520pt.
    private var hero: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                // Fill the whole hero (image runs under the name), cropped from the square art.
                ArtworkView(artwork: artist.artwork, cornerRadius: 0)
                    .frame(width: geometry.size.height, height: geometry.size.height)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.6), .init(color: Color(.systemBackground), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 16) {
                Text(artist.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 8)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 36) {
                    Button { showingAbout = true } label: {
                        Image(systemName: "info").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .opacity(artist.description == nil ? 0 : 1)
                    .disabled(artist.description == nil)
                    .accessibilityLabel("아티스트 정보")

                    Button { player.startRadio(for: artist, songs: detail.songs, playlistID: detail.radioPlaylistID) } label: {
                        Image(systemName: "play.fill").font(.title.weight(.semibold)).frame(width: 72, height: 72)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.tint, in: Circle())
                    .accessibilityLabel("\(artist.name) 라디오 재생")

                    Button { subscribed.toggle() } label: {
                        Image(systemName: subscribed ? "star.fill" : "star")
                            .font(.title3.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(subscribed ? "구독 취소" : "구독")
                    .accessibilityValue("이 기기의 샘플 상태")
                }
            }
            .padding(.bottom, 19)
        }
        .frame(height: 520)
    }

    @ViewBuilder
    private func sectionView(_ section: ArtistDetail.Section) -> some View {
        switch section.content {
        case .songs(let songs):
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(title: section.title)
                VStack(spacing: 0) {
                    ForEach(songs.prefix(5)) { track in
                        SongRow(track: track, leading: .artwork, subtitle: releaseLine(track)) {
                            player.play(track, in: songs, source: "\(artist.name) 노래")
                        }
                    }
                }
            }
        case .items(let items):
            shelf(section.title, items)
        }
    }

    private func shelf(_ title: String, _ items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            Shelf(items: items)
        }
    }

    /// Apple: "I'm Nobody - Single · 2024년".
    private func releaseLine(_ track: Track) -> String {
        guard let release = track.releaseID.flatMap(Catalog.release) else { return track.album }
        return [release.displayTitle, release.year.map { "\(String($0))년" }].compactMap(\.self).joined(separator: " · ")
    }
}

