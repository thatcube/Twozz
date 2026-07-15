import Foundation
import Observation

/// Public facade for the signed-in viewer's followed channels.
///
/// Owns the observable state that the UI binds to (the live "Following" rail,
/// the full Following directory, the follow-category profile, plus loading and
/// error flags) and the orchestration that decides *when* to fetch live data,
/// fall back to demo/trending content, refresh expired tokens, or enrich with
/// YouTube presence. The heavy lifting is delegated to focused, Foundation-only
/// collaborators so this type stays a thin coordinator:
///
/// - `FollowedChannelsFetcher` — every Twitch Helix round-trip plus decode and
///   model mapping.
/// - `FollowedChannelsDemoProvider` — anonymous trending + hand-curated demo
///   channels used as fallbacks.
/// - `FollowedChannelsAvatarPrewarmer` — best-effort avatar image prewarming.
///
/// The public surface (type name, observable properties, and the `refresh`,
/// `loadDirectory`, and `applyYouTubePresence` methods) is unchanged.
@MainActor
@Observable
final class FollowedChannelsService {
  private static let disallowedClientIDs: Set<String> = [
    // Twitch web public client. Device flow consent appears as "Twilight"
    // and followed-channel APIs can fail unexpectedly.
    TwitchConfig.webPublicClientID
  ]

  private let fetcher = FollowedChannelsFetcher()
  private let demoProvider = FollowedChannelsDemoProvider()
  private let avatarPrewarmer = FollowedChannelsAvatarPrewarmer()

  private(set) var channels: [FollowedChannel] = [] {
    didSet { avatarPrewarmer.prewarm(channels) }
  }
  /// Category name -> number of followed channels (online **and** offline) whose
  /// last/current broadcast was in that category. Drives the personalized
  /// recommendation profile so it reflects the whole follow list, not just whoever
  /// happens to be live. Empty in demo mode or when the lookup fails.
  private(set) var followedCategories: [String: Int] = [:]
  /// Lowercased logins of every channel the viewer follows (online and offline),
  /// used to guarantee recommendations never include someone they already follow —
  /// even a live follow beyond the first page of `/streams/followed`.
  private(set) var followedLogins: Set<String> = []
  private(set) var isLoading = false
  private(set) var isUsingDemoData = false
  private(set) var errorMessage: String?
  private(set) var lastUpdatedAt: Date?

  /// The full "Following" directory — every channel the viewer follows, live
  /// **and** offline — sorted live-first. Populated lazily by `loadDirectory`
  /// when the directory screen opens, so its heavier multi-batch fetch never
  /// runs as part of the Home refresh.
  private(set) var directory: [FollowedChannel] = [] {
    didSet { avatarPrewarmer.prewarm(directory) }
  }
  private(set) var isLoadingDirectory = false
  private(set) var directoryErrorMessage: String?
  private(set) var directoryLoadedAt: Date?

  /// Merges live YouTube presence into the current Twitch-followed channels and
  /// directory so a dual-platform streamer shows as one card with both Twitch
  /// and YouTube viewers. Called after `refresh`/`loadDirectory` from the view
  /// layer, which owns the (downloaded, parameter-free) alias + snapshot
  /// services. A streamer with no known YouTube mapping, or who isn't currently
  /// live on YouTube, has its `youtube` presence cleared so stale data never
  /// lingers.
  func applyYouTubePresence(
    aliases: TwitchYouTubeAliasService,
    live: YouTubeLiveSnapshotService
  ) {
    func enrich(_ channel: FollowedChannel) -> FollowedChannel {
      var updated = channel
      if let channelID = aliases.youtubeChannelID(forTwitchLogin: channel.login),
        let presence = live.presence(forChannelID: channelID),
        presence.isLive {
        updated.youtube = presence
      } else {
        updated.youtube = nil
      }
      return updated
    }

    channels = channels.map(enrich)
    if !directory.isEmpty {
      directory = directory.map(enrich)
    }
  }

  func refresh(using auth: TwitchAuthSession) async {
    isLoading = true
    errorMessage = nil

    defer {
      isLoading = false
      lastUpdatedAt = Date()
    }

    guard auth.isAuthenticated else {
      channels = await fetchDemoChannels()
      isUsingDemoData = true
      return
    }

    guard let clientID = resolveClientID() else {
      channels = await fetchDemoChannels()
      isUsingDemoData = true
      errorMessage =
        "Cannot load followed channels until TWITCH_CLIENT_ID is set in Config/TwitchSecrets.xcconfig.local."
      return
    }

    if Self.disallowedClientIDs.contains(clientID.lowercased()) {
      channels = await fetchDemoChannels()
      isUsingDemoData = true
      errorMessage =
        "TWITCH_CLIENT_ID is using a public Twitch web client (shows \"Twilight\"). Create your own Twitch app and use its Client ID to load followed channels."
      return
    }

    guard let userID = auth.userID
    else {
      channels = await fetchDemoChannels()
      isUsingDemoData = true
      return
    }

    let initialAccessToken: String
    if let accessToken = auth.accessToken {
      initialAccessToken = accessToken
    } else {
      do {
        initialAccessToken = try await auth.refreshAccessTokenIfNeeded(force: true)
      } catch {
        channels = await fetchDemoChannels()
        isUsingDemoData = true
        let detail = describe(error)
        errorMessage =
          "Could not load followed channels (\(detail)). Showing trending channels instead."
        return
      }
    }

    do {
      channels = try await fetcher.fetchLiveFollowedChannels(
        clientID: clientID,
        accessToken: initialAccessToken,
        userID: userID
      )
      isUsingDemoData = false
    } catch let error as TwitchHelixRequestError where error.status == 401 {
      do {
        let refreshedAccessToken = try await auth.recoverAccessToken(
          afterUnauthorized: initialAccessToken)
        channels = try await fetcher.fetchLiveFollowedChannels(
          clientID: clientID,
          accessToken: refreshedAccessToken,
          userID: userID
        )
        isUsingDemoData = false
      } catch {
        channels = await fetchDemoChannels()
        isUsingDemoData = true
        let detail = describe(error)
        errorMessage =
          "Could not load followed channels (\(detail)). Showing trending channels instead."
      }
    } catch {
      channels = await fetchDemoChannels()
      isUsingDemoData = true
      let detail = describe(error)
      errorMessage =
        "Could not load followed channels (\(detail)). Showing trending channels instead."
    }

    // Best-effort: build the full follow-category profile (incl. offline follows)
    // for personalized recommendations. Never affects the Following rail.
    if !isUsingDemoData {
      await refreshFollowedCategories(
        clientID: clientID,
        accessToken: auth.accessToken ?? initialAccessToken,
        userID: userID
      )
    } else {
      followedCategories = [:]
      followedLogins = []
    }
  }

  /// Loads the full Following directory — every followed channel, live and
  /// offline — into `directory`, sorted live-first. Lazy and idempotent: a cached
  /// result is reused unless `force` is set. Requires a real authenticated
  /// session (the directory has no demo/trending equivalent).
  func loadDirectory(using auth: TwitchAuthSession, force: Bool = false) async {
    guard auth.isAuthenticated, let userID = auth.userID else { return }
    guard let clientID = resolveClientID(),
          !Self.disallowedClientIDs.contains(clientID.lowercased())
    else { return }

    if !force, directoryLoadedAt != nil { return }
    if isLoadingDirectory { return }

    isLoadingDirectory = true
    directoryErrorMessage = nil
    defer { isLoadingDirectory = false }

    let accessToken: String
    if let token = auth.accessToken {
      accessToken = token
    } else {
      do {
        accessToken = try await auth.refreshAccessTokenIfNeeded(force: true)
      } catch {
        directoryErrorMessage =
          "Could not load your follows (\(describe(error)))."
        return
      }
    }

    do {
      directory = try await fetcher.fetchFollowingDirectory(
        clientID: clientID, accessToken: accessToken, userID: userID)
      directoryLoadedAt = Date()
    } catch let error as TwitchHelixRequestError where error.status == 401 {
      do {
        let refreshed = try await auth.recoverAccessToken(
          afterUnauthorized: accessToken)
        directory = try await fetcher.fetchFollowingDirectory(
          clientID: clientID, accessToken: refreshed, userID: userID)
        directoryLoadedAt = Date()
      } catch {
        directoryErrorMessage = "Could not load your follows (\(describe(error)))."
      }
    } catch {
      directoryErrorMessage = "Could not load your follows (\(describe(error)))."
    }
  }

  /// Loads the categories of every channel the viewer follows (online and offline)
  /// and tallies them by category. Best-effort: on any failure the previous
  /// profile is left intact so a transient error doesn't wipe recommendations.
  private func refreshFollowedCategories(clientID: String, accessToken: String, userID: String) async {
    do {
      let follows = try await fetcher.fetchFollowedBroadcasters(
        clientID: clientID, accessToken: accessToken, userID: userID)
      let ids = follows.map(\.broadcasterID)
      guard !ids.isEmpty else {
        followedCategories = [:]
        followedLogins = []
        return
      }
      followedLogins = Set(
        follows.compactMap {
          let login = $0.broadcasterLogin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          return (login?.isEmpty == false) ? login : nil
        })
      followedCategories = try await fetcher.fetchChannelCategoryCounts(
        clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
    } catch {
      // Keep any previously-loaded profile.
    }
  }

  private func resolveClientID() -> String? {
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

  private func fetchDemoChannels() async -> [FollowedChannel] {
    do {
      let trending = try await demoProvider.fetchTrendingChannels()
      if !trending.isEmpty {
        return trending
      }
      errorMessage = "Trending feed is empty right now. Showing fallback demo channels."
    } catch {
      errorMessage = "Could not load trending channels. Showing fallback demo channels."
    }

    return FollowedChannelsDemoProvider.demoChannels
  }

  private func describe(_ error: Error) -> String {
    if let helixError = error as? TwitchHelixRequestError {
      return helixError.localizedDescription
    }
    return error.localizedDescription
  }
}
