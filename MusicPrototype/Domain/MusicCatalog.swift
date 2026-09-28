import SwiftUI

/// Home as the service lays it out: its shelves, titles and order.
struct HomeFeed: Sendable {
    var sections: [HomeSection]
    /// Fixture feeds say so on screen; live feeds don't.
    var isSample = false
}

struct HomeSection: Identifiable, Sendable {
    enum Content: Sendable {
        /// 빠른 선곡, shown first as the paged grid (H1).
        case quickPicks([QuickPick])
        /// Song list; `rowsPerPage` pages it horizontally as the service does, nil stacks it.
        case songs([Track], rowsPerPage: Int?)
        case items([BrowseItem])
    }

    let id: String
    let title: String
    let content: Content
}

/// Result-type chips shared by Apple Music and YouTube Music search.
enum SearchFilter: CaseIterable, Hashable, Sendable {
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

/// A release page: the release, its tracks in order, and the shelves below them.
struct ReleaseDetail: Sendable {
    let release: Release
    let tracks: [Track]
    /// Titled by the service ("맞춤 발표곡"); may hold other artists' releases.
    let shelves: [DetailShelf]
}

/// A playlist page. Long lists arrive in pages; `next` fetches the rest.
struct PlaylistDetail: Sendable {
    /// Opaque to views; only the catalog that issued it can use it.
    struct Continuation: Hashable, Sendable {
        let token: String
    }

    struct Page: Sendable {
        let tracks: [Track]
        let next: Continuation?
    }

    let playlist: Playlist
    let tracks: [Track]
    /// The service's own count line ("1,110곡 • 6시간 이상"); nil computes it from `tracks`.
    var summary: String? = nil
    var next: Continuation? = nil
}

/// An artist page in the service's own section order.
struct ArtistDetail: Sendable {
    enum Content: Sendable {
        case songs([Track])
        case items([BrowseItem])
    }

    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let content: Content
    }

    let artist: Artist
    let sections: [Section]
    /// The header's 믹스 (RDEM…) and 셔플 (RDAO…) queues, for when playback exists.
    var radioPlaylistID: String? = nil
    var shufflePlaylistID: String? = nil

    /// The page's songs, for the mock radio.
    var songs: [Track] {
        sections.flatMap { section -> [Track] in if case .songs(let tracks) = section.content { tracks } else { [] } }
    }
}

struct DetailShelf: Identifiable, Sendable {
    let id: String
    let title: String
    var route: Route? = nil
    let items: [BrowseItem]
}

/// One page of catalog search; `top` is the service's highlighted result.
struct SearchResults: Sendable {
    var top: BrowseItem?
    var items: [BrowseItem]
}

enum CatalogError: LocalizedError {
    case signedOut
    case http(Int)
    case unexpectedResponse
    /// Replay mode has no recording for this request.
    case notRecorded
    case notFound

    var errorDescription: String? {
        switch self {
        case .signedOut: "YouTube Music 세션이 만료되었거나 로그아웃되었습니다. 다시 로그인한 세션으로 갱신한 뒤 다시 시도하세요."
        case .notRecorded: "이 요청은 녹화된 응답이 없습니다."
        case .notFound: "페이지를 찾을 수 없습니다."
        case .http(let status): "YouTube Music 서버 오류 (HTTP \(status))"
        case .unexpectedResponse: "YouTube Music 응답을 해석하지 못했습니다."
        }
    }
}

/// Where browse data comes from. Views ask for domain values; how requests are
/// made and authenticated stays behind this boundary.
protocol MusicCatalog: Sendable {
    func home() async throws -> HomeFeed
    func search(_ query: String, filter: SearchFilter) async throws -> SearchResults
    func release(_ id: Release.ID) async throws -> ReleaseDetail
    func artist(_ id: Artist.ID) async throws -> ArtistDetail
    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail
    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page
}

extension EnvironmentValues {
    @Entry var musicCatalog: any MusicCatalog = MockMusicCatalog()
}

/// The local fixtures, unchanged from the prototype.
struct MockMusicCatalog: MusicCatalog {
    func home() async throws -> HomeFeed {
        HomeFeed(sections: [
            HomeSection(id: "quickPicks", title: "빠른 선곡", content: .quickPicks(Catalog.quickPicks)),
            HomeSection(id: "forgotten", title: "잊고 있던 좋은 음악", content: .songs(Catalog.forgottenFavorites, rowsPerPage: nil)),
            HomeSection(id: "listenAgain", title: "다시 듣기", content: .items(Catalog.listenAgain)),
            HomeSection(id: "mixes", title: "나만의 믹스", content: .items(Catalog.mixesForYou)),
        ], isSample: true)
    }

    func search(_ query: String, filter: SearchFilter) async throws -> SearchResults {
        let q = query
        let artists = Catalog.artists.filter { $0.name.localizedStandardContains(q) }.map(BrowseItem.artist)
        let releases = Catalog.releases.filter { "\($0.title) \($0.artistName)".localizedStandardContains(q) }.map(BrowseItem.release)
        let playlists = Catalog.playlists.filter { "\($0.title) \($0.owner)".localizedStandardContains(q) }.map(BrowseItem.playlist)
        let songs = Catalog.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(q) }.map(BrowseItem.track)
        let items: [BrowseItem] = switch filter {
        case .top: artists + songs + releases + playlists
        case .songs: songs
        case .albums: releases
        case .artists: artists
        case .playlists: playlists
        }
        return SearchResults(top: nil, items: items)
    }

    func release(_ id: Release.ID) async throws -> ReleaseDetail {
        guard let release = Catalog.release(id) else { throw CatalogError.notFound }
        let more = Catalog.releases(by: release.artistID, excluding: release.id).map(BrowseItem.release)
        return ReleaseDetail(
            release: release, tracks: Catalog.tracks(of: release),
            shelves: more.isEmpty ? [] : [DetailShelf(id: "more", title: "\(release.artistName)의 다른 음악",
                                                      route: release.artistID.map(Route.artist), items: more)])
    }

    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail {
        guard let playlist = Catalog.playlist(id) else { throw CatalogError.notFound }
        return PlaylistDetail(playlist: playlist, tracks: Catalog.tracks(of: playlist))
    }

    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page {
        throw CatalogError.notFound
    }

    func artist(_ id: Artist.ID) async throws -> ArtistDetail {
        guard let artist = Catalog.artist(id) else { throw CatalogError.notFound }
        let sections = artist.sections.enumerated().map { index, section in
            let content: ArtistDetail.Content = switch section.content {
            case .songs(let ids): .songs(Catalog.tracks(ids))
            case .releases(let ids): .items(ids.compactMap(Catalog.release).map(BrowseItem.release))
            case .playlists(let ids): .items(ids.compactMap(Catalog.playlist).map(BrowseItem.playlist))
            case .artists(let ids): .items(ids.compactMap(Catalog.artist).map(BrowseItem.artist))
            }
            return ArtistDetail.Section(id: "\(index)", title: section.title, content: content)
        }
        return ArtistDetail(artist: artist, sections: sections)
    }
}
