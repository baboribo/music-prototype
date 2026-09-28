import SwiftUI
import Synchronization

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

/// Whether a release or playlist is saved in the listener's library, and the
/// id the service saves it under (an album's `OLAK5uy_…` list, a playlist's id).
struct LibraryMembership: Hashable, Sendable {
    let listID: String
    let isSaved: Bool
}

/// A release page: the release, its tracks in order, and the shelves below them.
struct ReleaseDetail: Sendable {
    let release: Release
    let tracks: [Track]
    /// The release's playlist on the service (`OLAK5uy_…`), which its queue is built from.
    var queuePlaylistID: String? = nil
    /// Titled by the service ("맞춤 발표곡"); may hold other artists' releases.
    let shelves: [DetailShelf]
    /// Nil when the page offers no save toggle.
    var membership: LibraryMembership? = nil
}

/// Opaque to views; only the catalog that issued it can use it.
struct CatalogContinuation: Hashable, Sendable {
    let token: String
}

/// The library root: the listener's pinned items, then recent activity.
struct LibraryFeed: Sendable {
    let pinned: [BrowseItem]
    let recent: [BrowseItem]
}

/// One page of a library category, in the service's order.
struct LibraryPage: Sendable {
    let items: [BrowseItem]
    var next: CatalogContinuation? = nil
}

/// A playlist page. Long lists arrive in pages; `next` fetches the rest.
struct PlaylistDetail: Sendable {
    typealias Continuation = CatalogContinuation

    struct Page: Sendable {
        let tracks: [Track]
        let next: Continuation?
    }

    let playlist: Playlist
    let tracks: [Track]
    /// The service's own count line ("1,110곡 • 6시간 이상"); nil computes it from `tracks`.
    var summary: String? = nil
    var next: Continuation? = nil
    /// Nil for the listener's own lists (already in the library) and when unknown.
    var membership: LibraryMembership? = nil
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

/// YouTube Music searches either its catalog or the listener's library. The library
/// scope is the service's own: it covers library songs, albums, artists and the
/// listener's own playlists, but not other people's saved playlists.
enum SearchScope: Hashable, Sendable { case catalog, library }

/// The 아티스트 screen's two lists, which are different things on the service.
enum LibraryArtistScope: Hashable, Sendable, CaseIterable {
    /// Artists of the songs in the library ("27곡").
    case library
    /// Subscribed artist channels ("구독자 N명").
    case subscribed

    var title: String {
        switch self {
        case .library: "보관함"
        case .subscribed: "구독"
        }
    }
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

/// A reversible change to the listener's account. Each case has an exact inverse.
enum LibraryEdit: Hashable, Sendable {
    /// Like (`true`) or remove the like from a song or video.
    case like(Track.ID, Bool)
    /// Save (`true`) a release or playlist to the library, or remove it.
    case save(listID: String, Bool)
}

/// Data a write can make stale. Views holding that data reload when its revision changes.
enum CatalogScope: Hashable, Sendable {
    /// One playlist's page (the liked-music list for likes).
    case playlist(Playlist.ID)
    /// The library root, its category lists and library-scoped search.
    case library
}

/// Revisions per scope; a completed write bumps the scopes it affected.
@MainActor
@Observable
final class CatalogChanges {
    private var revisions: [CatalogScope: Int] = [:]

    func revision(_ scope: CatalogScope) -> Int { revisions[scope, default: 0] }

    func invalidate(_ scopes: Set<CatalogScope>) {
        for scope in scopes { revisions[scope, default: 0] += 1 }
    }
}

/// Where browse data comes from. Views ask for domain values; how requests are
/// made and authenticated stays behind this boundary.
protocol MusicCatalog: Sendable {
    func home() async throws -> HomeFeed
    func search(_ query: String, filter: SearchFilter, scope: SearchScope) async throws -> SearchResults
    func release(_ id: Release.ID) async throws -> ReleaseDetail
    func artist(_ id: Artist.ID) async throws -> ArtistDetail
    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail
    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page
    func library() async throws -> LibraryFeed
    func library(_ category: LibraryCategory) async throws -> LibraryPage
    func libraryArtists(_ scope: LibraryArtistScope) async throws -> LibraryPage
    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage
    func queue(_ seed: QueueSeed) async throws -> QueuePage
    func queuePage(_ continuation: CatalogContinuation) async throws -> QueuePage
    /// Applies the edit on the service; returns the scopes whose data it changed.
    func apply(_ edit: LibraryEdit) async throws -> Set<CatalogScope>
}

extension EnvironmentValues {
    @Entry var musicCatalog: any MusicCatalog = MockMusicCatalog()
}

/// Library saves made against the fixtures this session (no service).
private enum MockSaves {
    static let ids = Mutex(Set(Catalog.libraryReleases.map(\.id) + Catalog.libraryPlaylists.map(\.id)))
    static func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
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

    func search(_ query: String, filter: SearchFilter, scope: SearchScope) async throws -> SearchResults {
        let q = query
        let inLibrary = scope == .library
        let artists = (inLibrary ? Catalog.libraryArtists : Catalog.artists).filter { $0.name.localizedStandardContains(q) }.map(BrowseItem.artist)
        let releases = (inLibrary ? Catalog.releases.filter { MockSaves.contains($0.id) } : Catalog.releases).filter { "\($0.title) \($0.artistName)".localizedStandardContains(q) }.map(BrowseItem.release)
        // Like the service, the library scope finds only the listener's own playlists.
        let playlists = (inLibrary ? Catalog.playlists.filter { $0.kind == .user && MockSaves.contains($0.id) } : Catalog.playlists)
            .filter { "\($0.title) \($0.owner)".localizedStandardContains(q) }.map(BrowseItem.playlist)
        let songs = (inLibrary ? Catalog.librarySongs : Catalog.tracks).filter { "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(q) }.map(BrowseItem.track)
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
                                                      route: release.artistID.map(Route.artist), items: more)],
            membership: LibraryMembership(listID: release.id, isSaved: MockSaves.contains(release.id)))
    }

    func playlist(_ id: Playlist.ID) async throws -> PlaylistDetail {
        guard let playlist = Catalog.playlist(id) else { throw CatalogError.notFound }
        return PlaylistDetail(playlist: playlist, tracks: Catalog.tracks(of: playlist),
                              membership: playlist.isListenersOwn ? nil
                                  : LibraryMembership(listID: playlist.id, isSaved: MockSaves.contains(playlist.id)))
    }

    func playlistPage(_ continuation: PlaylistDetail.Continuation) async throws -> PlaylistDetail.Page {
        throw CatalogError.notFound
    }

    func library() async throws -> LibraryFeed {
        LibraryFeed(pinned: Catalog.libraryPinned, recent: Catalog.libraryRecent)
    }

    func library(_ category: LibraryCategory) async throws -> LibraryPage {
        let items: [BrowseItem] = switch category {
        case .playlists: Catalog.playlists.filter { MockSaves.contains($0.id) }.map(BrowseItem.playlist)
        case .songs: Catalog.librarySongs.map(BrowseItem.track)
        case .albums: Catalog.releases.filter { MockSaves.contains($0.id) }.map(BrowseItem.release)
        case .artists: Catalog.libraryArtists.map(BrowseItem.artist)
        }
        return LibraryPage(items: items)
    }

    func libraryArtists(_ scope: LibraryArtistScope) async throws -> LibraryPage {
        switch scope {
        case .library: try await library(.artists)
        case .subscribed: LibraryPage(items: Catalog.subscribedArtists.map(BrowseItem.artist))
        }
    }

    func libraryPage(_ continuation: CatalogContinuation) async throws -> LibraryPage {
        throw CatalogError.notFound
    }

    /// Fixture queues: the prototype's local mix order, or the list as given.
    func queue(_ seed: QueueSeed) async throws -> QueuePage {
        let (tracks, start): ([Track], Track?) = switch seed {
        case .radio(let track):
            // Mock mix: the seed, then the rest of the catalog in a stable order.
            {
                let others = Catalog.tracks.filter { $0.id != track.id }
                let offset = (Catalog.tracks.firstIndex(of: track) ?? 0) % max(1, others.count)
                return ([track] + Array(others[offset...] + others[..<offset]), track)
            }()
        case .list(_, let tracks, let start): (tracks, start)
        case .artist(_, let songs): (songs, songs.first)
        }
        return QueuePage(items: tracks.map { QueueItem(track: $0) },
                         selectedIndex: start.flatMap { s in tracks.firstIndex { $0.id == s.id } })
    }

    func queuePage(_ continuation: CatalogContinuation) async throws -> QueuePage {
        throw CatalogError.notFound
    }

    /// Fixtures don't change; the scopes are still reported so views exercise their reload.
    func apply(_ edit: LibraryEdit) async throws -> Set<CatalogScope> {
        switch edit {
        case .like: return [.playlist("liked"), .library]
        case .save(let id, let saved):
            MockSaves.ids.withLock { ids in
                if saved { ids.insert(id) } else { ids.remove(id) }
            }
            return [.library]
        }
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
