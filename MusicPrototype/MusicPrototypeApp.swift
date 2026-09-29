import SwiftUI

@main
struct MusicPrototypeApp: App {
    @State private var player: MockPlayer
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
        _player = State(initialValue: MockPlayer(catalog: catalog, actions: actions))
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
