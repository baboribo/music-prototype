import SwiftUI

/// Album, Single and EP share Apple Music's release page; only the kind label differs.
struct ReleaseDetailView: View {
    @Environment(MockPlayer.self) private var player
    let release: Release

    private var tracks: [Track] { Catalog.tracks(of: release) }
    private var moreReleases: [BrowseItem] { Catalog.releases(by: release.artistID, excluding: release.id).map(BrowseItem.release) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DetailHeader(artwork: release.artwork, title: release.displayTitle, subtitle: release.artistName,
                             subtitleRoute: .artist(release.artistID), meta: "\(release.kind.label) · \(String(release.year))년")
                PlaybackActions(shuffle: { play(shuffled: true) }, play: { play(shuffled: false) }) {
                    LibrarySaveButton(id: release.id)
                }
                .padding(.top, 18)
                .padding(.bottom, 23)

                VStack(spacing: 0) {
                    Divider().padding(.leading, BrowseMetrics.margin).padding(.trailing, BrowseMetrics.margin)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        SongRow(track: track, leading: .number(index + 1),
                                subtitle: track.artist == release.artistName ? nil : track.artist,
                                hideAlbumLink: true) {
                            player.play(track, in: tracks, source: release.displayTitle)
                        }
                    }
                }
                .padding(.bottom, 24)

                DetailFooter(lines: ["\(String(release.year))년", durationSummary(tracks)]) {
                    if !moreReleases.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: "\(release.artistName)의 다른 음악", route: .artist(release.artistID))
                            Shelf(items: moreReleases)
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
                    NavigationLink(value: Route.artist(release.artistID)) {
                        Label("아티스트로 이동", systemImage: "music.microphone")
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
        player.play(first, in: list, source: release.displayTitle)
    }
}

/// Same header grammar as releases; rows carry artwork because items differ in origin.
struct PlaylistDetailView: View {
    @Environment(MockPlayer.self) private var player
    let playlist: Playlist

    private var tracks: [Track] { Catalog.tracks(of: playlist) }

    /// YouTube Music's page line for each source; shown in the footer, not the header.
    private var kindLine: String {
        switch playlist.kind {
        case .user: "재생목록 · 나"
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
                    if playlist.kind == .user || playlist.kind == .automatic {
                        // Own lists are already in the library; Apple shows download here.
                        Image(systemName: "arrow.down").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityLabel("다운로드 (샘플에서는 사용할 수 없음)")
                    } else {
                        LibrarySaveButton(id: playlist.id)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 23)

                VStack(spacing: 0) {
                    Divider().padding(.horizontal, BrowseMetrics.margin)
                    ForEach(tracks) { track in
                        SongRow(track: track, leading: .artwork, subtitle: track.artist) {
                            player.play(track, in: tracks, source: playlist.title)
                        }
                    }
                }
                .padding(.bottom, 24)

                DetailFooter(lines: [playlist.description, kindLine, durationSummary(tracks)].compactMap { $0 }) { EmptyView() }
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

    private func play(shuffled: Bool) {
        let list = shuffled ? tracks.shuffled() : tracks
        guard let first = list.first else { return }
        player.play(first, in: list, source: playlist.title)
    }
}

/// Full-bleed hero, then the sections the artist page returned, in order.
struct ArtistDetailView: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @State private var subscribed = false
    @State private var showingAbout = false
    let artist: Artist

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(artist.sections.enumerated()), id: \.offset) { _, section in
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
                ArtworkView(theme: artist.artwork, cornerRadius: 0)
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

                    Button { player.startRadio(for: artist) } label: {
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
    private func sectionView(_ section: ArtistSection) -> some View {
        switch section.content {
        case .songs(let ids):
            let songs = Catalog.tracks(ids)
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
        case .releases(let ids):
            shelf(section.title, ids.compactMap(Catalog.release).map(BrowseItem.release))
        case .playlists(let ids):
            shelf(section.title, ids.compactMap(Catalog.playlist).map(BrowseItem.playlist))
        case .artists(let ids):
            shelf(section.title, ids.compactMap(Catalog.artist).map(BrowseItem.artist))
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
        return "\(release.displayTitle) · \(String(release.year))년"
    }
}

