import SwiftUI

// MARK: Library

/// Apple Music Library root (am-library): pinned 3-column grid, category rows,
/// then a 2-column grid. Entries are YouTube Music's library (pins, recent activity).
struct LibraryView: View {
    private let pinnedColumns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    private let recentColumns = Array(repeating: GridItem(.flexible(), spacing: 13, alignment: .top), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: pinnedColumns, spacing: 16) {
                    ForEach(Catalog.libraryPinned) { item in
                        if let route = item.route {
                            NavigationLink(value: route) { pinnedTile(item) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library.pinned.\(item.id)")
                        }
                    }
                }
                .padding(.horizontal, BrowseMetrics.margin)
                .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(LibraryCategory.allCases, id: \.self) { category in
                        NavigationLink(value: Route.library(category)) { categoryRow(category) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.category.\(category.rawValue)")
                    }
                }
                .padding(.top, 20)

                ShelfHeader(title: "최근 활동").padding(.top, 34)
                LazyVGrid(columns: recentColumns, spacing: 20) {
                    ForEach(Catalog.libraryRecent) { item in
                        if let route = item.route {
                            NavigationLink(value: route) { GridTile(item: item) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library.\(item.id)")
                        }
                    }
                }
                .padding(.horizontal, BrowseMetrics.margin)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private func pinnedTile(_ item: BrowseItem) -> some View {
        VStack(spacing: 7) {
            ArtworkView(theme: item.artwork, cornerRadius: item.isArtist ? 999 : 8)
                .aspectRatio(1, contentMode: .fit)
            Text(item.title).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// 52.5pt rows, symbol centred at 32pt, text and separator from 61pt.
    private func categoryRow(_ category: LibraryCategory) -> some View {
        HStack(spacing: 0) {
            Image(systemName: category.symbol)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 24)
                .padding(.leading, BrowseMetrics.margin)
                .padding(.trailing, 17)
            Text(category.title).font(.title3)
            Spacer()
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                .padding(.trailing, BrowseMetrics.margin)
        }
        .frame(height: 52.5)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 61).padding(.trailing, BrowseMetrics.margin)
        }
    }
}

/// Two-column grid tile used by Library (recent activity, albums).
struct GridTile: View {
    let item: BrowseItem

    var body: some View {
        VStack(alignment: item.isArtist ? .center : .leading, spacing: 0) {
            ArtworkView(theme: item.artwork, cornerRadius: item.isArtist ? 999 : 6)
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 7)
            Text(item.title).font(.subheadline).lineLimit(1)
            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct LibraryCategoryView: View {
    @Environment(MockPlayer.self) private var player
    let category: LibraryCategory

    var body: some View {
        ScrollView {
            content.padding(.bottom, 24)
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("library.detail.\(category.rawValue)")
    }

    @ViewBuilder private var content: some View {
        switch category {
        case .playlists:
            // Apple's playlist list: 64pt artwork, 80pt pitch, chevron.
            LazyVStack(spacing: 0) {
                ForEach(Catalog.libraryPlaylists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        listRow(artwork: playlist.artwork, circle: false, size: 64, title: playlist.title,
                                subtitle: playlist.kind == .user || playlist.kind == .automatic ? nil : playlist.owner)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.playlist.\(playlist.id)")
                }
            }
        case .songs:
            let songs = Catalog.librarySongs
            VStack(spacing: 16) {
                HStack(spacing: 13) {
                    capsuleButton("재생", symbol: "play.fill") { play(songs, shuffled: false) }
                    capsuleButton("임의 재생", symbol: "shuffle") { play(songs, shuffled: true) }
                }
                .padding(.horizontal, BrowseMetrics.margin)
                LazyVStack(spacing: 0) {
                    ForEach(songs) { track in
                        SongRow(track: track, leading: .artwork, subtitle: track.artist) {
                            player.play(track, in: songs, source: "보관함 노래")
                        }
                    }
                }
            }
            .padding(.top, 8)
        case .albums:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13, alignment: .top), count: 2), spacing: 20) {
                ForEach(Catalog.libraryReleases) { release in
                    NavigationLink(value: Route.release(release.id)) { GridTile(item: .release(release)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, BrowseMetrics.margin)
            .padding(.top, 8)
        case .artists:
            LazyVStack(spacing: 0) {
                ForEach(Catalog.libraryArtists) { artist in
                    NavigationLink(value: Route.artist(artist.id)) {
                        listRow(artwork: artist.artwork, circle: true, size: 44, title: artist.name, subtitle: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func listRow(artwork: ArtworkTheme, circle: Bool, size: CGFloat, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            ArtworkView(theme: artwork, cornerRadius: circle ? size / 2 : 6).frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(2)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, BrowseMetrics.margin)
        .frame(height: size + 16)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 1 / 3)
                .padding(.leading, BrowseMetrics.margin + size + 14).padding(.trailing, BrowseMetrics.margin)
        }
    }

    private func capsuleButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func play(_ songs: [Track], shuffled: Bool) {
        let list = shuffled ? songs.shuffled() : songs
        guard let first = list.first else { return }
        player.play(first, in: list, source: "보관함 노래")
    }
}

// MARK: Search

enum SearchScope: Hashable { case catalog, library }

/// Result-type chips shared by Apple Music and YouTube Music search.
enum SearchFilter: CaseIterable, Hashable {
    case top, songs, albums, artists, playlists

    var title: String {
        switch self {
        case .top: "인기 검색 결과"
        case .songs: "노래"
        case .albums: "앨범"
        case .artists: "아티스트"
        case .playlists: "재생목록"
        }
    }
}

/// Session-only recent searches (both apps show them on the empty Search page).
@MainActor
@Observable
final class SearchHistory {
    private(set) var recent: [BrowseItem] = []

    func record(_ item: BrowseItem) {
        recent.removeAll { $0.id == item.id }
        recent.insert(item, at: 0)
        if recent.count > 10 { recent.removeLast() }
    }

    func clear() { recent.removeAll() }
}

struct SearchView: View {
    @Environment(MockPlayer.self) private var player
    @Environment(MockLibrary.self) private var library
    @Environment(SearchHistory.self) private var history
    let query: String
    let scope: SearchScope
    @State private var filter: SearchFilter = .top

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var results: [BrowseItem] {
        let q = normalizedQuery
        guard !q.isEmpty else { return [] }
        let inLibrary: (String) -> Bool = { scope == .catalog || library.contains($0) }
        let artists = Catalog.artists.filter { $0.name.localizedStandardContains(q) }.map(BrowseItem.artist)
        let releases = Catalog.releases.filter { inLibrary($0.id) && "\($0.title) \($0.artistName)".localizedStandardContains(q) }.map(BrowseItem.release)
        let playlists = Catalog.playlists.filter { inLibrary($0.id) && "\($0.title) \($0.owner)".localizedStandardContains(q) }.map(BrowseItem.playlist)
        let songs = Catalog.tracks.filter {
            (scope == .catalog || Catalog.librarySongs.contains($0)) && "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(q)
        }.map(BrowseItem.track)
        switch filter {
        case .top: return (scope == .catalog ? artists : []) + songs + releases + playlists
        case .songs: return songs
        case .albums: return releases
        case .artists: return scope == .catalog ? artists : []
        case .playlists: return playlists
        }
    }

    var body: some View {
        Group {
            if normalizedQuery.isEmpty {
                if history.recent.isEmpty {
                    ContentUnavailableView("음악 검색", systemImage: "magnifyingglass", description: Text("노래, 아티스트, 앨범, 재생목록을 검색하세요."))
                } else {
                    recents
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        chips
                        if results.isEmpty {
                            ContentUnavailableView.search(text: normalizedQuery).padding(.top, 60)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(results) { resultRow($0) }
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle("Search")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var recents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("최근 검색한 항목").font(.title3.weight(.semibold))
                    Spacer()
                    Button("지우기") { history.clear() }.foregroundStyle(.tint)
                }
                .padding(.horizontal, BrowseMetrics.margin)
                LazyVStack(spacing: 0) {
                    ForEach(history.recent) { resultRow($0) }
                }
            }
            .padding(.top, 8)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases, id: \.self) { f in
                    Button { filter = f } label: {
                        Text(f.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .foregroundStyle(filter == f ? Color.white : Color.primary)
                            .background(filter == f ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
        }
        .contentMargins(.horizontal, BrowseMetrics.margin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .padding(.top, 4)
    }

    /// Songs play (with a trailing menu); everything else pushes (with a chevron).
    @ViewBuilder private func resultRow(_ item: BrowseItem) -> some View {
        switch item {
        case .track(let track):
            SongRow(track: track, leading: .artwork, subtitle: "노래 · \(track.artist)") {
                history.record(item)
                player.startMix(from: track)
            }
        default:
            if let route = item.route {
                NavigationLink(value: route) { navigableRow(item) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { history.record(item) })
                    .accessibilityIdentifier("search.\(item.id)")
            }
        }
    }

    private func navigableRow(_ item: BrowseItem) -> some View {
        let kind: String = switch item {
        case .release(let r): "\(r.kind.label) · \(r.artistName)"
        case .playlist(let p): "재생목록 · \(p.owner)"
        case .artist: "아티스트"
        case .track(let t): "노래 · \(t.artist)"
        }
        return HStack(spacing: 12) {
            ArtworkView(theme: item.artwork, cornerRadius: item.isArtist ? BrowseMetrics.rowArtwork / 2 : 4)
                .frame(width: BrowseMetrics.rowArtwork, height: BrowseMetrics.rowArtwork)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).lineLimit(1)
                Text(kind).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, BrowseMetrics.margin)
        .frame(height: BrowseMetrics.artworkRowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 1 / 3)
                .padding(.leading, BrowseMetrics.margin + BrowseMetrics.rowArtwork + 12).padding(.trailing, BrowseMetrics.margin)
        }
    }
}
