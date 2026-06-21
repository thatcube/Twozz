import Foundation
import Observation

@MainActor
@Observable
final class TwitchAuthSession {
    private static let disallowedClientIDs: Set<String> = [
        // Twitch web public client. Using this shows "Twilight" on consent
        // and may not reliably authorize Helix followed-channel endpoints.
        TwitchConfig.webPublicClientID
    ]
    static let twitchGraphQLPublicClientID = TwitchConfig.webPublicClientID

    var isAuthenticated = false
    var userID: String?
    var userLogin: String?
    var userDisplayName: String?
    var profileImageURL: URL?
    var accessToken: String?
    var refreshToken: String?

    var isAuthenticating = false
    var activationCode: String?
    var verificationURI: String?
    var verificationURIComplete: String?
    var statusMessage: String?
    var errorMessage: String?

    let userDefaults: UserDefaults = {
        guard let suite = UserDefaults(suiteName: TopShelf.appGroupID) else {
            return .standard
        }
        TwitchAuthSession.migrateLegacyAuthIfNeeded(into: suite)
        return suite
    }()
    var pollTask: Task<Void, Never>?
    var broadcasterIDCache: [String: String] = [:]
    /// Coalesces concurrent token refreshes into a single in-flight request.
    /// Twitch refresh tokens are single-use, so two callers refreshing at once
    /// would each spend the same token and the loser would be rejected with
    /// `invalid_grant`, needlessly tearing down the session.
    var refreshInFlight: Task<String, Error>?

    var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_CLIENT_ID") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("$(") || trimmed.contains("TWITCH_CLIENT_ID") {
            return nil
        }
        return trimmed
    }

    var clientIDValidationIssue: String? {
        guard let clientID else {
            return "Missing Twitch client ID. Set TWITCH_CLIENT_ID in Config/TwitchSecrets.xcconfig.local."
        }

        if Self.disallowedClientIDs.contains(clientID.lowercased()) {
            return "TWITCH_CLIENT_ID is set to a public Twitch web client ID (shows as \"Twilight\"). Create your own app in the Twitch Developer Console and use that Client ID."
        }

        return nil
    }

    var requestedScopes: [String] {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_OAUTH_SCOPES") as? String {
            let pieces = raw
                .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !pieces.isEmpty {
                return Array(NSOrderedSet(array: pieces)) as? [String] ?? pieces
            }
        }

        return [
            // Read the signed-in user's followed channels.
            "user:read:follows",
            // Read chat messages (Helix / EventSub) and via IRC.
            "user:read:chat",
            "chat:read",
            // Send chat messages (Helix Send Chat Message) and via IRC.
            "user:write:chat",
            "chat:edit"
        ]
    }

    enum StorageKey {
        static let accessToken = PersistenceKey.twitchAccessToken
        static let refreshToken = PersistenceKey.twitchRefreshToken
        static let userID = PersistenceKey.twitchUserID
        static let clientID = PersistenceKey.twitchClientID
        static let userLogin = PersistenceKey.twitchUserLogin
        static let userDisplayName = PersistenceKey.twitchUserDisplayName
        static let profileImageURL = PersistenceKey.twitchProfileImageURL
    }

    /// One-time copy of any auth previously stored in `UserDefaults.standard`
    /// into the shared App Group suite. Auth now lives in the App Group so the
    /// Top Shelf extension can read it (and write back refreshed tokens). Without
    /// this migration, already-signed-in users would appear signed out after the
    /// switch. The legacy values are left in place harmlessly.
    private static func migrateLegacyAuthIfNeeded(into suite: UserDefaults) {
        guard suite.string(forKey: PersistenceKey.twitchAccessToken) == nil else { return }
        let legacy = UserDefaults.standard
        let keys = [
            PersistenceKey.twitchAccessToken,
            PersistenceKey.twitchRefreshToken,
            PersistenceKey.twitchUserID,
            PersistenceKey.twitchUserLogin,
            PersistenceKey.twitchUserDisplayName,
            PersistenceKey.twitchProfileImageURL
        ]
        for key in keys {
            if let value = legacy.string(forKey: key) {
                suite.set(value, forKey: key)
            }
        }
    }

    func restore() {
        if let issue = clientIDValidationIssue {
            clearStoredAuthState()
            statusMessage = nil
            errorMessage = issue
            return
        }

        accessToken = userDefaults.string(forKey: StorageKey.accessToken)
        refreshToken = userDefaults.string(forKey: StorageKey.refreshToken)
        userID = userDefaults.string(forKey: StorageKey.userID)
        userLogin = userDefaults.string(forKey: StorageKey.userLogin)
        userDisplayName = userDefaults.string(forKey: StorageKey.userDisplayName)
        profileImageURL = userDefaults.string(forKey: StorageKey.profileImageURL).flatMap(URL.init(string:))
        isAuthenticated = accessToken != nil && userID != nil
        statusMessage = nil
        errorMessage = nil

        // Mirror the client id into the shared App Group suite so the Top Shelf
        // extension can perform its own Helix requests for fresh live streams.
        if isAuthenticated, let clientID {
            userDefaults.set(clientID, forKey: StorageKey.clientID)
        }
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil

        isAuthenticated = false
        isAuthenticating = false
        accessToken = nil
        refreshToken = nil
        userID = nil
        userLogin = nil
        userDisplayName = nil
        profileImageURL = nil
        activationCode = nil
        verificationURI = nil
        verificationURIComplete = nil
        statusMessage = nil
        errorMessage = nil

        userDefaults.removeObject(forKey: StorageKey.accessToken)
        userDefaults.removeObject(forKey: StorageKey.refreshToken)
        userDefaults.removeObject(forKey: StorageKey.userID)
        userDefaults.removeObject(forKey: StorageKey.clientID)
        userDefaults.removeObject(forKey: StorageKey.userLogin)
        userDefaults.removeObject(forKey: StorageKey.userDisplayName)
        userDefaults.removeObject(forKey: StorageKey.profileImageURL)

        // Drop cached per-channel emote/badge/cheermote catalogs so a new
        // session starts clean rather than reusing the prior viewer's caches.
        Task {
            await EmoteCatalogService.shared.clear()
            await BadgeCatalogService.shared.clear()
            await CheermoteCatalogService.shared.clear()
        }
    }

    func clearStoredAuthState() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        userLogin = nil
        userDisplayName = nil
        profileImageURL = nil
        isAuthenticated = false
        isAuthenticating = false

        userDefaults.removeObject(forKey: StorageKey.accessToken)
        userDefaults.removeObject(forKey: StorageKey.refreshToken)
        userDefaults.removeObject(forKey: StorageKey.userID)
        userDefaults.removeObject(forKey: StorageKey.clientID)
        userDefaults.removeObject(forKey: StorageKey.userLogin)
        userDefaults.removeObject(forKey: StorageKey.userDisplayName)
        userDefaults.removeObject(forKey: StorageKey.profileImageURL)
    }

    func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    func normalizedOAuthMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        return message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    func makeHTTPError(context: String, status: Int, data: Data) -> TwitchAuthHTTPError {
        let payload = try? TwitchAPIClient.decode(TwitchAuthAPIErrorPayload.self, from: data)
        let message = payload?.message ?? payload?.error ?? String(data: data, encoding: .utf8)
        return TwitchAuthHTTPError(context: context, status: status, message: message)
    }

    func isInvalidRefreshError(_ error: TwitchAuthHTTPError) -> Bool {
        guard error.status == 400 || error.status == 401 else { return false }
        guard let normalized = normalizedOAuthMessage(error.message) else { return false }
        return normalized.contains("invalid_refresh_token") || normalized.contains("invalid_grant")
    }

    func isInvalidClientIDError(_ error: TwitchAuthHTTPError) -> Bool {
        guard error.status == 400 else { return false }
        guard let normalized = normalizedOAuthMessage(error.message) else { return false }
        return normalized.contains("client_id") && normalized.contains("invalid")
    }

    func isIntegrityCheckFailureMessage(_ message: String?) -> Bool {
        guard let normalized = normalizedOAuthMessage(message) else { return false }
        return normalized.contains("integrity_check") && normalized.contains("fail")
    }

    func describe(_ error: Error) -> String {
        if let authError = error as? TwitchAuthHTTPError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }

    func validAccessToken() async throws -> String {
        if let accessToken {
            return accessToken
        }
        return try await refreshAccessTokenIfNeeded(force: true)
    }

    func withUserTokenRefreshRetry<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let accessToken = try await validAccessToken()
        do {
            return try await operation(accessToken)
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
            let refreshedAccessToken = try await refreshAccessTokenIfNeeded(force: true)
            return try await operation(refreshedAccessToken)
        }
    }

}

/// Credentials required to open an EventSub WebSocket and create subscriptions
/// for the signed-in user.
struct TwitchEventSubCredentials: Equatable {
    let clientID: String
    let accessToken: String
    let userID: String
}

enum FollowActionError: LocalizedError {
    case notSignedIn
    case integrityCheckRequired
    case mutationFailed(reason: String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to follow channels."
        case .integrityCheckRequired:
            return "Twitch blocked follow/unfollow from this app (integrity check required). Use the Twitch app or website to change follows."
        case .mutationFailed(let reason):
            if let reason, !reason.isEmpty {
                return "Couldn't update follow: \(reason)."
            }
            return "Couldn't update follow right now."
        }
    }
}

enum ChatSendError: LocalizedError {
    case notSignedIn
    case channelNotFound
    case dropped(reason: String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to send messages."
        case .channelNotFound:
            return "Couldn't find that channel."
        case .dropped(let reason):
            if let reason, !reason.isEmpty {
                return "Message not sent: \(reason)."
            }
            return "Message not sent."
        }
    }
}

private struct TwitchAuthAPIErrorPayload: Decodable {
    let status: Int?
    let message: String?
    let error: String?
}

struct TwitchAuthHTTPError: LocalizedError {
    let context: String
    let status: Int
    let message: String?

    var errorDescription: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "\(context): \(trimmed) (HTTP \(status))"
        }
        return "\(context) failed (HTTP \(status))"
    }
}
