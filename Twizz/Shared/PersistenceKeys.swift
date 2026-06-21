import Foundation

/// The single catalog of every `UserDefaults` key the app persists under.
///
/// Persistence used to be scattered across services and models as one-off string
/// literals and private `storageKey`/`etagDefaultsKey` constants, which made key
/// collisions and typos possible and hid the full list of what the app stores.
/// This namespace gathers all of them in one place.
///
/// **Do not change any string value here.** Existing installs already hold data
/// under these exact keys; changing a literal silently orphans that data. This is
/// a readability/safety refactor, not a data migration. The Twitch credential
/// keys that are shared with the Top Shelf extension intentionally reference
/// `TopShelfCredentialStore` so their strings live in exactly one place and stay
/// byte-for-byte identical across the app and the extension.
///
/// Plain Foundation/Swift so it stays portable (e.g. to an iOS companion app).
enum PersistenceKey {
  // MARK: Twitch auth — shared App Group suite (`TopShelf.appGroupID`)

  /// Mirrored to the App Group so the Top Shelf extension can read them. The four
  /// credential keys are defined in `TopShelfCredentialStore` (shared with the
  /// extension) and referenced here to avoid duplicating the literals.
  static let twitchAccessToken = TopShelfCredentialStore.accessTokenKey  // "twitch.auth.accessToken"
  static let twitchRefreshToken = TopShelfCredentialStore.refreshTokenKey  // "twitch.auth.refreshToken"
  static let twitchUserID = TopShelfCredentialStore.userIDKey  // "twitch.auth.userID"
  static let twitchClientID = TopShelfCredentialStore.clientIDKey  // "twitch.auth.clientID"
  static let twitchUserLogin = "twitch.auth.userLogin"
  static let twitchUserDisplayName = "twitch.auth.userDisplayName"
  static let twitchProfileImageURL = "twitch.auth.profileImageURL"

  // MARK: YouTube auth — shared App Group suite (`TopShelf.appGroupID`)

  static let youTubeAccessToken = "youtube.auth.accessToken"
  static let youTubeRefreshToken = "youtube.auth.refreshToken"
  static let youTubeTokenExpiry = "youtube.auth.expiry"

  // MARK: On-device personalization (standard suite)

  static let watchHistoryEntries = "watchHistoryEntriesV1"
  static let recommendationFeedback = "recommendationFeedbackV1"
  static let personalizedRecommendationsEnabled = "personalizedRecommendationsEnabled"

  // MARK: Go-live toasts (standard suite)

  static let goLiveNotificationsEnabled = "goLiveNotificationsEnabled"
  static let goLiveMutedChannels = "goLiveMutedChannelsV1"

  // MARK: Directory cache freshness — HTTP ETag + last-fetch timestamps

  static let kickAliasETag = "kickAliasETag"
  static let kickAliasLastFetch = "kickAliasLastFetch"
  static let youTubeLiveETag = "youTubeLiveETag"
  static let youTubeLiveLastFetch = "youTubeLiveLastFetch"
  static let streamerAffinityETag = "streamerAffinityETag"
  static let streamerAffinityLastFetch = "streamerAffinityLastFetch"
  static let twitchYouTubeAliasETag = "twitchYouTubeAliasETag"
  static let twitchYouTubeAliasLastFetch = "twitchYouTubeAliasLastFetch"
  static let youTubeSubscriptionsLastFetch = "youTubeSubscriptionsLastFetch"

  // MARK: Appearance & display preferences (also bound via `@AppStorage` in views)

  static let appTheme = "appTheme"
  static let streamCardSize = "streamCardSize"
  static let streamLanguageFilter = "streamLanguageFilter"
  static let showYouTubeSubscriptions = "showYouTubeSubscriptions"

  // MARK: Experimental playback toggles (also bound via `@AppStorage` in views)

  static let lowLatencyProxyEnabled = "lowLatencyProxyEnabled"
  static let streamRewindEnabled = "streamRewindEnabled"

  // MARK: Chat appearance migration — one-time legacy→numeric conversion

  static let chatAppearanceMigratedV1 = "chatAppearanceMigratedV1"
  static let chatTextSizeValue = "chatTextSizeValue"
  static let chatTextSizeLegacy = "chatTextSize"
  static let chatLineHeightValue = "chatLineHeightValue"
  static let chatLineHeightLegacy = "chatLineHeight"
  static let chatMessageSpacingValue = "chatMessageSpacingValue"
  static let chatLineSpacingLegacy = "chatLineSpacing"
  static let chatWidthValue = "chatWidthValue"
  static let chatWidthModeLegacy = "chatWidthMode"

  // MARK: Settings view bindings (also bound via `@AppStorage` in views)

  static let showChatByDefault = "showChatByDefault"
  static let disableLiquidGlass = "disableLiquidGlass"
}

/// Small typed helpers that wrap the `JSONEncoder`/`JSONDecoder` round-trip used
/// to persist Codable models in `UserDefaults`, replacing the duplicated
/// load/persist boilerplate that several services carried.
enum Defaults {
  /// Decodes a Codable value previously stored with ``save(_:forKey:to:)``.
  /// Returns `nil` when nothing is stored or the data can't be decoded.
  static func load<T: Decodable>(
    _ type: T.Type = T.self,
    forKey key: String,
    from defaults: UserDefaults = .standard
  ) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  /// Encodes and stores a Codable value as `Data`. Silently no-ops if encoding
  /// fails (matching the prior `try?`-based call sites).
  static func save<T: Encodable>(
    _ value: T,
    forKey key: String,
    to defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }
}
