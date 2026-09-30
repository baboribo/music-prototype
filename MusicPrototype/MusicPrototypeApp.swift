import SwiftUI

@main
struct MusicPrototypeApp: App {
    @State private var player: PlayerModel
    @State private var searchHistory = SearchHistory()
    @State private var changes: CatalogChanges
    @State private var actions: LibraryActions
    @State private var account: AccountSession
    private let catalog: any MusicCatalog

    init() {
        let services = AppServices.make()
        let catalog = services.catalog
        let changes = CatalogChanges()
        self.catalog = catalog
        _account = State(initialValue: services.account)
        let actions = LibraryActions(catalog: catalog, changes: changes)
        _changes = State(initialValue: changes)
        _actions = State(initialValue: actions)
        // Real audio needs a signed-in session; fixtures and recorded responses stay silent.
        let engine: any PlaybackEngine = if let credentials = services.credentials {
            NativeAudioEngine(resolver: PlaybackResolver(credentials: credentials, playerJS: WebPlayerJSProvider(),
                                                         solver: JSCSolver(release: .ejs080)))
        } else {
            SilentPlaybackEngine()
        }
        _player = State(initialValue: PlayerModel(catalog: catalog, actions: actions, engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(player)
                .environment(searchHistory)
                .environment(changes)
                .environment(actions)
                .environment(account)
                .environment(\.musicCatalog, catalog)
                .tint(.indigo)
        }
    }
}
