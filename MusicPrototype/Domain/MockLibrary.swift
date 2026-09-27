import Observation

/// Session-only "saved to library" flags; never writes to a service.
@MainActor
@Observable
final class MockLibrary {
    private var savedIDs: Set<String> = Set(Catalog.libraryReleases.map(\.id) + Catalog.libraryPlaylists.map(\.id))

    func contains(_ id: String) -> Bool { savedIDs.contains(id) }

    func toggle(_ id: String) {
        if savedIDs.contains(id) { savedIDs.remove(id) } else { savedIDs.insert(id) }
    }
}
