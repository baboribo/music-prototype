import SwiftUI

@main
struct MusicPrototypeApp: App {
    @State private var player = MockPlayer()
    @State private var library = MockLibrary()
    @State private var searchHistory = SearchHistory()
    private let catalog: any MusicCatalog = LiveMusicCatalog.fromEnvironment() ?? MockMusicCatalog()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(player)
                .environment(library)
                .environment(searchHistory)
                .environment(\.musicCatalog, catalog)
                .tint(.indigo)
        }
    }
}
