import Foundation
import Observation
import OSLog

/// Every account write goes through here: the change shows at once, a second tap waits
/// for the write in flight, a failure restores the previous state and is reported once,
/// and a success invalidates only the scopes the catalog says it changed.
@MainActor
@Observable
final class LibraryActions {
    /// What a write changes, for the state views show.
    enum Key: Hashable {
        case like(Track.ID)
        case save(listID: String)
        case songInLibrary(Track.ID)
        /// `BrowseItem.id` / `QuickPick.id` of the pinned item.
        case pin(itemID: String)

        /// For logs: the kind only, no ids or tokens.
        var kind: String {
            switch self {
            case .like: "like"
            case .save: "save"
            case .songInLibrary: "songInLibrary"
            case .pin: "pin"
            }
        }
    }

    /// A write that failed and was undone, for the alert.
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var failure: Failure?
    /// Written states that views show over what their (older) data says.
    private var written: [Key: Bool] = [:]
    private var inFlight: Set<Key> = []

    private let catalog: any MusicCatalog
    private let changes: CatalogChanges
    private static let log = Logger(subsystem: "MusicPrototype", category: "Write")

    init(catalog: any MusicCatalog, changes: CatalogChanges) {
        self.catalog = catalog
        self.changes = changes
    }

    /// The state to show: the last write this session, else what the data said.
    func value(_ key: Key, given data: Bool?) -> Bool? {
        written[key] ?? data
    }

    func isWriting(_ key: Key) -> Bool { inFlight.contains(key) }

    /// Shows `value` for `key` and applies `edit` (built by the view from the item's own
    /// response). `current` is what was shown before the tap.
    func perform(_ edit: LibraryEdit, showing value: Bool, for key: Key, from current: Bool?, failureTitle: String) {
        guard !inFlight.contains(key) else { return }
        Self.log.info("write \(key.kind, privacy: .public) → \(value)")
        let previous = written[key]
        written[key] = value
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            do {
                changes.invalidate(try await catalog.apply(edit))
            } catch {
                written[key] = previous ?? current
                Self.log.error("write failed, reverted: \(error.localizedDescription, privacy: .public)")
                failure = Failure(title: failureTitle, message: error.localizedDescription)
            }
        }
    }
}
