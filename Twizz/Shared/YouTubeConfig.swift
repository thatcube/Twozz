import Foundation

/// Shared YouTube OAuth/device-flow configuration, read from the app's Info.plist
/// (populated from `Config/YouTubeSecrets.xcconfig.local`). Centralizes the
/// client credentials and endpoints so the auth session and subscriptions
/// service share one source of truth.
enum YouTubeConfig {
  /// OAuth scope needed to read the signed-in viewer's subscriptions.
  static let readonlyScope = "https://www.googleapis.com/auth/youtube.readonly"

  static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
  static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  static let apiBaseURL = URL(string: "https://www.googleapis.com/youtube/v3")!

  /// A single reused decoder for YouTube Data API / OAuth responses. Mirrors
  /// `TwitchAPIClient.sharedDecoder`: the YouTube services check the HTTP status
  /// themselves and then decode the body, so they can reuse one decoder instead
  /// of allocating a fresh `JSONDecoder()` per response. Holds only immutable
  /// configuration and is safe to read concurrently while decoding value types.
  nonisolated(unsafe) static let sharedDecoder = JSONDecoder()

  /// The OAuth client ID, or nil when the secret hasn't been configured (so the
  /// app can hide YouTube sign-in instead of failing). Guards against the
  /// unresolved `$(YOUTUBE_CLIENT_ID)` placeholder when the local xcconfig is
  /// missing.
  static var clientID: String? {
    resolve("YOUTUBE_CLIENT_ID")
  }

  /// The OAuth client secret. Google's limited-input device flow uniquely
  /// requires the secret when exchanging the device code for tokens.
  static var clientSecret: String? {
    resolve("YOUTUBE_CLIENT_SECRET")
  }

  /// True when both client credentials are present, i.e. YouTube sign-in can run.
  static var isConfigured: Bool {
    clientID != nil && clientSecret != nil
  }

  private static func resolve(_ key: String) -> String? {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !trimmed.contains(key) else { return nil }
    return trimmed
  }
}

/// User preferences for the YouTube integration.
enum YouTubePreferences {
  /// `@AppStorage` key for the "Show YouTube subscriptions" toggle (default on).
  static let showSubscriptionsKey = PersistenceKey.showYouTubeSubscriptions
}
