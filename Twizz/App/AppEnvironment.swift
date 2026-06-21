import Foundation

/// App-level composition root.
///
/// Owns the long-lived, app-global services as a single injectable object so
/// their lifetime is bound to the *app* rather than to whichever screen happens
/// to be on-screen. Previously `HomeView` was the de-facto composition root: it
/// instantiated these services as `@State`, tying their lifetime to one view and
/// prop-drilling them into children. They now live here, are created once in
/// `TwizzApp`, and are injected into the view tree with `.environment(_:)`. Views
/// read them with `@Environment(AppEnvironment.self)`.
///
/// Only genuinely app-global services live here. Screen-scoped services (e.g.
/// `BrowseService`, `SearchService`, a channel page's profile/content services,
/// or a single player session's state) stay owned by their view, since their
/// lifetime is correctly bound to that screen.
///
/// Intentionally plain Swift + Observation with no tvOS-only APIs, so it can back
/// an iOS target later without modification.
@MainActor
@Observable
final class AppEnvironment {
  /// Twitch account / OAuth session.
  let auth = TwitchAuthSession()
  /// The viewer's followed channels (live + offline) and their liveness.
  let follows = FollowedChannelsService()
  /// Anonymous "popular / top streams" recommendations and categories.
  let recommendations = RecommendationsService()
  /// On-device personalized recommendations derived from follows + history.
  let personalized = PersonalizedRecommendationsService()
  /// On-device watch history feeding personalization.
  let watchHistory = WatchHistoryService()
  /// "Not interested" feedback used to filter recommendations.
  let feedback = RecommendationFeedbackService()
  /// Streamer affinity signals for personalization.
  let affinity = StreamerAffinityService()
  /// Twitch↔YouTube identity alias table for dual-platform streamers.
  let youtubeAliases = TwitchYouTubeAliasService()
  /// Public YouTube live snapshot used to merge YouTube presence into follows.
  let youtubeLive = YouTubeLiveSnapshotService()
  /// Anonymous watch-page scraper for live YouTube concurrent viewer counts,
  /// used to fill in counts the public snapshot ships as `nil`.
  let youtubeConcurrentViewers = YouTubeConcurrentViewersService()
  /// YouTube account / device-code session.
  let youtubeAuth = YouTubeAuthSession()
  /// The viewer's YouTube subscriptions.
  let youtubeSubscriptions = YouTubeSubscriptionsService()
  /// Resolves live presence for subscribed YouTube channels.
  let youtubeResolver = YouTubeLiveResolver()
  /// Active theme selection + palette resolution.
  let themeManager = ThemeManager()
  /// Watches followed channels for "just went live" toasts.
  let goLive = GoLiveWatcher()
  /// Per-channel go-live notification opt-outs.
  let goLiveSettings = GoLiveNotificationSettings()

  init() {}
}
