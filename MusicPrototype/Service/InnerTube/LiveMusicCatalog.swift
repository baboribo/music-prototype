import Foundation
import OSLog

/// Browse data from the user's own YouTube Music session.
struct LiveMusicCatalog: MusicCatalog {
    private let client: any InnerTubeTransport
    private static let log = Logger(subsystem: "MusicPrototype", category: "InnerTube")

    /// `YTM_SESSION_FILE`: the user's session file (outside the repository) for live data.
    /// `YTM_REPLAY_DIR` (debug builds): recorded responses instead of any request.
    /// Neither: the app stays on fixtures.
    static func fromEnvironment() -> (any MusicCatalog)? {
        let environment = ProcessInfo.processInfo.environment
        do {
            #if DEBUG
            if let directory = environment["YTM_REPLAY_DIR"], !directory.isEmpty {
                return LiveMusicCatalog(client: try ReplayTransport(directory: directory))
            }
            #endif
            guard let path = environment["YTM_SESSION_FILE"], !path.isEmpty else { return nil }
            _ = try ExternalFile.validate(path)
            return LiveMusicCatalog(client: InnerTubeClient(store: SessionCredentialStore(path: path)))
        } catch {
            log.error("catalog source rejected: \(error.localizedDescription, privacy: .public)")
            return FailingCatalog(error: error)
        }
    }

    func home() async throws -> HomeFeed {
        let started = ContinuousClock.now
        var shelves: [JSON] = []
        var page = try await client.post("browse", body: ["browseId": "FEmusic_home"])
        var list = page.at("contents.singleColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer")
        guard list != nil else { throw CatalogError.unexpectedResponse }
        var requests = 1
        // Home arrives in pages; 빠른 선곡 is usually on the last one.
        while let current = list {
            shelves += current["contents"]?.array ?? []
            guard let token = current.at("continuations.0.nextContinuationData.continuation")?.string, requests < 8 else { break }
            try Task.checkCancellation()
            page = try await client.post("browse", body: ["continuation": .string(token)])
            list = page.at("continuationContents.sectionListContinuation")
            requests += 1
        }
        let feed = HomeParsing.feed(shelves)
        Self.log.info("home: \(requests) requests, \(shelves.count) shelves → \(feed.sections.count) sections in \(started.duration(to: .now), privacy: .public)")
        return feed
    }

    func search(_ query: String, filter: SearchFilter) async throws -> SearchResults {
        var body: [String: JSON] = ["query": .string(query)]
        if let params = SearchParsing.params[filter] { body["params"] = .string(params) }
        return SearchParsing.results(try await client.post("search", body: body))
    }

    func release(_ id: Release.ID) async throws -> ReleaseDetail {
        guard let detail = ReleaseParsing.detail(try await client.post("browse", body: ["browseId": .string(id)]), id: id) else {
            throw CatalogError.unexpectedResponse
        }
        return detail
    }

    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail {
        guard let detail = PlaylistParsing.detail(try await client.post("browse", body: ["browseId": .string(id)]), id: id) else {
            throw CatalogError.unexpectedResponse
        }
        return detail
    }

    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page {
        PlaylistParsing.page(try await client.post("browse", body: ["continuation": .string(continuation.token)]))
    }

    func library() async throws -> LibraryFeed {
        LibraryParsing.feed(try await client.post("browse", body: ["browseId": "FEmusic_library_landing"]))
    }

    func library(_ category: LibraryCategory) async throws -> LibraryPage {
        let id = switch category {
        case .playlists: "FEmusic_liked_playlists"
        case .songs: "FEmusic_liked_videos"
        case .albums: "FEmusic_liked_albums"
        case .artists: "FEmusic_library_corpus_track_artists"
        }
        return LibraryParsing.page(try await client.post("browse", body: ["browseId": .string(id)]))
    }

    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage {
        LibraryParsing.page(try await client.post("browse", body: ["continuation": .string(continuation.token)]))
    }

    func artist(_ id: Artist.ID) async throws -> ArtistDetail {
        guard let detail = ArtistParsing.detail(try await client.post("browse", body: ["browseId": .string(id)]), id: id) else {
            throw CatalogError.unexpectedResponse
        }
        return detail
    }
}

/// Keeps a rejected session visible as an error instead of silently falling back to fixtures.
private struct FailingCatalog: MusicCatalog {
    let error: any Error
    func home() async throws -> HomeFeed { throw error }
    func search(_ query: String, filter: SearchFilter) async throws -> SearchResults { throw error }
    func release(_ id: Release.ID) async throws -> ReleaseDetail { throw error }
    func artist(_ id: Artist.ID) async throws -> ArtistDetail { throw error }
    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail { throw error }
    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page { throw error }
    func library() async throws -> LibraryFeed { throw error }
    func library(_ category: LibraryCategory) async throws -> LibraryPage { throw error }
    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage { throw error }
}

enum SearchParsing {
    /// The service's own filter chips (the same values its search page sends;
    /// ytmusicapi uses the same constants). "재생목록" maps to 추천 재생목록;
    /// 커뮤니티 재생목록 has no chip in this UI yet.
    static let params: [SearchFilter: String] = [
        .songs: "EgWKAQIIAWoSEAUQCRADEA4QChAEEBAQFRAR",
        .albums: "EgWKAQIYAWoSEAUQCRADEA4QChAEEBAQFRAR",
        .artists: "EgWKAQIgAWoSEAUQCRADEA4QChAEEBAQFRAR",
        .playlists: "EgeKAQQoADgBahIQBRAJEAMQDhAKEAQQEBAVEBE=",
    ]

    static func results(_ root: JSON) -> SearchResults {
        let list = root.at("contents.tabbedSearchResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer")
        var top: BrowseItem?
        var items: [BrowseItem] = []
        for node in list?["contents"]?.array ?? [] {
            if let card = node["musicCardShelfRenderer"] {
                top = ItemParsing.topResult(card)
            }
            // Results arrive as one shelf (filtered) or one itemSection per result (all).
            let rows = (node.at("musicShelfRenderer.contents")?.array ?? []) + (node.at("itemSectionRenderer.contents")?.array ?? [])
            items += rows.compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.row) }
        }
        var seen = Set(top.map { [$0.id] } ?? [])
        return SearchResults(top: top, items: items.filter { seen.insert($0.id).inserted })
    }
}

enum HomeParsing {
    /// The localized title is the only marker the web response gives 빠른 선곡.
    private static let quickPicksTitles: Set<String> = ["빠른 선곡", "Quick picks"]

    static func feed(_ shelves: [JSON]) -> HomeFeed {
        var sections: [HomeSection] = []
        for (index, node) in shelves.enumerated() {
            guard let shelf = node["musicCarouselShelfRenderer"] else { continue }
            let title = shelf.at("header.musicCarouselShelfBasicHeaderRenderer.title")?.text ?? ""
            let contents = shelf["contents"]?.array ?? []
            let id = "\(index).\(title)"
            if contents.contains(where: { $0["musicResponsiveListItemRenderer"] != nil }) {
                let tracks = contents.compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.track) }
                guard !tracks.isEmpty else { continue }
                if quickPicksTitles.contains(title) {
                    sections.insert(HomeSection(id: id, title: title, content: .quickPicks(tracks.map(QuickPick.track))), at: 0)
                } else {
                    let rows = shelf["numItemsPerColumn"]?.string.flatMap(Int.init) ?? shelf["numItemsPerColumn"]?.number.map(Int.init)
                    sections.append(HomeSection(id: id, title: title, content: .songs(tracks, rowsPerPage: rows ?? 4)))
                }
            } else {
                let items = contents.compactMap { $0["musicTwoRowItemRenderer"].flatMap(ItemParsing.card) }
                guard !items.isEmpty else { continue }
                sections.append(HomeSection(id: id, title: title, content: .items(items)))
            }
        }
        return HomeFeed(sections: sections)
    }
}

enum ReleaseParsing {
    static func detail(_ root: JSON, id: String) -> ReleaseDetail? {
        let columns = root.at("contents.twoColumnBrowseResultsRenderer")
        guard let header = columns?.at("tabs.0.tabRenderer.content.sectionListRenderer.contents.0.musicResponsiveHeaderRenderer")
        else { return nil }
        // "앨범 • 2017년"; the artist is the strapline above the title.
        let subtitle = (header["subtitle"]?.text ?? "").components(separatedBy: " • ")
        let artistRuns = (header.at("straplineTextOne.runs")?.array ?? []).filter { $0.at("navigationEndpoint.browseEndpoint.browseId") != nil }
        let artistName = header["straplineTextOne"]?.text ?? ""
        let artistID = artistRuns.first?.at("navigationEndpoint.browseEndpoint.browseId")?.string
        let artwork = ItemParsing.artwork(header.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails"))

        let secondary = columns?.at("secondaryContents.sectionListRenderer.contents")?.array ?? []
        let rows = secondary.compactMap { $0.at("musicShelfRenderer.contents")?.array }.first ?? []
        let tracks = rows.compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.track) }.map { track in
            // Rows omit the artist when it's the release's own, and never repeat the album.
            Track(id: track.id, title: track.title,
                  artist: track.artist.isEmpty ? artistName : track.artist,
                  artistID: track.artistID ?? artistID,
                  album: header["title"]?.text ?? "", releaseID: id,
                  artwork: track.artwork == .theme(.midnight) ? artwork : track.artwork,
                  duration: track.duration, isExplicit: track.isExplicit, isPlayable: track.isPlayable)
        }
        let release = Release(
            id: id, title: header["title"]?.text ?? "",
            kind: ItemParsing.releaseKind(subtitle.first), artistName: artistName, artistID: artistID,
            year: subtitle.lazy.compactMap(ItemParsing.year).last, artwork: artwork,
            trackIDs: tracks.map(\.id))
        let shelves: [DetailShelf] = secondary.enumerated().compactMap { index, node in
            guard let carousel = node["musicCarouselShelfRenderer"] else { return nil }
            let items = (carousel["contents"]?.array ?? []).compactMap { $0["musicTwoRowItemRenderer"].flatMap(ItemParsing.card) }
            guard !items.isEmpty else { return nil }
            return DetailShelf(id: "\(index)", title: carousel.at("header.musicCarouselShelfBasicHeaderRenderer.title")?.text ?? "",
                               items: items)
        }
        return ReleaseDetail(release: release, tracks: tracks, shelves: shelves)
    }
}

enum ArtistParsing {
    static func detail(_ root: JSON, id: String) -> ArtistDetail? {
        guard let header = root.at("header.musicImmersiveHeaderRenderer") ?? root.at("header.musicVisualHeaderRenderer")
        else { return nil }
        let name = header["title"]?.text ?? ""
        let artist = Artist(
            id: id, name: name,
            artwork: ItemParsing.artwork(header.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails"), resize: false),
            description: header["description"]?.text, sections: [])
        let contents = root.at("contents.singleColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")?.array ?? []
        let sections: [ArtistDetail.Section] = contents.enumerated().compactMap { index, node in
            if let shelf = node["musicShelfRenderer"] {
                let tracks = (shelf["contents"]?.array ?? []).compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.track) }
                guard !tracks.isEmpty else { return nil }
                return .init(id: "\(index)", title: shelf["title"]?.text ?? "", content: .songs(tracks))
            }
            guard let carousel = node["musicCarouselShelfRenderer"] else { return nil }
            let items = (carousel["contents"]?.array ?? []).compactMap { $0["musicTwoRowItemRenderer"].flatMap(ItemParsing.card) }
                .map { attributed($0, to: artist) }
            guard !items.isEmpty else { return nil }
            return .init(id: "\(index)", title: carousel.at("header.musicCarouselShelfBasicHeaderRenderer.title")?.text ?? "",
                         content: .items(items))
        }
        return ArtistDetail(
            artist: artist, sections: sections,
            radioPlaylistID: header.at("startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId")?.string,
            shufflePlaylistID: header.at("playButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId")?.string)
    }

    /// The 앨범 shelf's cards carry only the year; the page's artist is implied.
    private static func attributed(_ item: BrowseItem, to artist: Artist) -> BrowseItem {
        guard case .release(let r) = item, r.artistName.isEmpty else { return item }
        return .release(Release(id: r.id, title: r.title, kind: r.kind, artistName: artist.name, artistID: artist.id,
                                year: r.year, artwork: r.artwork, trackIDs: r.trackIDs))
    }
}

enum PlaylistParsing {
    static func detail(_ root: JSON, id: String) -> PlaylistDetail? {
        let columns = root.at("contents.twoColumnBrowseResultsRenderer")
        let top = columns?.at("tabs.0.tabRenderer.content.sectionListRenderer.contents.0")
        // The listener's own playlists wrap the header in an editable one.
        let editable = top?["musicEditablePlaylistDetailHeaderRenderer"]
        guard let header = top?["musicResponsiveHeaderRenderer"] ?? editable?.at("header.musicResponsiveHeaderRenderer")
        else { return nil }
        // "재생목록 • 2026", "자동 재생목록 • 2026", "믹스"; the owner is the facepile's text, when there is one.
        let label = (header["subtitle"]?.text ?? "").components(separatedBy: " • ").first
        let owner = header.at("facepile.avatarStackViewModel.text.content")?.string
        let kind: PlaylistKind = switch label {
        case "자동 재생목록", "Auto playlist": .automatic
        case "믹스", "Mix": .mix
        default: ItemParsing.playlistKind(id: id, owner: owner)
        }
        let shelf = columns?.at("secondaryContents.sectionListRenderer.contents.0.musicPlaylistShelfRenderer")
        let page = page(rows: shelf?["contents"]?.array ?? [])
        let playlist = Playlist(
            id: id, title: header["title"]?.text ?? "", kind: kind, owner: owner ?? "",
            description: header.at("description.musicDescriptionShelfRenderer.description")?.text,
            artwork: ItemParsing.artwork(header.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails")),
            trackIDs: page.tracks.map(\.id), isOwned: editable != nil ? true : ItemParsing.ownership(header["buttons"]))
        return PlaylistDetail(playlist: playlist, tracks: page.tracks,
                              summary: header["secondSubtitle"]?.text, next: page.next)
    }

    /// A continuation response: the next rows and, if more remain, the next token.
    static func page(_ root: JSON) -> PlaylistDetail.Page {
        let items = (root["onResponseReceivedActions"]?.array ?? [])
            .flatMap { $0.at("appendContinuationItemsAction.continuationItems")?.array ?? [] }
        return page(rows: items)
    }

    private static func page(rows: [JSON]) -> PlaylistDetail.Page {
        let tracks = rows.compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.track) }
        let token = rows.lazy.compactMap { $0.at("continuationItemRenderer.continuationEndpoint.continuationCommand.token")?.string }.first
        return PlaylistDetail.Page(tracks: tracks, next: token.map(PlaylistDetail.Continuation.init))
    }
}

enum LibraryParsing {
    /// The library landing grid: pinned items carry a "고정됨" badge and come first.
    static func feed(_ root: JSON) -> LibraryFeed {
        let (nodes, _) = container(root)
        var pinned: [BrowseItem] = []
        var recent: [BrowseItem] = []
        for node in nodes {
            guard let card = node["musicTwoRowItemRenderer"], let item = ItemParsing.card(card) else { continue }
            if ItemParsing.isPinned(card) { pinned.append(item) } else { recent.append(item) }
        }
        return LibraryFeed(pinned: pinned, recent: recent)
    }

    /// A category page or its continuation: grid cards (playlists, albums) or shelf rows (songs, artists).
    /// Action entries ("새 재생목록", "모두 셔플") aren't items and are skipped.
    static func page(_ root: JSON) -> LibraryPage {
        let (nodes, token) = container(root)
        let items = nodes.compactMap { node -> BrowseItem? in
            if let card = node["musicTwoRowItemRenderer"] { return ItemParsing.card(card) }
            if let row = node["musicResponsiveListItemRenderer"] { return ItemParsing.row(row) }
            return nil
        }
        return LibraryPage(items: items, next: token.map(CatalogContinuation.init))
    }

    /// First pages nest a grid or shelf in the section list; continuations return it directly.
    private static func container(_ root: JSON) -> ([JSON], String?) {
        let sections = root.at("contents.singleColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")?.array ?? []
        let candidates = sections.flatMap { section -> [JSON] in
            [section["gridRenderer"], section["musicShelfRenderer"],
             section.at("itemSectionRenderer.contents.0.gridRenderer"),
             section.at("itemSectionRenderer.contents.0.musicShelfRenderer")].compactMap(\.self)
        } + [root.at("continuationContents.gridContinuation"), root.at("continuationContents.musicShelfContinuation")].compactMap(\.self)
        guard let list = candidates.first else { return ([], nil) }
        let nodes = list["items"]?.array ?? list["contents"]?.array ?? []
        let token = list.at("continuations.0.nextContinuationData.continuation")?.string
        return (nodes, token)
    }
}
