import Foundation

// Domain-shaped results. Field names follow MusicPrototype/Domain so the app
// can adopt them by swapping `ArtworkTheme` for an artwork URL.

public struct NRef: Sendable, Hashable {
    public let name: String
    public let browseID: String?
}

public enum NReleaseKind: Sendable, Hashable {
    case album, single, ep
    /// The service only exposes the kind as localized text.
    static func parse(_ label: String?) -> NReleaseKind? {
        switch label?.lowercased() {
        case "앨범", "album": .album
        case "싱글", "single": .single
        case "ep": .ep
        default: nil
        }
    }
}

public struct NTrack: Sendable, Hashable {
    public let id: String
    public let title: String
    public let artists: [NRef]
    public let album: NRef?
    public let durationSeconds: Int?
    public let isExplicit: Bool
    public let artworkURL: URL?
    public let index: Int?
    public let unplayableReason: String?
    public var artist: String { artists.map(\.name).joined(separator: ", ") }
}

public struct NRelease: Sendable, Hashable {
    public let id: String
    public let audioPlaylistID: String?
    public let title: String
    public let kind: NReleaseKind?
    public let artist: NRef?
    public let year: Int?
    public let artworkURL: URL?
    public let tracks: [NTrack]
    /// Server-titled shelves below the tracks ("맞춤 발표곡"); not necessarily the same artist.
    public let shelves: [NSection]
}

public struct NSection: Sendable, Hashable {
    public let title: String
    public let items: [NItem]
    public let moreBrowseID: String?
}

public struct NArtistPage: Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let subscribers: String?
    /// "믹스" button (RDEM…) and "셔플" button (RDAO…).
    public let radioPlaylistID: String?
    public let shufflePlaylistID: String?
    public let artworkURL: URL?
    public let sections: [NSection]
}

public indirect enum NItem: Sendable, Hashable {
    case track(NTrack)
    case release(id: String, title: String, kind: NReleaseKind?, artist: String?, year: Int?, artworkURL: URL?)
    case playlist(id: String, title: String, owner: String?, artworkURL: URL?)
    case artist(id: String, name: String, artworkURL: URL?)
    /// Episodes, profiles, podcasts: kept so nothing is silently dropped.
    case other(kind: String, title: String)
}

public struct NSearch: Sendable, Hashable {
    public let filters: [String]
    public let top: NItem?
    public let items: [NItem]
}

public struct NSuggestions: Sendable, Hashable {
    public let queries: [String]
    public let items: [NItem]
}

public struct NQueue: Sendable, Hashable {
    public let playlistID: String?
    public let tracks: [NTrack]
    public let hasContinuation: Bool
    public let lyricsBrowseID: String?
    public let relatedBrowseID: String?
}

public enum Normalize {
    // MARK: Pages

    public static func release(_ root: JSON, id: String) -> NRelease? {
        let two = root.at("contents.twoColumnBrowseResultsRenderer")
        guard let header = two?.at("tabs.0.tabRenderer.content.sectionListRenderer.contents.0.musicResponsiveHeaderRenderer") else { return nil }
        let subtitle = runs(header["subtitle"])
        let strapline = header.at("straplineTextOne.runs.0")
        let artist = strapline.flatMap { r in r["text"]?.string.map { NRef(name: $0, browseID: browseID(r)) } }
        let secondary = two?.at("secondaryContents.sectionListRenderer.contents")?.array ?? []
        let shelf = secondary.first?["musicShelfRenderer"]
        let tracks = (shelf?["contents"]?.array ?? []).compactMap { listItem($0["musicResponsiveListItemRenderer"]) }
            .compactMap { if case .track(let t) = $0 { t } else { nil } }
        let shelves = secondary.dropFirst().compactMap { $0["musicCarouselShelfRenderer"] }.map { c in
            NSection(title: c.at("header.musicCarouselShelfBasicHeaderRenderer.title")?.text ?? "", items: carouselItems(c), moreBrowseID: nil)
        }
        return NRelease(
            id: id,
            audioPlaylistID: root.all("playlistId").compactMap(\.string).first { $0.hasPrefix("OLAK5uy_") },
            title: header["title"]?.text ?? "",
            kind: NReleaseKind.parse(subtitle.first),
            artist: artist,
            year: year(subtitle),
            artworkURL: thumbnail(header),
            tracks: tracks,
            shelves: shelves)
    }

    public static func artist(_ root: JSON, id: String) -> NArtistPage? {
        guard let header = root.at("header.musicImmersiveHeaderRenderer") ?? root.at("header.musicVisualHeaderRenderer") else { return nil }
        let contents = root.at("contents.singleColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")?.array ?? []
        let sections: [NSection] = contents.compactMap { node in
            if let shelf = node["musicShelfRenderer"] {
                return NSection(title: shelf["title"]?.text ?? "",
                                items: (shelf["contents"]?.array ?? []).compactMap { listItem($0["musicResponsiveListItemRenderer"]) },
                                moreBrowseID: shelf.at("bottomEndpoint.browseEndpoint.browseId")?.string)
            }
            if let carousel = node["musicCarouselShelfRenderer"] {
                let head = carousel.at("header.musicCarouselShelfBasicHeaderRenderer")
                return NSection(title: head?["title"]?.text ?? "",
                                items: carouselItems(carousel),
                                moreBrowseID: head?.at("moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint.browseId")?.string
                                    ?? head?.at("title.runs.0.navigationEndpoint.browseEndpoint.browseId")?.string)
            }
            return nil
        }
        return NArtistPage(
            id: id,
            name: header["title"]?.text ?? "",
            description: header["description"]?.text,
            subscribers: header.at("subscriptionButton.subscribeButtonRenderer.subscriberCountText")?.text,
            radioPlaylistID: header.at("startRadioButton.buttonRenderer.navigationEndpoint.watchPlaylistEndpoint.playlistId")?.string,
            shufflePlaylistID: header.at("playButton.buttonRenderer.navigationEndpoint.watchPlaylistEndpoint.playlistId")?.string,
            artworkURL: thumbnail(header),
            sections: sections)
    }

    public static func search(_ root: JSON) -> NSearch {
        let list = root.at("contents.tabbedSearchResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer")
        let filters = (list?.at("header.chipCloudRenderer.chips")?.array ?? []).compactMap { $0.at("chipCloudChipRenderer.text")?.text }
        var top: NItem?
        var items: [NItem] = []
        for node in list?["contents"]?.array ?? [] {
            if let card = node["musicCardShelfRenderer"] {
                top = cardItem(card)
            }
            // Results arrive either as one shelf or as one itemSection per result.
            let rows = (node.at("musicShelfRenderer.contents")?.array ?? []) + (node.at("itemSectionRenderer.contents")?.array ?? [])
            items += rows.compactMap { listItem($0["musicResponsiveListItemRenderer"]) }
        }
        return NSearch(filters: filters, top: top, items: items)
    }

    public static func suggestions(_ root: JSON) -> NSuggestions {
        let entries = (root["contents"]?.array ?? []).flatMap { $0.at("searchSuggestionsSectionRenderer.contents")?.array ?? [] }
        return NSuggestions(
            queries: entries.compactMap { $0.at("searchSuggestionRenderer.suggestion")?.text },
            items: entries.compactMap { listItem($0["musicResponsiveListItemRenderer"]) })
    }

    public static func queue(_ root: JSON) -> NQueue {
        let tabs = root.at("contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs")?.array ?? []
        let panel = tabs.first?.at("tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer")
            ?? root.at("continuationContents.playlistPanelContinuation")
        let tracks = (panel?["contents"]?.array ?? []).compactMap { node -> NTrack? in
            guard let v = node["playlistPanelVideoRenderer"] ?? node.at("playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer"),
                  let id = v["videoId"]?.string else { return nil }
            // "아티스트 • 앨범 • 연도": artist and album runs carry browse endpoints.
            let byline = v["longBylineText"]?["runs"]?.array ?? []
            let refs = byline.filter { browseID($0) != nil }
            let artistRefs = refs.filter { browseID($0)?.hasPrefix("UC") == true }.compactMap { r in r["text"]?.string.map { NRef(name: $0, browseID: browseID(r)) } }
            let album = refs.first { browseID($0)?.hasPrefix("MPRE") == true }.flatMap { r in r["text"]?.string.map { NRef(name: $0, browseID: browseID(r)) } }
            return NTrack(id: id, title: v["title"]?.text ?? "", artists: artistRefs, album: album,
                          durationSeconds: seconds(v["lengthText"]?.text), isExplicit: isExplicit(v),
                          artworkURL: thumbnail(v), index: nil, unplayableReason: v["unplayableText"]?.text)
        }
        func tabBrowse(_ i: Int) -> String? { tabs.count > i ? tabs[i].at("tabRenderer.endpoint.browseEndpoint.browseId")?.string : nil }
        return NQueue(playlistID: panel?["playlistId"]?.string, tracks: tracks,
                      hasContinuation: panel?["continuations"] != nil,
                      lyricsBrowseID: tabBrowse(1), relatedBrowseID: tabBrowse(3))
    }

    // MARK: Items

    static func listItem(_ li: JSON?) -> NItem? {
        guard let li else { return nil }
        let columns: [JSON] = (li["flexColumns"]?.array ?? []).map { $0.at("musicResponsiveListItemFlexColumnRenderer.text") ?? .null }
        func column(_ i: Int) -> JSON { columns.indices.contains(i) ? columns[i] : .null }
        let title = column(0).text ?? ""
        let secondRuns: [JSON] = column(1)["runs"]?.array ?? []
        let secondTexts = secondRuns.compactMap { $0["text"]?.string }.filter { $0 != " • " }
        let nav = li["navigationEndpoint"]

        if let pageType = nav?.at("browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType")?.string,
           let id = nav?.at("browseEndpoint.browseId")?.string {
            return classify(pageType: pageType, id: id, title: title, subtitle: secondTexts, artwork: thumbnail(li))
        }
        guard let videoID = li.at("playlistItemData.videoId")?.string
                ?? li.at("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId")?.string
        else { return nil }
        let videoType = li.first("musicVideoType")?.string
        if videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return .other(kind: "episode", title: title) }
        let artists = secondRuns.filter { browseID($0)?.hasPrefix("UC") == true }.compactMap { r in r["text"]?.string.map { NRef(name: $0, browseID: browseID(r)) } }
        let albumRun: JSON? = column(2)["runs"]?.array.first ?? secondRuns.first { browseID($0)?.hasPrefix("MPRE") == true }
        let fixed = li.at("fixedColumns.0.musicResponsiveListItemFixedColumnRenderer.text")?.text
        let duration = seconds(fixed) ?? secondTexts.last.flatMap(seconds)
        return .track(NTrack(
            id: videoID, title: title,
            artists: artists,
            album: albumRun.flatMap { r in r["text"]?.string.map { NRef(name: $0, browseID: browseID(r)) } },
            durationSeconds: duration, isExplicit: isExplicit(li), artworkURL: thumbnail(li),
            index: li["index"]?.text.flatMap(Int.init), unplayableReason: nil))
    }

    static func carouselItems(_ carousel: JSON) -> [NItem] {
        (carousel["contents"]?.array ?? []).compactMap { node in
            if let two = node["musicTwoRowItemRenderer"] {
                let subtitle = (two["subtitle"]?["runs"]?.array ?? []).compactMap { $0["text"]?.string }.filter { $0 != " • " }
                let title = two["title"]?.text ?? ""
                if let pageType = two.at("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType")?.string,
                   let id = two.at("navigationEndpoint.browseEndpoint.browseId")?.string {
                    return classify(pageType: pageType, id: id, title: title, subtitle: subtitle, artwork: thumbnail(two))
                }
                if let videoID = two.at("navigationEndpoint.watchEndpoint.videoId")?.string {
                    return .track(NTrack(id: videoID, title: title, artists: [], album: nil, durationSeconds: nil,
                                         isExplicit: false, artworkURL: thumbnail(two), index: nil, unplayableReason: nil))
                }
                return nil
            }
            return listItem(node["musicResponsiveListItemRenderer"])
        }
    }

    static func cardItem(_ card: JSON) -> NItem? {
        let run = card.at("title.runs.0")
        guard let pageType = run?.at("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType")?.string,
              let id = run.flatMap(browseID) else { return nil }
        let subtitle = (card["subtitle"]?["runs"]?.array ?? []).compactMap { $0["text"]?.string }.filter { $0 != " • " }
        return classify(pageType: pageType, id: id, title: run?["text"]?.string ?? "", subtitle: subtitle, artwork: thumbnail(card))
    }

    /// Subtitle runs are localized: "싱글 • 아이유 • 2026년", "재생목록 • YouTube Music • 78곡".
    static func classify(pageType: String, id: String, title: String, subtitle: [String], artwork: URL?) -> NItem {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM":
            let kind = NReleaseKind.parse(subtitle.first)
            let artist = subtitle.dropFirst(kind == nil ? 0 : 1).first { year([$0]) == nil }
            return .release(id: id, title: title, kind: kind, artist: artist, year: year(subtitle), artworkURL: artwork)
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(id: id, title: title, owner: subtitle.count > 1 ? subtitle[1] : nil, artworkURL: artwork)
        case "MUSIC_PAGE_TYPE_ARTIST":
            return .artist(id: id, name: title, artworkURL: artwork)
        default:
            return .other(kind: pageType.replacingOccurrences(of: "MUSIC_PAGE_TYPE_", with: "").lowercased(), title: title)
        }
    }

    // MARK: Fields

    static func runs(_ node: JSON?) -> [String] {
        (node?["runs"]?.array ?? []).compactMap { $0["text"]?.string }.filter { $0 != " • " }
    }

    static func browseID(_ run: JSON) -> String? { run.at("navigationEndpoint.browseEndpoint.browseId")?.string }

    static func year(_ parts: [String]) -> Int? {
        parts.reversed().lazy.compactMap { $0.firstCapture(#"^(\d{4})"#).flatMap(Int.init) }.first
    }

    static func seconds(_ text: String?) -> Int? {
        guard let text, text.contains(":") else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
    }

    static func isExplicit(_ node: JSON) -> Bool {
        node.all("iconType").contains { $0.string == "MUSIC_EXPLICIT_BADGE" }
    }

    /// Largest square artwork on the node.
    static func thumbnail(_ node: JSON) -> URL? {
        let thumbs = node.all("thumbnails").first?.array ?? []
        return thumbs.max { ($0["width"]?.number ?? 0) < ($1["width"]?.number ?? 0) }?["url"]?.string.flatMap(URL.init(string:))
    }
}
