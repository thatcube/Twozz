import Foundation
import Observation

@MainActor
@Observable
final class FollowedChannelsService {
  private static let disallowedClientIDs: Set<String> = [
    // Twitch web public client. Device flow consent appears as "Twilight"
    // and followed-channel APIs can fail unexpectedly.
    TwitchConfig.webPublicClientID
  ]

  private(set) var channels: [FollowedChannel] = [] {
    didSet { prewarmAvatars(channels) }
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
    didSet { prewarmAvatars(directory) }
  }
  private(set) var isLoadingDirectory = false
  private(set) var directoryErrorMessage: String?
  private(set) var directoryLoadedAt: Date?

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
      channels = try await fetchLiveFollowedChannels(
        clientID: clientID,
        accessToken: initialAccessToken,
        userID: userID
      )
      isUsingDemoData = false
    } catch let error as TwitchHelixRequestError where error.status == 401 {
      do {
        let refreshedAccessToken = try await auth.refreshAccessTokenIfNeeded(force: true)
        channels = try await fetchLiveFollowedChannels(
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

  /// Warm the decoded-image cache for followed channels' *static* avatars
  /// whenever the followed list or the full Following directory updates, so the
  /// Home "Followed" rail and the directory grid paint each avatar instantly
  /// instead of decoding it on the fly while scrolling. Live stream preview
  /// thumbnails (`FollowedChannel.thumbnailURL`) are deliberately never
  /// prewarmed: they must always reflect the current moment. Best-effort and low
  /// priority; idempotent and bounded by the shared `NSCache`.
  private func prewarmAvatars(_ channels: [FollowedChannel]) {
    let urls = channels.compactMap(\.profileImageURL)
    guard !urls.isEmpty else { return }
    Task(priority: .utility) {
      for url in urls {
        if Task.isCancelled { return }
        await ImageMemoryCache.shared.prewarm(url)
      }
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
      directory = try await fetchFollowingDirectory(
        clientID: clientID, accessToken: accessToken, userID: userID)
      directoryLoadedAt = Date()
    } catch let error as TwitchHelixRequestError where error.status == 401 {
      do {
        let refreshed = try await auth.refreshAccessTokenIfNeeded(force: true)
        directory = try await fetchFollowingDirectory(
          clientID: clientID, accessToken: refreshed, userID: userID)
        directoryLoadedAt = Date()
      } catch {
        directoryErrorMessage = "Could not load your follows (\(describe(error)))."
      }
    } catch {
      directoryErrorMessage = "Could not load your follows (\(describe(error)))."
    }
  }

  /// Assembles the full directory: every followed broadcaster (paginated),
  /// enriched with live status + viewer counts (`/streams`), identity + profile
  /// and offline images (`/users`), and last/current title + game (`/channels`),
  /// all batched at 100 IDs per request, then sorted live-first.
  private func fetchFollowingDirectory(clientID: String, accessToken: String, userID: String)
    async throws -> [FollowedChannel]
  {
    let broadcasters = try await fetchAllFollowedBroadcasters(
      clientID: clientID, accessToken: accessToken, userID: userID)
    guard !broadcasters.isEmpty else { return [] }

    let ids = broadcasters.map(\.broadcasterID)
    let liveByID = try await fetchLiveStreamsForBroadcasterIDs(
      clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
    let usersByID = try await fetchUsersByID(
      clientID: clientID, accessToken: accessToken, userIDs: ids)
    let infoByID = try await fetchChannelInfoByID(
      clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)

    let channels: [FollowedChannel] = broadcasters.map { broadcaster in
      let user = usersByID[broadcaster.broadcasterID]
      if let stream = liveByID[broadcaster.broadcasterID] {
        return mapStream(stream, profileImageURL: user?.profileImageURL)
      }
      let info = infoByID[broadcaster.broadcasterID]
      let login = user?.login ?? broadcaster.broadcasterLogin ?? ""
      let name =
        user?.displayName ?? broadcaster.broadcasterName ?? broadcaster.broadcasterLogin ?? login
      return FollowedChannel(
        id: broadcaster.broadcasterID,
        login: login,
        displayName: name,
        title: info?.title ?? "",
        gameName: info?.gameName ?? "",
        viewerCount: nil,
        thumbnailURL: user?.offlineImageURL,
        profileImageURL: user?.profileImageURL,
        isLive: false
      )
    }

    return channels.sorted { lhs, rhs in
      if lhs.isLive != rhs.isLive { return lhs.isLive }
      if lhs.isLive && rhs.isLive {
        return (lhs.viewerCount ?? 0) > (rhs.viewerCount ?? 0)
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  /// Pages through `/channels/followed` (cursor) so the directory includes every
  /// follow, not just the first 100.
  private func fetchAllFollowedBroadcasters(clientID: String, accessToken: String, userID: String)
    async throws -> [FollowedBroadcaster]
  {
    var all: [FollowedBroadcaster] = []
    var cursor: String?

    repeat {
      var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
      components.queryItems = [
        URLQueryItem(name: "user_id", value: userID),
        URLQueryItem(name: "first", value: "100"),
      ]
      if let cursor {
        components.queryItems?.append(URLQueryItem(name: "after", value: cursor))
      }

      let req = TwitchAPIClient.helixRequest(
        url: components.url!, accessToken: accessToken, clientID: clientID,
        accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

      let (data, status) = try await performHelixRequest(req)
      guard (200...299).contains(status) else {
        throw makeHelixError(context: "loading followed channels", status: status, data: data)
      }

      let envelope = try JSONDecoder().decode(FollowedChannelsEnvelope.self, from: data)
      all.append(contentsOf: envelope.data)
      let next = envelope.pagination?.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
      cursor = (next?.isEmpty == false) ? next : nil
    } while cursor != nil

    return all
  }

  /// Live stream lookup for an arbitrary number of broadcasters, batched at 100
  /// IDs per `/streams` request (the existing single-batch helper caps at 100).
  private func fetchLiveStreamsForBroadcasterIDs(
    clientID: String, accessToken: String, broadcasterIDs: [String]
  ) async throws -> [String: HelixStream] {
    var result: [String: HelixStream] = [:]
    let uniqueIDs = Array(Set(broadcasterIDs))

    for chunk in stride(from: 0, to: uniqueIDs.count, by: 100) {
      let batch = Array(uniqueIDs[chunk..<min(chunk + 100, uniqueIDs.count)])
      var components = URLComponents(string: "https://api.twitch.tv/helix/streams")!
      components.queryItems = [URLQueryItem(name: "first", value: "100")]
      components.queryItems?.append(
        contentsOf: batch.map { URLQueryItem(name: "user_id", value: $0) })

      let req = TwitchAPIClient.helixRequest(
        url: components.url!, accessToken: accessToken, clientID: clientID,
        accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

      let (data, status) = try await performHelixRequest(req)
      guard (200...299).contains(status) else {
        throw makeHelixError(context: "loading live stream statuses", status: status, data: data)
      }

      let streams = try JSONDecoder().decode(FollowedStreamsEnvelope.self, from: data).data
      for stream in streams {
        result[stream.userID] = stream
      }
    }

    return result
  }

  /// Identity + profile/offline images for an arbitrary number of users, batched
  /// at 100 IDs per `/users` request.
  private func fetchUsersByID(
    clientID: String, accessToken: String, userIDs: [String]
  ) async throws -> [String: HelixUser] {
    var result: [String: HelixUser] = [:]
    let uniqueIDs = Array(Set(userIDs))

    for chunk in stride(from: 0, to: uniqueIDs.count, by: 100) {
      let batch = Array(uniqueIDs[chunk..<min(chunk + 100, uniqueIDs.count)])
      var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
      components.queryItems = batch.map { URLQueryItem(name: "id", value: $0) }

      let req = TwitchAPIClient.helixRequest(
        url: components.url!, accessToken: accessToken, clientID: clientID,
        accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

      let (data, status) = try await performHelixRequest(req)
      guard (200...299).contains(status) else {
        throw makeHelixError(context: "loading followed user profiles", status: status, data: data)
      }

      let payload = try JSONDecoder().decode(HelixUsersEnvelope.self, from: data)
      for user in payload.data {
        result[user.id] = user
      }
    }

    return result
  }

  /// Last/current broadcast title + game for an arbitrary number of broadcasters,
  /// batched at 100 IDs per `/channels` request. Drives offline card metadata.
  private func fetchChannelInfoByID(
    clientID: String, accessToken: String, broadcasterIDs: [String]
  ) async throws -> [String: ChannelInformation] {
    var result: [String: ChannelInformation] = [:]
    let uniqueIDs = Array(Set(broadcasterIDs))

    for chunk in stride(from: 0, to: uniqueIDs.count, by: 100) {
      let batch = Array(uniqueIDs[chunk..<min(chunk + 100, uniqueIDs.count)])
      var components = URLComponents(string: "https://api.twitch.tv/helix/channels")!
      components.queryItems = batch.map { URLQueryItem(name: "broadcaster_id", value: $0) }

      let req = TwitchAPIClient.helixRequest(
        url: components.url!, accessToken: accessToken, clientID: clientID,
        accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

      let (data, status) = try await performHelixRequest(req)
      guard (200...299).contains(status) else {
        throw makeHelixError(context: "loading followed channel info", status: status, data: data)
      }

      let payload = try JSONDecoder().decode(ChannelInformationEnvelope.self, from: data)
      for channel in payload.data {
        if let id = channel.broadcasterID {
          result[id] = channel
        }
      }
    }

    return result
  }

  /// Loads the categories of every channel the viewer follows (online and offline)
  /// and tallies them by category. Best-effort: on any failure the previous
  /// profile is left intact so a transient error doesn't wipe recommendations.
  private func refreshFollowedCategories(clientID: String, accessToken: String, userID: String) async {
    do {
      let follows = try await fetchFollowedBroadcasters(
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
      followedCategories = try await fetchChannelCategoryCounts(
        clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
    } catch {
      // Keep any previously-loaded profile.
    }
  }

  /// Tallies last/current broadcast categories for the given broadcasters via
  /// Helix Get Channel Information (batched at 100 IDs per request).
  private func fetchChannelCategoryCounts(
    clientID: String, accessToken: String, broadcasterIDs: [String]
  ) async throws -> [String: Int] {
    var counts: [String: Int] = [:]
    let uniqueIDs = Array(Set(broadcasterIDs))

    for chunk in stride(from: 0, to: uniqueIDs.count, by: 100) {
      let batch = Array(uniqueIDs[chunk..<min(chunk + 100, uniqueIDs.count)])
      var components = URLComponents(string: "https://api.twitch.tv/helix/channels")!
      components.queryItems = batch.map { URLQueryItem(name: "broadcaster_id", value: $0) }

      let req = TwitchAPIClient.helixRequest(
        url: components.url!, accessToken: accessToken, clientID: clientID,
        accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

      let (data, status) = try await performHelixRequest(req)
      guard (200...299).contains(status) else {
        throw makeHelixError(context: "loading followed channel categories", status: status, data: data)
      }

      let payload = try JSONDecoder().decode(ChannelInformationEnvelope.self, from: data)
      for channel in payload.data {
        let name = channel.gameName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { continue }
        counts[name, default: 0] += 1
      }
    }

    return counts
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
      let trending = try await fetchTrendingChannels()
      if !trending.isEmpty {
        return trending
      }
      errorMessage = "Trending feed is empty right now. Showing fallback demo channels."
    } catch {
      errorMessage = "Could not load trending channels. Showing fallback demo channels."
    }

    return Self.demoChannels
  }

  private func fetchLiveFollowedChannels(clientID: String, accessToken: String, userID: String)
    async throws -> [FollowedChannel]
  {
    do {
      let followed = try await fetchFollowedStreamsDirect(
        clientID: clientID, accessToken: accessToken, userID: userID)
      let profileImagesByUserID = try await fetchProfileImagesByUserID(
        clientID: clientID,
        accessToken: accessToken,
        userIDs: followed.map(\.userID)
      )
      return followed.map { stream in
        mapStream(stream, profileImageURL: profileImagesByUserID[stream.userID])
      }
    } catch let error as TwitchHelixRequestError {
      guard error.status == 404 else {
        throw error
      }

      do {
        let follows = try await fetchFollowedBroadcasters(
          clientID: clientID, accessToken: accessToken, userID: userID)
        if follows.isEmpty {
          return []
        }

        let liveByBroadcasterID = try await fetchLiveStreamsByBroadcasterID(
          clientID: clientID,
          accessToken: accessToken,
          broadcasterIDs: follows.map(\.broadcasterID)
        )
        let profileImagesByUserID = try await fetchProfileImagesByUserID(
          clientID: clientID,
          accessToken: accessToken,
          userIDs: follows.map(\.broadcasterID)
        )

        return follows.compactMap { followed in
          guard let stream = liveByBroadcasterID[followed.broadcasterID] else {
            return nil
          }
          return mapStream(stream, profileImageURL: profileImagesByUserID[followed.broadcasterID])
        }
      } catch let fallbackError as TwitchHelixRequestError {
        // Some clients/tokens occasionally fail for /channels/followed but
        // still allow resolving the current user via /users.
        guard fallbackError.status == 404 else {
          throw fallbackError
        }

        let resolvedUserID = try await fetchCurrentUserID(
          clientID: clientID, accessToken: accessToken)
        guard resolvedUserID != userID else {
          throw fallbackError
        }

        let followed = try await fetchFollowedStreamsDirect(
          clientID: clientID,
          accessToken: accessToken,
          userID: resolvedUserID
        )
        let profileImagesByUserID = try await fetchProfileImagesByUserID(
          clientID: clientID,
          accessToken: accessToken,
          userIDs: followed.map(\.userID)
        )
        return followed.map { stream in
          mapStream(stream, profileImageURL: profileImagesByUserID[stream.userID])
        }
      }
    }
  }

  private func fetchCurrentUserID(clientID: String, accessToken: String) async throws -> String {
    let req = TwitchAPIClient.helixRequest(
      url: URL(string: "https://api.twitch.tv/helix/users")!, accessToken: accessToken,
      clientID: clientID, accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "resolving current Twitch user", status: status, data: data)
    }

    let payload = try JSONDecoder().decode(HelixUsersEnvelope.self, from: data)
    guard let first = payload.data.first else {
      throw URLError(.cannotParseResponse)
    }
    return first.id
  }

  private func fetchFollowedStreamsDirect(clientID: String, accessToken: String, userID: String)
    async throws -> [HelixStream]
  {
    var components = URLComponents(string: "https://api.twitch.tv/helix/streams/followed")!
    components.queryItems = [
      URLQueryItem(name: "user_id", value: userID),
      URLQueryItem(name: "first", value: "100"),
    ]

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "loading followed streams", status: status, data: data)
    }

    return try JSONDecoder().decode(FollowedStreamsEnvelope.self, from: data).data
  }

  private func fetchFollowedBroadcasters(clientID: String, accessToken: String, userID: String)
    async throws -> [FollowedBroadcaster]
  {
    var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
    components.queryItems = [
      URLQueryItem(name: "user_id", value: userID),
      URLQueryItem(name: "first", value: "100"),
    ]

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "loading followed channels", status: status, data: data)
    }

    return try JSONDecoder().decode(FollowedChannelsEnvelope.self, from: data).data
  }

  private func fetchLiveStreamsByBroadcasterID(
    clientID: String, accessToken: String, broadcasterIDs: [String]
  ) async throws -> [String: HelixStream] {
    guard !broadcasterIDs.isEmpty else { return [:] }

    let cappedIDs = Array(Set(broadcasterIDs)).prefix(100)
    var components = URLComponents(string: "https://api.twitch.tv/helix/streams")!
    components.queryItems = [URLQueryItem(name: "first", value: "100")]
    components.queryItems?.append(
      contentsOf: cappedIDs.map { URLQueryItem(name: "user_id", value: $0) })

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "loading live stream statuses", status: status, data: data)
    }

    let streams = try JSONDecoder().decode(FollowedStreamsEnvelope.self, from: data).data
    return Dictionary(uniqueKeysWithValues: streams.map { ($0.userID, $0) })
  }

  private func fetchProfileImagesByUserID(
    clientID: String, accessToken: String, userIDs: [String]
  ) async throws -> [String: URL] {
    guard !userIDs.isEmpty else { return [:] }

    let cappedIDs = Array(Set(userIDs)).prefix(100)
    var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
    components.queryItems = cappedIDs.map { URLQueryItem(name: "id", value: $0) }

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "loading streamer profile images", status: status, data: data)
    }

    let payload = try JSONDecoder().decode(HelixUsersEnvelope.self, from: data)
    return Dictionary(
      uniqueKeysWithValues: payload.data.compactMap { user in
        guard let profileURL = user.profileImageURL else {
          return nil
        }
        return (user.id, profileURL)
      })
  }

  private func mapStream(_ stream: HelixStream, profileImageURL: URL?) -> FollowedChannel {
    let thumb = stream.thumbnailURL
      .replacingOccurrences(of: "{width}", with: "640")
      .replacingOccurrences(of: "{height}", with: "360")

    return FollowedChannel(
      id: stream.userID,
      login: stream.userLogin,
      displayName: stream.userName,
      title: stream.title,
      gameName: stream.gameName,
      viewerCount: stream.viewerCount,
      thumbnailURL: URL(string: thumb),
      profileImageURL: profileImageURL,
      isLive: stream.type == "live",
      isMature: stream.isMature
    )
  }

  private func performHelixRequest(_ req: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (data, status)
  }

  private func makeHelixError(context: String, status: Int, data: Data) -> TwitchHelixRequestError {
    let payload = try? JSONDecoder().decode(TwitchHelixErrorPayload.self, from: data)
    let message = payload?.message ?? payload?.error ?? String(data: data, encoding: .utf8)
    return TwitchHelixRequestError(context: context, status: status, message: message)
  }

  private func describe(_ error: Error) -> String {
    if let helixError = error as? TwitchHelixRequestError {
      return helixError.localizedDescription
    }
    return error.localizedDescription
  }

  /// Fetches top live streams anonymously from Twitch GraphQL.
  /// This powers demo mode when user auth is not configured yet.
  private func fetchTrendingChannels(limit: Int = 20) async throws -> [FollowedChannel] {
    struct TrendingNode: Decodable {
      let id: String?
      let title: String?
      let viewersCount: Int?
      let isMature: Bool?
      let previewImageURL: String?
      let broadcaster: Broadcaster?
      let game: Game?

      struct Broadcaster: Decodable {
        let login: String?
        let displayName: String?
        let profileImageURL: String?
      }

      struct Game: Decodable {
        let displayName: String?
      }
    }

    struct TrendingEdge: Decodable {
      let node: TrendingNode?
    }

    struct StreamsConnection: Decodable {
      let edges: [TrendingEdge]?
    }

    struct TrendingData: Decodable {
      let streams: StreamsConnection?
    }

    struct TrendingEnvelope: Decodable {
      let data: TrendingData?
    }

    let query = """
      query TopStreams($first: Int!) {
        streams(first: $first) {
          edges {
            node {
              id
              title
              viewersCount
              isMature
              previewImageURL(width: 640, height: 360)
              broadcaster {
                login
                displayName
                profileImageURL(width: 70)
              }
              game {
                displayName
              }
            }
          }
        }
      }
      """

    var req = TwitchAPIClient.graphQLRequest()
    req.httpBody = try JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["first": limit]))

    let (data, response) = try await URLSession.shared.data(for: req)
    try TwitchAPIClient.validatedData(data, response)

    let decoded = try JSONDecoder().decode(TrendingEnvelope.self, from: data)
    let edges = decoded.data?.streams?.edges ?? []

    let channels = edges.compactMap { edge -> FollowedChannel? in
      guard let node = edge.node else { return nil }

      let id = node.id ?? UUID().uuidString
      let login = node.broadcaster?.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let displayName = node.broadcaster?.displayName?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let title = node.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Live now"
      let gameName =
        node.game?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Live"
      let previewURL = node.previewImageURL.flatMap { URL(string: $0) }
      let profileURL = node.broadcaster?.profileImageURL.flatMap { URL(string: $0) }

      guard !login.isEmpty else { return nil }

      return FollowedChannel(
        id: id,
        login: login,
        displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? login,
        title: title,
        gameName: gameName,
        viewerCount: node.viewersCount,
        thumbnailURL: previewURL,
        profileImageURL: profileURL,
        isLive: true,
        isMature: node.isMature ?? false
      )
    }

    return channels
  }

  private static let demoChannels: [FollowedChannel] = [
    FollowedChannel(
      id: "44322889",
      login: "alveussanctuary",
      displayName: "AlveusSanctuary",
      title: "Rescue animals, science, and chill vibes",
      gameName: "Animals, Aquariums, and Zoos",
      viewerCount: 4821,
      thumbnailURL: URL(
        string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_alveussanctuary-640x360.jpg"),
      profileImageURL: nil,
      isLive: true
    ),
    FollowedChannel(
      id: "71092938",
      login: "northernlion",
      displayName: "Northernlion",
      title: "Trying weird roguelikes and talking nonsense",
      gameName: "Balatro",
      viewerCount: 8230,
      thumbnailURL: URL(
        string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_northernlion-640x360.jpg"),
      profileImageURL: nil,
      isLive: true
    ),
    FollowedChannel(
      id: "26490481",
      login: "cohhcarnage",
      displayName: "CohhCarnage",
      title: "New release first look",
      gameName: "Just Chatting",
      viewerCount: 3912,
      thumbnailURL: URL(
        string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_cohhcarnage-640x360.jpg"),
      profileImageURL: nil,
      isLive: true
    ),
    FollowedChannel(
      id: "23161357",
      login: "esl_cs2",
      displayName: "ESL_CSGO",
      title: "Playoffs day 2 - main stage",
      gameName: "Counter-Strike",
      viewerCount: 66740,
      thumbnailURL: URL(
        string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_esl_cs2-640x360.jpg"),
      profileImageURL: nil,
      isLive: true
    ),
  ]
}

private struct FollowedStreamsEnvelope: Decodable {
  let data: [HelixStream]
}

private struct HelixStream: Decodable {
  let userID: String
  let userLogin: String
  let userName: String
  let gameName: String
  let title: String
  let viewerCount: Int
  let isMature: Bool
  let thumbnailURL: String
  let type: String

  private enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case userLogin = "user_login"
    case userName = "user_name"
    case gameName = "game_name"
    case title
    case viewerCount = "viewer_count"
    case isMature = "is_mature"
    case thumbnailURL = "thumbnail_url"
    case type
  }
}

private struct FollowedChannelsEnvelope: Decodable {
  let data: [FollowedBroadcaster]
  let pagination: HelixPagination?
}

private struct HelixPagination: Decodable {
  let cursor: String?
}

private struct ChannelInformationEnvelope: Decodable {
  let data: [ChannelInformation]
}

private struct ChannelInformation: Decodable {
  let broadcasterID: String?
  let gameName: String?
  let title: String?

  private enum CodingKeys: String, CodingKey {
    case broadcasterID = "broadcaster_id"
    case gameName = "game_name"
    case title
  }
}

private struct HelixUsersEnvelope: Decodable {
  let data: [HelixUser]
}

private struct HelixUser: Decodable {
  let id: String
  let login: String?
  let displayName: String?
  let profileImageURL: URL?
  let offlineImageURL: URL?

  private enum CodingKeys: String, CodingKey {
    case id
    case login
    case displayName = "display_name"
    case profileImageURL = "profile_image_url"
    case offlineImageURL = "offline_image_url"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    login = try container.decodeIfPresent(String.self, forKey: .login)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    profileImageURL = Self.url(in: container, forKey: .profileImageURL)
    offlineImageURL = Self.url(in: container, forKey: .offlineImageURL)
  }

  private static func url(
    in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) -> URL? {
    let raw = try? container.decodeIfPresent(String.self, forKey: key)
    guard let raw, !raw.isEmpty else { return nil }
    return URL(string: raw)
  }
}

private struct FollowedBroadcaster: Decodable {
  let broadcasterID: String
  let broadcasterLogin: String?
  let broadcasterName: String?

  private enum CodingKeys: String, CodingKey {
    case broadcasterID = "broadcaster_id"
    case broadcasterLogin = "broadcaster_login"
    case broadcasterName = "broadcaster_name"
  }
}

private struct TwitchHelixErrorPayload: Decodable {
  let error: String?
  let status: Int?
  let message: String?
}

private struct TwitchHelixRequestError: LocalizedError {
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
