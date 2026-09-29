import SwiftUI

/// How the app signs in and out. Implemented by the service layer; the UI only sees `AccountSession`.
@MainActor
protocol AccountBackend: AnyObject {
    func isSignedIn() async -> Bool
    /// App-local sign-out.
    func signOut() async
    /// The sign-in UI closed: the session may be new.
    func sessionMayHaveChanged() async
    func signInView() -> AnyView
}

/// The signed-in state as the UI sees it.
@MainActor
@Observable
final class AccountSession {
    enum State: Equatable {
        case checking
        case signedIn
        case signedOut
        /// Development sources (session file, replay, fixtures): no in-app sign-in.
        case unmanaged
    }

    private(set) var state: State
    /// Changes when the signed-in session changes (sign-in, sign-out): account data on screen must reload.
    private(set) var generation = 0
    var isPresentingSignIn = false
    private let backend: (any AccountBackend)?

    init(backend: (any AccountBackend)?) {
        self.backend = backend
        state = backend == nil ? .unmanaged : .checking
    }

    var canSignIn: Bool { backend != nil }

    func refresh() async {
        guard let backend else { return }
        state = await backend.isSignedIn() ? .signedIn : .signedOut
    }

    func presentSignIn() {
        guard canSignIn else { return }
        isPresentingSignIn = true
    }

    func signInView() -> AnyView { backend?.signInView() ?? AnyView(EmptyView()) }

    /// After the sign-in sheet closes: re-read the session; a new sign-in reloads account data.
    func signInClosed() async {
        guard let backend else { return }
        let before = state
        await backend.sessionMayHaveChanged()
        await refresh()
        if state == .signedIn, before != .signedIn { generation += 1 }
    }

    func signOut() async {
        guard let backend else { return }
        await backend.signOut()
        state = .signedOut
        generation += 1
    }

    /// The service rejected the session (sign-out elsewhere, expiry).
    func sessionRejected() {
        guard backend != nil else { return }
        state = .signedOut
    }
}

/// A failed load as views show it: the message, and whether signing in would help.
struct LoadFailure: Sendable {
    let message: String
    let needsSignIn: Bool

    init(_ error: any Error) {
        message = error.localizedDescription
        if case CatalogError.signedOut = error { needsSignIn = true } else { needsSignIn = false }
    }
}
