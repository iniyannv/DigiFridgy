import Foundation
import FirebaseAuth

final class FirebaseAuthService: AuthService {
    private var auth: Auth { Auth.auth() }

    var currentUser: AuthUser? { auth.currentUser.map(Self.map) }

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

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You're not signed in."
        case .invalidCredentials: "Enter a valid email and a password of at least 6 characters."
        }
    }
}
