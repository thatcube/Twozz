import Foundation

/// The minimum Twitch credentials the Top Shelf extension needs to fetch fresh
/// live streams at render time.
struct TopShelfCredentials: Equatable {
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var userID: String
}

/// Shares Twitch credentials between the main app and the Top Shelf extension
/// through the App Group `UserDefaults` suite.
///
/// The extension runs in a separate process and cannot see the app's in-memory
/// auth state, so the app mirrors these credentials into the shared suite. The
/// suite is the single source of truth: when the extension refreshes an expired
/// access token it writes the new tokens back here, and the app reads them on
/// its next launch. Keeping one store avoids refresh-token rotation conflicts
/// between the two processes.
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
            refreshToken: nonEmpty(defaults.string(forKey: refreshTokenKey)),
            userID: userID
        )
    }

    /// Persists refreshed access/refresh tokens (e.g. after the extension
    /// refreshes an expired token) so the app adopts them on its next launch.
    static func updateTokens(accessToken: String, refreshToken: String?) {
        let defaults = defaults
        defaults.set(accessToken, forKey: accessTokenKey)
        if let refreshToken = nonEmpty(refreshToken) {
            defaults.set(refreshToken, forKey: refreshTokenKey)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
