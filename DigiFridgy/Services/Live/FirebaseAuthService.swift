import Foundation
import FirebaseAuth

final class FirebaseAuthService: AuthService {
    private var auth: Auth { Auth.auth() }

    var currentUser: AuthUser? { auth.currentUser.map(Self.map) }

    var supportsEmail: Bool { true }

    /// Firebase ID token (auto-refreshed by the SDK). SpacetimeDB accepts it as an OIDC token and derives
    /// the user's Identity from its `iss` (https://securetoken.google.com/<project>) and `sub` (uid).
    func idToken() async throws -> String? {
        guard let user = auth.currentUser else { return nil }
        return try await user.getIDToken()
    }

    func signInAnonymously() async throws -> AuthUser {
        let result = try await auth.signInAnonymously()
        return Self.map(result.user)
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        let result = try await auth.signIn(withEmail: email, password: password)
        return Self.map(result.user)
    }

    func signUp(email: String, password: String) async throws -> AuthUser {
        let result = try await auth.createUser(withEmail: email, password: password)
        return Self.map(result.user)
    }

    func linkEmail(email: String, password: String) async throws -> AuthUser {
        guard let user = auth.currentUser else { throw AuthServiceError.notSignedIn }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        let result = try await user.link(with: credential)
        return Self.map(result.user)
    }

    func signOut() throws {
        try auth.signOut()
    }

    private static func map(_ user: User) -> AuthUser {
        AuthUser(uid: user.uid, email: user.email, isAnonymous: user.isAnonymous)
    }
}

nonisolated enum AuthServiceError: LocalizedError {
    case notSignedIn
    case invalidCredentials
    case emailUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You're not signed in."
        case .invalidCredentials: "Enter a valid email and a password of at least 6 characters."
        case .emailUnavailable: "Email sign-in needs Firebase. Add GoogleService-Info.plist to enable it."
        }
    }
}
