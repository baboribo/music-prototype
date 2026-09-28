import SwiftUI

@main
struct MusicPrototypeApp: App {
    @State private var player: MockPlayer
    @State private var searchHistory = SearchHistory()
    @State private var changes: CatalogChanges
    private let catalog: any MusicCatalog

    init() {
        let catalog = LiveMusicCatalog.fromEnvironment() ?? MockMusicCatalog()
        let changes = CatalogChanges()
        self.catalog = catalog
        _changes = State(initialValue: changes)
        _player = State(initialValue: MockPlayer(catalog: catalog, changes: changes))
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(player)
                .environment(searchHistory)
                .environment(changes)
                .environment(\.musicCatalog, catalog)
                .tint(.indigo)
        }
    }
}
