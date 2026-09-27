import SwiftUI

private enum AppTab: Hashable {
    case home, library, search
}

struct AppShell: View {
    @Environment(MockPlayer.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPrefersCrossFadeTransitions) private var prefersCrossFade
    @State private var selectedTab: AppTab = .home
    @State private var homePath: [Route] = []
    @State private var libraryPath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .catalog
    @State private var showingPlayer = false
    @State private var playerMode: PlayerMode = .artwork
    @State private var playerTransition = InteractivePlayerContext()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView().browseDestinations()
                }
                .environment(\.browseNavigate) { homePath.append($0) }
            }
            Tab("Library", systemImage: "square.stack", value: .library) {
                NavigationStack(path: $libraryPath) {
                    LibraryView().browseDestinations()
                }
                .environment(\.browseNavigate) { libraryPath.append($0) }
            }
            Tab(value: .search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(query: searchText, scope: searchScope).browseDestinations()
                }
                .environment(\.browseNavigate) { searchPath.append($0) }
                // Scope search to this destination. On iOS 27, TabView-wide
                // search left an extra field in Library after cancellation.
                .searchable(text: $searchText, prompt: "노래, 아티스트, 앨범")
                // Both reference apps scope search to the catalog or the user's library.
                .searchScopes($searchScope, activation: .onSearchPresentation) {
                    Text("YouTube Music").tag(SearchScope.catalog)
                    Text("보관함").tag(SearchScope.library)
                }
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: player.currentTrack != nil) {
            MiniPlayer {
                showingPlayer = true
            }
            .environment(\.interactivePlayerTransitionContext, playerTransition)
            .background(InteractivePlayerSourceAnchor(context: playerTransition))
        }
        .background {
            InteractivePlayerPresenter(
                isPresented: $showingPlayer,
                context: playerTransition,
                reduceMotion: reduceMotion || prefersCrossFade
            ) {
                FullPlayer(mode: $playerMode, closePlayer: playerTransition.dismiss)
                    .environment(player)
                    .environment(\.colorScheme, .dark)
                    .environment(\.interactivePlayerTransitionContext, playerTransition)
            }
        }
    }
}
