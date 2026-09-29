import SwiftUI

// MARK: Library

/// Apple Music Library root (am-library): pinned 3-column grid, category rows,
/// then a 2-column grid. Entries are YouTube Music's library (pins, recent activity).
struct LibraryView: View {
    @Environment(\.musicCatalog) private var catalog
    @Environment(CatalogChanges.self) private var changes
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var loadedRevision = 0
    private let pinnedColumns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    private let recentColumns = Array(repeating: GridItem(.flexible(), spacing: 13, alignment: .top), count: 2)

    private enum Phase {
        case loading
        case loaded(LibraryFeed)
        case failed(LoadFailure)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let failure):
                LoadFailureView(title: "보관함을 불러오지 못했습니다", failure: failure) { phase = .loading; attempt += 1 }
            case .loaded(let feed):
                content(feed)
            }
        }
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inlineLarge)
        .task(id: attempt) { await load() }
        .task(id: changes.revision(.library)) { await reloadIfChanged() }
    }

    /// First appearance and retry only; switching tabs keeps what's loaded.
    private func load() async {
        guard case .loading = phase else { return }
        let revision = changes.revision(.library)
        do {
            phase = .loaded(try await catalog.library())
            loadedRevision = revision
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(LoadFailure(error))
        }
    }

    /// After a write changed the library: replace in place, keep the shown feed on failure.
    private func reloadIfChanged() async {
        let revision = changes.revision(.library)
        guard case .loaded = phase, revision != loadedRevision,
              let feed = try? await catalog.library(), !Task.isCancelled else { return }
        phase = .loaded(feed)
        loadedRevision = revision
    }

    private func content(_ feed: LibraryFeed) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: pinnedColumns, spacing: 16) {
                    ForEach(feed.pinned) { item in
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
                    ForEach(feed.recent) { item in
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
    }

    private func pinnedTile(_ item: BrowseItem) -> some View {
        VStack(spacing: 7) {
            ArtworkView(artwork: item.artwork, cornerRadius: item.isArtist ? 999 : 8)
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
            ArtworkView(artwork: item.artwork, cornerRadius: item.isArtist ? 999 : 6)
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 7)
            Text(item.title).font(.subheadline).lineLimit(1)
            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct LibraryCategoryView: View {
    @Environment(\.musicCatalog) private var catalog
    let category: LibraryCategory
    /// Artists in the library and subscribed artists are separate lists on the service.
    @State private var artistScope: LibraryArtistScope = .library

    var body: some View {
        Group {
            if category == .artists {
                CatalogPage(scope: .library) { [catalog, artistScope] in try await catalog.libraryArtists(artistScope) } content: { page in
                    LibraryCategoryList(category: category, first: page)
                }
                .id(artistScope)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("아티스트 범위", selection: $artistScope) {
                        ForEach(LibraryArtistScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, BrowseMetrics.margin)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("library.artists.scope")
                }
            } else {
                CatalogPage(scope: .library) { [catalog, category] in try await catalog.library(category) } content: { page in
                    LibraryCategoryList(category: category, first: page)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("library.detail.\(category.rawValue)")
    }
}

/// One library category; further pages load as the list reaches its end.
private struct LibraryCategoryList: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.musicCatalog) private var catalog
    let category: LibraryCategory
    @State private var items: [BrowseItem]
    @State private var next: CatalogContinuation?
    @State private var loadingMore = false
    @State private var loadFailed = false

    init(category: LibraryCategory, first: LibraryPage) {
        self.category = category
        _items = State(initialValue: first.items)
        _next = State(initialValue: first.next)
    }

    var body: some View {
        ScrollView {
            content.padding(.bottom, 24)
            if next != nil {
                Group {
                    if loadFailed {
                        Button("나머지 다시 불러오기") { Task { await loadMore() } }.buttonStyle(.bordered)
                    } else {
                        ProgressView()
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Called from inside the lazy containers, so it fires only when the last entry scrolls in.
    private func loadMoreIfLast(_ id: String) {
        if id == items.last?.id { Task { await loadMore() } }
    }

    private func loadMore() async {
        guard let token = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await catalog.libraryPage(token)
            // Library continuations repeat some entries from the previous page.
            let seen = Set(items.map(\.id))
            items += page.items.filter { !seen.contains($0.id) }
            next = page.next
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private var playlists: [Playlist] { items.compactMap { if case .playlist(let v) = $0 { v } else { nil } } }
    private var songs: [Track] { items.compactMap { if case .track(let v) = $0 { v } else { nil } } }
    private var releases: [Release] { items.compactMap { if case .release(let v) = $0 { v } else { nil } } }
    private var artists: [Artist] { items.compactMap { if case .artist(let v) = $0 { v } else { nil } } }

    @ViewBuilder private var content: some View {
        switch category {
        case .playlists:
            // Apple's playlist list: 64pt artwork, 80pt pitch, chevron.
            LazyVStack(spacing: 0) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        listRow(artwork: playlist.artwork, circle: false, size: 64, title: playlist.title,
                                subtitle: playlist.isListenersOwn || playlist.owner.isEmpty ? nil : playlist.owner)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.playlist.\(playlist.id)")
                    .onAppear { loadMoreIfLast("playlist.\(playlist.id)") }
                }
            }
        case .songs:
            let songs = songs
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
                        .onAppear { loadMoreIfLast("track.\(track.id)") }
                    }
                }
            }
            .padding(.top, 8)
        case .albums:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13, alignment: .top), count: 2), spacing: 20) {
                ForEach(releases) { release in
                    NavigationLink(value: Route.release(release.id)) { GridTile(item: .release(release)) }
                        .buttonStyle(.plain)
                        .onAppear { loadMoreIfLast("release.\(release.id)") }
                }
            }
            .padding(.horizontal, BrowseMetrics.margin)
            .padding(.top, 8)
        case .artists:
            LazyVStack(spacing: 0) {
                ForEach(artists) { artist in
                    NavigationLink(value: Route.artist(artist.id)) {
                        listRow(artwork: artist.artwork, circle: true, size: 44, title: artist.name, subtitle: artist.byline)
                    }
                    .buttonStyle(.plain)
                    .onAppear { loadMoreIfLast("artist.\(artist.id)") }
                }
            }
        }
    }

    private func listRow(artwork: Artwork, circle: Bool, size: CGFloat, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: artwork, cornerRadius: circle ? size / 2 : 6).frame(width: size, height: size)
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
        let list = (shuffled ? songs.shuffled() : songs).filter(\.isPlayable)
        guard let first = list.first else { return }
        player.play(first, in: list, source: "보관함 노래")
    }
}

// MARK: Search



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
    @Environment(SearchHistory.self) private var history
    @Environment(\.musicCatalog) private var catalog
    @Environment(CatalogChanges.self) private var changes
    let query: String
    let scope: SearchScope
    @State private var filter: SearchFilter = .top
    @State private var remote: RemotePhase = .idle
    @State private var attempt = 0
    /// What `remote` holds, so returning from a pushed page doesn't search again.
    @State private var loadedKey: RequestKey?

    /// Catalog results for one query/filter pair.
    private enum RemotePhase {
        case idle
        case loading
        case loaded(SearchResults)
        case failed(LoadFailure)
    }

    private struct RequestKey: Equatable {
        let query: String
        let filter: SearchFilter
        let scope: SearchScope
        let attempt: Int
        /// Library results are stale after a write to the library.
        let libraryRevision: Int
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                        resultsContent
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle("Search")
        .toolbarTitleDisplayMode(.inlineLarge)
        .task(id: requestKey) { await search() }
    }

    @ViewBuilder private var resultsContent: some View {
        let items: [BrowseItem]? = if case .loaded(let results) = remote {
            (results.top.map { [$0] } ?? []) + results.items
        } else {
            nil
        }
        if let items {
            if items.isEmpty {
                ContentUnavailableView.search(text: normalizedQuery).padding(.top, 60)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { resultRow($0) }
                }
            }
        } else if case .failed(let failure) = remote {
            LoadFailureView(title: "검색하지 못했습니다", failure: failure) { attempt += 1 }
                .padding(.top, 40)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    private var requestKey: RequestKey {
        RequestKey(query: normalizedQuery, filter: filter, scope: scope, attempt: attempt,
                   libraryRevision: scope == .library ? changes.revision(.library) : 0)
    }

    /// Debounced: typing cancels the previous task before its request goes out.
    private func search() async {
        let q = normalizedQuery
        let key = requestKey
        guard !q.isEmpty else { remote = .idle; loadedKey = nil; return }
        guard key != loadedKey else { return }
        remote = .loading
        do {
            try await Task.sleep(for: .milliseconds(300))
            let results = try await catalog.search(q, filter: filter, scope: scope)
            remote = .loaded(results)
            loadedKey = key
        } catch {
            guard !Task.isCancelled else { return }
            remote = .failed(LoadFailure(error))
        }
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
        case .release(let r): [r.kind?.label, r.artistName].compactMap(\.self).joined(separator: " · ")
        case .playlist(let p): "재생목록 · \(p.owner)"
        case .artist: "아티스트"
        case .track(let t): "노래 · \(t.artist)"
        }
        return HStack(spacing: 12) {
            ArtworkView(artwork: item.artwork, cornerRadius: item.isArtist ? BrowseMetrics.rowArtwork / 2 : 4)
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
