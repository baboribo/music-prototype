import Foundation
import OSLog
import SwiftUI

/// Which data and session sources the app runs on, decided once at launch.
///
/// - default: the app's WebKit session (in-app sign-in).
/// - `YTM_SESSION_FILE`: a browser session file outside the repository (development).
/// - `YTM_REPLAY_DIR` (debug builds): recorded responses, no requests.
/// - `YTM_MOCK=1`: fixtures.
@MainActor
struct AppServices {
    let catalog: any MusicCatalog
    let account: AccountSession
    /// The signed-in session, when there is one to use (browse data and, later, playback).
    let credentials: SessionCredentialStore?

    private static let log = Logger(subsystem: "MusicPrototype", category: "InnerTube")

    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppServices {
        if environment["YTM_MOCK"] == "1" {
            return AppServices(catalog: MockMusicCatalog(), account: AccountSession(backend: nil), credentials: nil)
        }
        #if DEBUG
        if let directory = environment["YTM_REPLAY_DIR"], !directory.isEmpty {
            do {
                return AppServices(catalog: try LiveMusicCatalog.replay(directory: directory), account: AccountSession(backend: nil), credentials: nil)
            } catch {
                return failing(error)
            }
        }
        #endif
        if let path = environment["YTM_SESSION_FILE"], !path.isEmpty {
            do {
                _ = try ExternalFile.validate(path)
            } catch {
                return failing(error)
            }
            let store = SessionCredentialStore(source: .file(path))
            return AppServices(catalog: LiveMusicCatalog.live(store: store), account: AccountSession(backend: nil), credentials: store)
        }
        let session = WebKitSession()
        let store = SessionCredentialStore(source: .webKit(session))
        let account = AccountSession(backend: WebKitAccountBackend(session: session, store: store))
        Task {
            // The account state follows the server's verdict on any request.
            await store.setOnRejected { Task { @MainActor in account.sessionRejected() } }
        }
        return AppServices(catalog: LiveMusicCatalog.live(store: store), account: account, credentials: store)
    }

    private static func failing(_ error: any Error) -> AppServices {
        log.error("catalog source rejected: \(error.localizedDescription, privacy: .public)")
        return AppServices(catalog: LiveMusicCatalog.failing(error), account: AccountSession(backend: nil), credentials: nil)
    }
}

/// In-app sign-in on the app's WebKit store.
@MainActor
final class WebKitAccountBackend: AccountBackend {
    private let session: WebKitSession
    private let store: SessionCredentialStore

    init(session: WebKitSession, store: SessionCredentialStore) {
        self.session = session
        self.store = store
    }

    func isSignedIn() async -> Bool { await store.isSignedIn() }

    func signOut() async {
        await session.clear()
        await store.reset()
    }

    func sessionMayHaveChanged() async { await store.reset() }

    func signInView() -> AnyView { session.signInView() }
}
