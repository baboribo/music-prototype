import Foundation

/// Maps InnerTube list/card renderers to domain values. Renderer kinds the
/// domain can't represent yet (podcasts, episodes, profiles) return nil.
enum ItemParsing {
    private static let separator = " • "

    // MARK: Cards (musicTwoRowItemRenderer)

    static func card(_ node: JSON) -> BrowseItem? {
        let title = node["title"]?.text ?? ""
        let runs = node.at("subtitle.runs")?.array ?? []
        // Split the joined line, not the runs: bylines also carry ", " runs.
        let texts = (node["subtitle"]?.text ?? "").components(separatedBy: separator).filter { !$0.isEmpty }
        let byline = (texts.first.map(isTypeLabel) ?? false) ? Array(texts.dropFirst()) : texts
        let artwork = artwork(node.at("thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails"))
        let artists = artistRuns(runs)

        if let id = node.at("navigationEndpoint.browseEndpoint.browseId")?.string,
           let pageType = pageType(node.at("navigationEndpoint.browseEndpoint")) {
            let item = page(id: id, pageType: pageType, title: title, subtitle: node["subtitle"] ?? .null, artwork: artwork)
            // Library cards say who owns a playlist through their menu: edit (own) or save (others').
            if case .playlist(var playlist)? = item, let owned = ownership(node["menu"]) {
                playlist.isOwned = owned
                return .playlist(playlist)
            }
            return item
        }
        guard let videoID = node.at("navigationEndpoint.watchEndpoint.videoId")?.string else { return nil }
        return .track(Track(
            id: videoID, title: title,
            artist: artists.isEmpty ? byline.first ?? "" : artists.map(\.name).joined(separator: ", "),
            artistID: artists.first?.id, album: "", releaseID: nil,
            artwork: artwork, duration: nil, isExplicit: isExplicit(node)))
    }

    // MARK: Rows (musicResponsiveListItemRenderer)

    /// A row that is either a playable item or a page (search results, suggestions).
    static func row(_ node: JSON) -> BrowseItem? {
        guard let endpoint = node.at("navigationEndpoint.browseEndpoint"),
              let id = endpoint["browseId"]?.string, let pageType = pageType(endpoint) else {
            return track(node).map(BrowseItem.track)
        }
        let columns = (node["flexColumns"]?.array ?? []).map { $0.at("musicResponsiveListItemFlexColumnRenderer.text") ?? .null }
        let title = columns.first?.text ?? ""
        let second = columns.count > 1 ? columns[1] : .null
        return page(id: id, pageType: pageType, title: title, subtitle: second,
                    artwork: artwork(node.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails")))
    }

    /// Search's highlighted result card (musicCardShelfRenderer).
    static func topResult(_ card: JSON) -> BrowseItem? {
        let artwork = artwork(card.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails"))
        let title = card["title"] ?? .null
        if let run = title.at("runs.0"), let endpoint = run.at("navigationEndpoint.browseEndpoint"),
           let id = endpoint["browseId"]?.string, let pageType = pageType(endpoint) {
            return page(id: id, pageType: pageType, title: title.text ?? "", subtitle: card["subtitle"] ?? .null, artwork: artwork)
        }
        guard let videoID = card.first("videoId")?.string else { return nil }
        let runs = card.at("subtitle.runs")?.array ?? []
        let artists = artistRuns(runs)
        let texts = (card["subtitle"]?.text ?? "").components(separatedBy: separator)
        let byline = (texts.first.map(isTypeLabel) ?? false) ? Array(texts.dropFirst()) : texts
        return .track(Track(id: videoID, title: title.text ?? "",
                            artist: artists.isEmpty ? byline.first ?? "" : artists.map(\.name).joined(separator: ", "),
                            artistID: artists.first?.id, album: "", releaseID: nil,
                            artwork: artwork, duration: nil, isExplicit: isExplicit(card)))
    }

    /// Album, playlist or artist from a title and a "종류 • 아티스트 • 연도" byline.
    private static func page(id: String, pageType: String, title: String, subtitle: JSON, artwork: Artwork) -> BrowseItem? {
        let runs = subtitle["runs"]?.array ?? []
        let texts = (subtitle.text ?? "").components(separatedBy: separator).filter { !$0.isEmpty }
        let byline = (texts.first.map(isTypeLabel) ?? false) ? Array(texts.dropFirst()) : texts
        let artists = artistRuns(runs)
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM":
            let kind = releaseKind(texts.first)
            return .release(Release(
                id: id, title: title, kind: kind,
                artistName: artists.isEmpty ? byline.first { year($0) == nil } ?? "" : artists.map(\.name).joined(separator: ", "),
                artistID: artists.first?.id, year: texts.lazy.compactMap(year).last,
                artwork: artwork, trackIDs: []))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(Playlist(
                id: id, title: title, kind: playlistKind(id: id, owner: byline.first),
                // The owner only; own lists have none, so a count ("트랙 479개", "78곡") can come first.
                owner: byline.first { !isCount($0) } ?? "", description: nil,
                artwork: artwork, trackIDs: []))
        case "MUSIC_PAGE_TYPE_ARTIST":
            return .artist(Artist(id: id, name: title, artwork: artwork, description: nil, sections: [],
                                  byline: byline.joined(separator: separator).nilIfEmpty))
        case "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            // Library artists browse as "MPLA" + the channel id; the app opens the artist page.
            let channel = id.hasPrefix("MPLA") ? String(id.dropFirst(4)) : id
            return .artist(Artist(id: channel, name: title, artwork: artwork, description: nil, sections: [],
                                  byline: byline.joined(separator: separator).nilIfEmpty))
        default:
            return nil
        }
    }

    static func track(_ node: JSON) -> Track? {
        guard let videoID = node.at("playlistItemData.videoId")?.string
                ?? node.at("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId")?.string
        else { return nil }
        if node.first("musicVideoType")?.string == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return nil }
        let columns = (node["flexColumns"]?.array ?? []).map { $0.at("musicResponsiveListItemFlexColumnRenderer.text") ?? .null }
        func column(_ i: Int) -> JSON { columns.indices.contains(i) ? columns[i] : .null }
        let second = column(1)["runs"]?.array ?? []
        let artists = artistRuns(second)
        // The album sits in its own column (3rd on search/home, 4th on artist pages) or in the byline.
        let albumRun = columns.dropFirst().lazy.flatMap { $0["runs"]?.array ?? [] }
            .first { pageType($0.at("navigationEndpoint.browseEndpoint")) == "MUSIC_PAGE_TYPE_ALBUM" }
        let texts = (column(1).text ?? "").components(separatedBy: separator).filter { !$0.isEmpty }
        let byline = (texts.first.map(isTypeLabel) ?? false) ? Array(texts.dropFirst()) : texts
        let fixed = node.at("fixedColumns.0.musicResponsiveListItemFixedColumnRenderer.text")?.text
        return Track(
            id: videoID, title: column(0).text ?? "",
            artist: artists.isEmpty ? byline.first ?? "" : artists.map(\.name).joined(separator: ", "),
            artistID: artists.first?.id,
            album: albumRun?["text"]?.string ?? "",
            releaseID: albumRun?.at("navigationEndpoint.browseEndpoint.browseId")?.string,
            artwork: artwork(node.at("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails")),
            // Fixed column on albums/search; a flex column on playlist rows.
            duration: (seconds(fixed) ?? columns.dropFirst().lazy.compactMap { seconds($0.text) }.first).map(Double.init),
            isExplicit: isExplicit(node),
            isPlayable: node["musicItemRendererDisplayPolicy"]?.string != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT")
    }

    // MARK: Fields

    /// A page header's save toggle (`BOOKMARK_BORDER` / `BOOKMARK`): its target list and state.
    static func membership(_ header: JSON?) -> LibraryMembership? {
        guard let toggle = header?.all("toggleButtonRenderer").first(where: {
                  $0.at("defaultIcon.iconType")?.string?.hasPrefix("BOOKMARK") == true }),
              let id = toggle.at("defaultServiceEndpoint.likeEndpoint.target.playlistId")?.string
        else { return nil }
        return LibraryMembership(listID: id, isSaved: toggle["isToggled"] == .bool(true))
    }

    /// `EDIT` → the listener's own list; `BOOKMARK*` (save toggle) → someone else's; neither → unknown.
    static func ownership(_ node: JSON?) -> Bool? {
        guard let icons = node?.all("iconType").compactMap(\.string) else { return nil }
        if icons.contains("EDIT") { return true }
        if icons.contains("BOOKMARK") || icons.contains("BOOKMARK_BORDER") { return false }
        return nil
    }

    /// Pinned with "다시 듣기에 고정". The menu toggle is authoritative: it offers
    /// `KEEP_OFF` (unpin) when pinned. The "고정됨" badge is missing on some pinned
    /// library items, so it's only a fallback when the menu has no toggle.
    static func isPinned(_ node: JSON) -> Bool {
        let toggles = (node.at("menu.menuRenderer.items")?.array ?? []).compactMap { $0["toggleMenuServiceItemRenderer"] }
        if let icon = toggles.lazy.compactMap({ $0.at("defaultIcon.iconType")?.string }).first(where: { $0 == "KEEP" || $0 == "KEEP_OFF" }) {
            return icon == "KEEP_OFF"
        }
        return node["subtitleBadges"]?.all("iconType").contains { $0.string == "KEEP" } ?? false
    }

    private static func pageType(_ endpoint: JSON?) -> String? {
        endpoint?.at("browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType")?.string
    }

    private static func artistRuns(_ runs: [JSON]) -> [(name: String, id: String)] {
        runs.compactMap { run in
            guard pageType(run.at("navigationEndpoint.browseEndpoint")) == "MUSIC_PAGE_TYPE_ARTIST",
                  let id = run.at("navigationEndpoint.browseEndpoint.browseId")?.string,
                  let name = run["text"]?.string else { return nil }
            return (name, id)
        }
    }

    /// The service only exposes the kind as localized text.
    static func releaseKind(_ label: String?) -> ReleaseKind? {
        switch label?.lowercased() {
        case "앨범", "album": .album
        case "싱글", "single": .single
        case "ep": .ep
        default: nil
        }
    }

    private static func isCount(_ text: String) -> Bool {
        text.wholeMatch(of: /(트랙 )?[\d,.]+(만|천)?(곡|개|회)|[\d,]+ (tracks|songs|views)/) != nil || text.hasPrefix("조회수")
    }

    private static func isTypeLabel(_ text: String) -> Bool {
        ["재생목록", "playlist", "노래", "song", "동영상", "video", "앨범", "album", "싱글", "single", "ep", "아티스트", "artist"]
            .contains(text.lowercased())
    }

    static func playlistKind(id: String, owner: String?) -> PlaylistKind {
        if id == "VLLM" || id.hasPrefix("VLSE") { return .automatic }
        // RDCLAK… are editorial lists; other RD… ids are generated mixes.
        if id.hasPrefix("VLRD"), !id.hasPrefix("VLRDCLAK") { return .mix }
        return owner == "YouTube Music" ? .editorial : .user
    }

    static func year(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: /^(\d{4})(년)?$/) else { return nil }
        return Int(match.1)
    }

    static func seconds(_ text: String?) -> Int? {
        guard let text, text.wholeMatch(of: /\d+(:\d{2})+/) != nil else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
    }

    private static func isExplicit(_ node: JSON) -> Bool {
        node.all("iconType").contains { $0.string == "MUSIC_EXPLICIT_BADGE" }
    }

    /// Largest thumbnail; square Google image URLs are re-sized to tile resolution.
    /// Wide artist banners keep their own size and crop.
    static func artwork(_ thumbnails: JSON?, resize: Bool = true) -> Artwork {
        let best = (thumbnails?.array ?? []).max { ($0["width"]?.number ?? 0) < ($1["width"]?.number ?? 0) }
        guard var url = best?["url"]?.string else { return .theme(.midnight) }
        if resize, url.contains("googleusercontent.com") {
            url = url.replacing(/=w\d+-h\d+/, with: "=w544-h544")
        }
        return URL(string: url).map(Artwork.remote) ?? .theme(.midnight)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
