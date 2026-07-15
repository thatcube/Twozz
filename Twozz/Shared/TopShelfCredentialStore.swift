import Foundation

/// The minimum Twitch credentials the Top Shelf extension needs to fetch fresh
/// live streams at render time.
struct TopShelfCredentials: Equatable {
    var clientID: String
    var accessToken: String
    var userID: String
}

/// Shares read-only Twitch credentials from the main app to Top Shelf through
/// the App Group `UserDefaults` suite.
///
/// The extension runs in a separate process and cannot see the app's in-memory
/// auth state. Only the main app rotates refresh tokens: an extension can be
/// terminated after Twitch spends a refresh token but before persistence, which
/// would irrecoverably lose the replacement token.
enum TopShelfCredentialStore {
    // Canonical key strings. `TwitchAuthSession` references these so the app and
    // the extension always read and write the same `UserDefaults` entries.
    static let clientIDKey = "twitch.auth.clientID"
    static let accessTokenKey = "twitch.auth.accessToken"
    static let refreshTokenKey = "twitch.auth.refreshToken"
    static let userIDKey = "twitch.auth.userID"

    /// Shared App Group defaults. Falls back to `.standard` only if the suite is
    /// somehow unavailable (entitlement inactive), which keeps the app working.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: TopShelf.appGroupID) ?? .standard
    }

    /// Returns the shared credentials, or `nil` when the user is not signed in
    /// (no access token / user id) or the client id has not been mirrored yet.
    static func load() -> TopShelfCredentials? {
        let defaults = defaults
        guard let clientID = nonEmpty(defaults.string(forKey: clientIDKey)),
              let accessToken = nonEmpty(defaults.string(forKey: accessTokenKey)),
              let userID = nonEmpty(defaults.string(forKey: userIDKey))
        else { return nil }

        return TopShelfCredentials(
            clientID: clientID,
            accessToken: accessToken,
            userID: userID
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
