import SwiftUI

// Shared Apple Music browse grammar. Metrics are points on the 430pt reference
// captures (release: IMG_4058/4094, playlist: IMG_4082, artist: IMG_4088,
// library: am-library); they are content-independent, so Dynamic Type still reflows.

enum BrowseMetrics {
    static let margin: CGFloat = 20
    static let headerArtwork: CGFloat = 294
    static let rowArtwork: CGFloat = 48
    static let numberedRowHeight: CGFloat = 52
    static let artworkRowHeight: CGFloat = 56
    static let shelfTile: CGFloat = 175
    static let artistTile: CGFloat = 112
}

// MARK: Navigation

private struct BrowseNavigateKey: EnvironmentKey {
    static let defaultValue: @MainActor (Route) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes onto the current tab's stack; used where a NavigationLink can't live (menus).
    var browseNavigate: @MainActor (Route) -> Void {
        get { self[BrowseNavigateKey.self] }
        set { self[BrowseNavigateKey.self] = newValue }
    }
}

extension BrowseItem {
    var route: Route? {
        switch self {
        case .track: nil
        case .release(let v): .release(v.id)
        case .playlist(let v): .playlist(v.id)
        case .artist(let v): .artist(v.id)
        }
    }

    var title: String {
        switch self {
        case .track(let v): v.title
        case .release(let v): v.displayTitle
        case .playlist(let v): v.title
        case .artist(let v): v.name
        }
    }

    var subtitle: String {
        switch self {
        case .track(let v): v.artist
        case .release(let v): v.artistName
        case .playlist(let v): v.kind == .mix ? (v.description ?? v.owner) : v.owner
        case .artist: "아티스트"
        }
    }

    var artwork: Artwork {
        switch self {
        case .track(let v): v.artwork
        case .release(let v): v.artwork
        case .playlist(let v): v.artwork
        case .artist(let v): v.artwork
        }
    }

    var isArtist: Bool { if case .artist = self { true } else { false } }
}

extension View {
    /// One destination table for every tab so all detail pages are reachable from anywhere.
    func browseDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .release(let id):
                ReleaseDestination(id: id)
            case .playlist(let id):
                PlaylistDestination(id: id)
            case .artist(let id):
                ArtistDestination(id: id)
            case .library(let category): LibraryCategoryView(category: category)
            }
        }
    }
}

private struct ReleaseDestination: View {
    @Environment(\.musicCatalog) private var catalog
    let id: Release.ID

    var body: some View {
        CatalogPage { [catalog, id] in try await catalog.release(id) } content: { ReleaseDetailView(detail: $0) }
    }
}

private struct ArtistDestination: View {
    @Environment(\.musicCatalog) private var catalog
    let id: Artist.ID

    var body: some View {
        CatalogPage { [catalog, id] in try await catalog.artist(id) } content: { ArtistDetailView(detail: $0) }
    }
}

private struct PlaylistDestination: View {
    @Environment(\.musicCatalog) private var catalog
    let id: Playlist.ID

    var body: some View {
        CatalogPage(scope: .playlist(id)) { [catalog, id] in try await catalog.playlist(id) } content: { PlaylistDetailView(detail: $0) }
    }
}

// MARK: Headers

/// Apple's shelf heading: bold title with a trailing chevron when it leads somewhere.
struct ShelfHeader: View {
    let title: String
    var route: Route? = nil

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { label(chevron: true) }.buttonStyle(.plain)
            } else {
                label(chevron: false)
            }
        }
        .padding(.horizontal, BrowseMetrics.margin)
        .accessibilityAddTraits(.isHeader)
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            if chevron {
                Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Centered artwork + title + subtitle + meta line (release and playlist pages).
struct DetailHeader: View {
    let artwork: Artwork
    let title: String
    let subtitle: String
    var subtitleRoute: Route? = nil
    /// Releases show "kind · year"; Apple's playlist header has no meta line.
    var meta: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ArtworkView(artwork: artwork, cornerRadius: 10)
                .frame(width: BrowseMetrics.headerArtwork, height: BrowseMetrics.headerArtwork)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .padding(.top, 14)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Group {
                if subtitle.isEmpty {
                    // Mixes and some playlists name no owner.
                    EmptyView()
                } else if let subtitleRoute {
                    NavigationLink(value: subtitleRoute) { Text(subtitle) }.buttonStyle(.plain)
                } else {
                    Text(subtitle)
                }
            }
            .font(.title3)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
            if let meta {
                Text(meta)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            }
        }
        .padding(.horizontal, BrowseMetrics.margin)
        .frame(maxWidth: .infinity)
    }
}

/// Shuffle circle · Play capsule · trailing circle (47 / 160×48 / 47 on the reference).
struct PlaybackActions<Trailing: View>: View {
    let shuffle: () -> Void
    let play: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Button(action: shuffle) {
                Image(systemName: "shuffle").font(.body.weight(.semibold)).frame(width: 47, height: 47)
            }
            .background(Color(.tertiarySystemFill), in: Circle())
            .accessibilityLabel("임의 재생")

            Button(action: play) {
                Label("재생", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 160, height: 48)
            }
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary, in: Capsule())
            .accessibilityIdentifier("detail.play")

            trailing()
                .frame(width: 47, height: 47)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// "저장" to the YouTube Music library, kept in session state only.
struct LibrarySaveButton: View {
    @Environment(MockLibrary.self) private var library
    let id: String

    var body: some View {
        Button { library.toggle(id) } label: {
            Image(systemName: library.contains(id) ? "checkmark" : "plus")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 47, height: 47)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(library.contains(id) ? "보관함에서 삭제" : "보관함에 저장")
        .accessibilityValue("이 기기의 샘플 상태")
    }
}

// MARK: Song rows

/// One row type for every song list; the leading slot is the only variant.
struct SongRow: View {
    enum Leading { case number(Int), artwork }

    @Environment(MockPlayer.self) private var player
    @Environment(\.browseNavigate) private var navigate
    let track: Track
    let leading: Leading
    /// Second line; nil keeps the row single-line (album rows for the album artist).
    var subtitle: String?
    /// Suppresses "go to album" when already on that album.
    var hideAlbumLink = false
    let play: () -> Void

    private var isCurrent: Bool { player.currentTrack?.id == track.id }
    private var textLeading: CGFloat {
        switch leading {
        case .number: 31
        case .artwork: BrowseMetrics.rowArtwork + 12
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(spacing: 0) {
                    leadingSlot
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(track.title).lineLimit(1)
                            if track.isExplicit {
                                Image(systemName: "e.square.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("청소년 유해")
                            }
                        }
                        .font(.body)
                        if let subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: subtitle == nil && isNumbered ? BrowseMetrics.numberedRowHeight : BrowseMetrics.artworkRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!track.isPlayable)
            .opacity(track.isPlayable ? 1 : 0.4)
            .accessibilityLabel(subtitle.map { "\(track.title), \($0)" } ?? track.title)
            .accessibilityValue(isCurrent ? (player.isPlaying ? "재생 중" : "일시정지") : "")
            .accessibilityIdentifier("track.\(track.id)")

            menu
        }
        .padding(.leading, BrowseMetrics.margin)
        .overlay(alignment: .leading) {
            if player.isFavorite(track.id) {
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1 / 3)
                .padding(.leading, BrowseMetrics.margin + textLeading)
                .padding(.trailing, BrowseMetrics.margin)
        }
    }

    private var isNumbered: Bool { if case .number = leading { true } else { false } }

    @ViewBuilder private var leadingSlot: some View {
        switch leading {
        case .number(let n):
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(.tint)
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("\(n)").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            .padding(.trailing, 9)
        case .artwork:
            ArtworkView(artwork: track.artwork, cornerRadius: 4)
                .frame(width: BrowseMetrics.rowArtwork, height: BrowseMetrics.rowArtwork)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45))
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(.white)
                            .font(.body.weight(.bold))
                    }
                }
                .padding(.trailing, 12)
        }
    }

    private var menu: some View {
        Menu {
            Button("라디오 시작", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(from: track) }
            if let releaseID = track.releaseID, !hideAlbumLink {
                Button("앨범으로 이동", systemImage: "square.stack") { navigate(.release(releaseID)) }
            }
            if let artistID = track.artistID {
                Button("아티스트로 이동", systemImage: "music.microphone") { navigate(.artist(artistID)) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("\(track.title) 옵션")
        .padding(.trailing, 6)
    }
}

// MARK: Tiles and shelves

/// Square artwork (circular for artists) with one or two lines below.
struct ItemTile: View {
    let item: BrowseItem
    var width: CGFloat = BrowseMetrics.shelfTile
    var centered = false

    var body: some View {
        VStack(alignment: item.isArtist || centered ? .center : .leading, spacing: 0) {
            ArtworkView(artwork: item.artwork, cornerRadius: item.isArtist ? width / 2 : 6)
                .frame(width: width, height: width)
                .padding(.bottom, 7)
            Text(item.title)
                .font(item.isArtist ? .subheadline : .subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !item.isArtist, !centered {
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

/// Horizontal, view-aligned shelf with the Apple peek; tracks play, everything else pushes.
struct Shelf: View {
    @Environment(MockPlayer.self) private var player
    let items: [BrowseItem]
    var tileWidth: CGFloat = BrowseMetrics.shelfTile

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    let width = item.isArtist ? BrowseMetrics.artistTile : tileWidth
                    if let route = item.route {
                        NavigationLink(value: route) { ItemTile(item: item, width: width) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(item.id)
                    } else if case .track(let track) = item {
                        Button { player.startMix(from: track) } label: { ItemTile(item: item, width: width) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(item.id)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, BrowseMetrics.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

/// Lower band of release/playlist pages: Apple switches to the grouped background here.
struct DetailFooter<Content: View>: View {
    let lines: [String]
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, BrowseMetrics.margin)
            content()
        }
        .padding(.top, 22)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Runs past the content end so the grouped band reaches the bottom edge (and overscroll).
        .background(alignment: .top) {
            Color(.secondarySystemBackground).frame(height: 2400)
        }
    }
}

func durationSummary(_ tracks: [Track]) -> String {
    let minutes = Int((tracks.reduce(0) { $0 + ($1.duration ?? 0) } / 60).rounded())
    return "\(tracks.count)곡, \(minutes)분"
}
