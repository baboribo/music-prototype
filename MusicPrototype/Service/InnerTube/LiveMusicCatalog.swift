import Foundation
import OSLog

/// Browse data from the user's own YouTube Music session.
struct LiveMusicCatalog: MusicCatalog {
    private let client: any InnerTubeTransport
    private static let log = Logger(subsystem: "MusicPrototype", category: "InnerTube")

    /// Signed-in requests with the store's current credential (see `AppServices` for the sources).
    static func live(store: SessionCredentialStore) -> LiveMusicCatalog {
        LiveMusicCatalog(client: InnerTubeClient(store: store))
    }

    #if DEBUG
    /// Recorded responses instead of any request.
    static func replay(directory: String) throws -> LiveMusicCatalog {
        LiveMusicCatalog(client: try ReplayTransport(directory: directory))
    }
    #endif

    /// Every request fails with the source's configuration error.
    static func failing(_ error: any Error) -> any MusicCatalog { FailingCatalog(error: error) }

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

    func search(_ query: String, filter: SearchFilter, scope: SearchScope) async throws -> SearchResults {
        var body: [String: JSON] = ["query": .string(query)]
        let params = scope == .library ? SearchParsing.libraryParams[filter] : SearchParsing.params[filter]
        if let params { body["params"] = .string(params) }
        var results = SearchParsing.results(try await client.post("search", body: body))
        if scope == .library {
            results.items = results.items.map(LibraryParsing.inLibrary)
            if filter == .playlists {
                // No playlist chip is known for the library tab; narrow its own results by kind.
                results.items = results.items.filter { if case .playlist = $0 { true } else { false } }
            }
        }
        return results
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

    func libraryArtists(_ scope: LibraryArtistScope) async throws -> LibraryPage {
        switch scope {
        case .library: try await library(.artists)
        case .subscribed: LibraryParsing.page(try await client.post("browse", body: ["browseId": "FEmusic_library_corpus_artists"]))
        }
    }

    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage {
        LibraryParsing.page(try await client.post("browse", body: ["continuation": .string(continuation.token)]))
    }

    /// The service's own queue (`/next`), as its web player requests it.
    func queue(_ seed: QueueSeed) async throws -> QueuePage {
        var body: [String: JSON] = ["isAudioOnly": .bool(true), "enablePersistentPlaylistPanel": .bool(true)]
        switch seed {
        case .radio(let track):
            body["videoId"] = .string(track.id)
            body["playlistId"] = .string("RDAMVM" + track.id)
            body["params"] = "wAEB"
        case .list(let playlistID?, _, let start):
            body["videoId"] = .string(start.id)
            body["playlistId"] = .string(playlistID)
        case .artist(let playlistID?, _):
            body["playlistId"] = .string(playlistID)
        case .list(nil, let tracks, let start):
            // No service playlist to ask for: keep the list as shown.
            return QueuePage(items: tracks.map { QueueItem(track: $0) }, selectedIndex: tracks.firstIndex { $0.id == start.id })
        case .artist(nil, let songs):
            return QueuePage(items: songs.map { QueueItem(track: $0) }, selectedIndex: songs.isEmpty ? nil : 0)
        }
        guard let page = QueueParsing.page(try await client.post("next", body: body)) else { throw CatalogError.unexpectedResponse }
        return page
    }

    func queuePage(_ continuation: CatalogContinuation) async throws -> QueuePage {
        guard let page = QueueParsing.page(try await client.post("next", body: ["continuation": .string(continuation.token)])) else {
            throw CatalogError.unexpectedResponse
        }
        return page
    }

    /// Writes send only ids (no stored tokens). Verified on the account, 2026-09-29:
    /// `like/like` also adds the song to the library's songs; `like/removelike`
    /// (like the web client) leaves it there.
    func apply(_ edit: LibraryEdit) async throws -> Set<CatalogScope> {
        switch edit {
        case .like(let videoID, let liked):
            _ = try await client.post(liked ? "like/like" : "like/removelike",
                                      body: ["target": .object(["videoId": .string(videoID)])])
            return [.playlist("VLLM"), .library]
        case .save(let listID, let saved):
            // Verified 2026-09-29 for an album, another listener's playlist and a mix
            // (RDTMAK…): all save by playlistId; removing restores the library exactly.
            _ = try await client.post(saved ? "like/like" : "like/removelike",
                                      body: ["target": .object(["playlistId": .string(listID)])])
            return [.library]
        case .songInLibrary(let toggle, let on):
            // Verified 2026-09-29: adds to / removes from 보관함 노래 and library search;
            // the like is untouched. No row in any response shows the resulting state.
            try await feedback(on ? toggle.turnOn : toggle.turnOff)
            return [.library]
        case .pin(let toggle, let on):
            // Verified 2026-09-29: a pinned item leads 다시 듣기 (Home) and the library landing.
            try await feedback(on ? toggle.turnOn : toggle.turnOff)
            return [.home, .library]
        }
    }

    private func feedback(_ action: ServiceAction) async throws {
        let response = try await client.post("feedback", body: ["feedbackTokens": .array([.string(action.token)])])
        guard response.at("feedbackResponses.0.isProcessed") == .bool(true) else { throw CatalogError.unexpectedResponse }
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
    func search(_ query: String, filter: SearchFilter, scope: SearchScope) async throws -> SearchResults { throw error }
    func libraryArtists(_ scope: LibraryArtistScope) async throws -> LibraryPage { throw error }
    func release(_ id: Release.ID) async throws -> ReleaseDetail { throw error }
    func artist(_ id: Artist.ID) async throws -> ArtistDetail { throw error }
    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail { throw error }
    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page { throw error }
    func library() async throws -> LibraryFeed { throw error }
    func library(_ category: LibraryCategory) async throws -> LibraryPage { throw error }
    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage { throw error }
    func queue(_ seed: QueueSeed) async throws -> QueuePage { throw error }
    func queuePage(_ continuation: CatalogContinuation) async throws -> QueuePage { throw error }
    func apply(_ edit: LibraryEdit) async throws -> Set<CatalogScope> { throw error }
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

    /// The search page's 보관함 tab (`agIYBA==`) and the chips it offers there.
    /// Its playlist chip hasn't been observed, so 재생목록 uses the tab itself.
    static let libraryParams: [SearchFilter: String] = [
        .top: "agIYBA==",
        .songs: "EgWKAQIIAWoIEAUQCRADGAQ=",
        .albums: "EgWKAQIYAWoIEAUQCRADGAQ=",
        .artists: "EgWKAQIgAWoIEAUQCRADGAQ=",
        .playlists: "agIYBA==",
    ]

    static func results(_ root: JSON) -> SearchResults {
        // The response carries every scope's tab; results sit in the selected one.
        let tabs = root.at("contents.tabbedSearchResultsRenderer.tabs")?.array ?? []
        let tab = tabs.first { $0.at("tabRenderer.selected") == .bool(true) } ?? tabs.first
        let list = tab?.at("tabRenderer.content.sectionListRenderer")
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
    /// Titles follow the iOS app, which shows both modules below as 빠른 선곡
    /// (the web client calls the first one 다시 듣기).
    static let quickPicksTitle = "빠른 선곡"

    static func feed(_ shelves: [JSON]) -> HomeFeed {
        var sections: [HomeSection] = []
        var pins: [String: ServiceToggle] = [:]
        for (index, node) in shelves.enumerated() {
            guard let shelf = node["musicCarouselShelfRenderer"] else { continue }
            let title = shelf.at("header.musicCarouselShelfBasicHeaderRenderer.title")?.text ?? ""
            let contents = shelf["contents"]?.array ?? []
            let id = "\(index).\(title)"
            if isListenAgain(shelf) {
                // The 3×3 grid, first on Home (H1); pinned items already lead.
                let picks = contents.compactMap { node -> QuickPick? in
                    guard let card = node["musicTwoRowItemRenderer"], let item = ItemParsing.card(card) else { return nil }
                    pins[item.id] = ItemParsing.pinToggle(card)
                    return QuickPick(item, pinned: ItemParsing.isPinned(card))
                }
                guard !picks.isEmpty else { continue }
                sections.insert(HomeSection(id: id, title: quickPicksTitle, content: .quickPicks(picks)), at: 0)
            } else if contents.contains(where: { $0["musicResponsiveListItemRenderer"] != nil }) {
                let tracks = contents.compactMap { $0["musicResponsiveListItemRenderer"].flatMap(ItemParsing.track) }
                guard !tracks.isEmpty else { continue }
                let rows = shelf["numItemsPerColumn"]?.string.flatMap(Int.init) ?? shelf["numItemsPerColumn"]?.number.map(Int.init)
                // Song 빠른 선곡 stays where the server puts it, as a row-based shelf.
                sections.append(HomeSection(id: id, title: isSongQuickPicks(shelf) ? quickPicksTitle : title,
                                            content: .songs(tracks, rowsPerPage: rows ?? 4)))
            } else {
                let items = contents.compactMap { node -> BrowseItem? in
                    guard let card = node["musicTwoRowItemRenderer"], let item = ItemParsing.card(card) else { return nil }
                    if pins[item.id] == nil { pins[item.id] = ItemParsing.pinToggle(card) }
                    return item
                }
                guard !items.isEmpty else { continue }
                sections.append(HomeSection(id: id, title: title, content: .items(items)))
            }
        }
        return HomeFeed(sections: sections, pins: pins)
    }

    /// The listen-again module: its "more" button browses `FEmusic_listen_again`.
    static func isListenAgain(_ shelf: JSON) -> Bool {
        shelf.at("header.musicCarouselShelfBasicHeaderRenderer.moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint.browseId")?.string
            == "FEmusic_listen_again"
    }

    /// Song 빠른 선곡: a paged row shelf with a play-all button whose every item starts
    /// that song's radio (`RDAMVM<videoId>`). "Shorts에서 들은 음악" has the same shape
    /// but plays bare videos.
    static func isSongQuickPicks(_ shelf: JSON) -> Bool {
        guard shelf["numItemsPerColumn"] != nil,
              shelf.at("header.musicCarouselShelfBasicHeaderRenderer.moreContentButton.buttonRenderer.navigationEndpoint.watchEndpoint") != nil
        else { return false }
        let rows = (shelf["contents"]?.array ?? []).compactMap { $0["musicResponsiveListItemRenderer"] }
        return !rows.isEmpty && rows.allSatisfy { row in
            let watch = row.at("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint")
            guard let videoID = watch?["videoId"]?.string else { return false }
            return watch?["playlistId"]?.string == "RDAMVM" + videoID
        }
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
                  duration: track.duration, isExplicit: track.isExplicit, isPlayable: track.isPlayable,
                  libraryToggle: track.libraryToggle, pinToggle: track.pinToggle)
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
        return ReleaseDetail(release: release, tracks: tracks,
                             queuePlaylistID: root.all("playlistId").lazy.compactMap(\.string).first { $0.hasPrefix("OLAK5uy_") },
                             shelves: shelves, membership: ItemParsing.membership(header))
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
                              summary: header["secondSubtitle"]?.text, next: page.next,
                              membership: editable != nil ? nil : ItemParsing.membership(header))
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
        }.map(inLibrary)
        return LibraryPage(items: items, next: token.map(CatalogContinuation.init))
    }

    /// Songs listed in the library are in it, whatever their row menus say.
    static func inLibrary(_ item: BrowseItem) -> BrowseItem {
        guard case .track(var track) = item, track.libraryToggle != nil else { return item }
        track.libraryToggle?.isOn = true
        return .track(track)
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

enum QueueParsing {
    /// The first page (watch-next panel) or a continuation.
    static func page(_ root: JSON) -> QueuePage? {
        let panel = root.at("contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs.0.tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer")
            ?? root.at("continuationContents.playlistPanelContinuation")
        guard let panel else { return nil }
        var selected: Int?
        var items: [QueueItem] = []
        for node in panel["contents"]?.array ?? [] {
            if let renderer = node["playlistPanelVideoRenderer"], let variant = variant(renderer) {
                if renderer["selected"] == .bool(true) { selected = items.count }
                items.append(QueueItem(id: entryID(renderer), primary: variant, counterpart: nil, segmentMap: nil,
                                       unplayableReason: renderer["unplayableText"]?.text))
            } else if let wrapper = node["playlistPanelVideoWrapperRenderer"],
                      let renderer = wrapper.at("primaryRenderer.playlistPanelVideoRenderer"), let primary = variant(renderer) {
                if renderer["selected"] == .bool(true) { selected = items.count }
                let pair = wrapper.at("counterpart.0")
                items.append(QueueItem(
                    id: entryID(renderer), primary: primary,
                    counterpart: pair?.at("counterpartRenderer.playlistPanelVideoRenderer").flatMap(variant),
                    segmentMap: pair?["segmentMap"].flatMap(segmentMap),
                    unplayableReason: renderer["unplayableText"]?.text))
            }
        }
        let token = panel.at("continuations.0.nextRadioContinuationData.continuation")?.string
            ?? panel.at("continuations.0.nextContinuationData.continuation")?.string
        return QueuePage(items: items, selectedIndex: selected, next: token.map(CatalogContinuation.init),
                         isInfinite: panel["isInfinite"] == .bool(true))
    }

    private static func entryID(_ renderer: JSON) -> String {
        renderer["playlistSetVideoId"]?.string ?? "\(renderer["videoId"]?.string ?? "?").\(UUID().uuidString)"
    }

    /// A queue row: "아티스트 • 앨범 • 연도" byline with browse runs; unplayable rows carry only the id.
    private static func variant(_ renderer: JSON) -> QueueVariant? {
        guard let videoID = renderer["videoId"]?.string else { return nil }
        let runs = renderer.at("longBylineText.runs")?.array ?? []
        func pageType(_ run: JSON) -> String? {
            run.at("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType")?.string
        }
        let artists = runs.filter { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }
        let album = runs.first { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }
        let byline = (renderer["shortBylineText"]?.text ?? renderer["longBylineText"]?.text ?? "")
        let kind: MediaKind = switch renderer.at("navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType")?.string {
        case "MUSIC_VIDEO_TYPE_ATV": .song
        case "MUSIC_VIDEO_TYPE_OMV": .officialVideo
        case "MUSIC_VIDEO_TYPE_UGC": .userVideo
        default: .other
        }
        let track = Track(
            id: videoID, title: renderer["title"]?.text ?? "",
            artist: artists.isEmpty ? byline : artists.compactMap { $0["text"]?.string }.joined(separator: ", "),
            artistID: artists.first?.at("navigationEndpoint.browseEndpoint.browseId")?.string,
            album: album?["text"]?.string ?? "",
            releaseID: album?.at("navigationEndpoint.browseEndpoint.browseId")?.string,
            artwork: ItemParsing.artwork(renderer.at("thumbnail.thumbnails")),
            duration: ItemParsing.seconds(renderer["lengthText"]?.text).map(Double.init),
            isExplicit: renderer.all("iconType").contains { $0.string == "MUSIC_EXPLICIT_BADGE" },
            isPlayable: renderer["unplayableText"] == nil)
        // The row menu's like toggle shows the action it would take: UNFAVORITE = liked now.
        let likeIcon = (renderer.at("menu.menuRenderer.items")?.array ?? [])
            .compactMap { $0.at("toggleMenuServiceItemRenderer.defaultIcon.iconType")?.string }
            .first { $0 == "FAVORITE" || $0 == "UNFAVORITE" }
        return QueueVariant(track: track, kind: kind, isLiked: likeIcon.map { $0 == "UNFAVORITE" })
    }

    private static func segmentMap(_ node: JSON) -> SegmentMap? {
        func ms(_ value: JSON?) -> Double? {
            (value?.string.flatMap(Double.init) ?? value?.number).map { $0 / 1000 }
        }
        let segments = (node["segment"]?.array ?? []).compactMap { segment -> SegmentMap.Segment? in
            guard let primary = ms(segment["primaryVideoStartTimeMilliseconds"]),
                  let counterpart = ms(segment["counterpartVideoStartTimeMilliseconds"]),
                  let duration = ms(segment["durationMilliseconds"]) else { return nil }
            return SegmentMap.Segment(primaryStart: primary, counterpartStart: counterpart, duration: duration)
        }
        return segments.isEmpty ? nil : SegmentMap(segments: segments)
    }
}
