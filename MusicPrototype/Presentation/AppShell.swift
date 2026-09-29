import SwiftUI

private enum AppTab: Hashable {
    case home, library, search
}

struct AppShell: View {
    @Environment(MockPlayer.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(AccountSession.self) private var account
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

    private var failureShown: Binding<Bool> {
        Binding(get: { actions.failure != nil }, set: { if !$0 { actions.failure = nil } })
    }

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
        // A new sign-in or a sign-out: account data on screen belongs to the previous session.
        .id(account.generation)
        .onChange(of: account.generation) {
            homePath = []
            libraryPath = []
            searchPath = []
        }
        .task { await account.refresh() }
        .sheet(isPresented: Bindable(account).isPresentingSignIn, onDismiss: { Task { await account.signInClosed() } }) {
            NavigationStack {
                account.signInView()
                    .navigationTitle("YouTube Music 로그인")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("완료") { account.isPresentingSignIn = false }
                        }
                    }
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        // A write that failed has already been undone on screen; say so once.
        .alert(actions.failure?.title ?? "", isPresented: failureShown, presenting: actions.failure) { _ in
            Button("확인", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .sensoryFeedback(.error, trigger: actions.failure?.id) { _, new in new != nil }
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
