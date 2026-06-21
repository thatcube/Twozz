import Foundation

/// Networking + decode/mapping collaborator for `FollowedChannelsService`.
///
/// Owns every Twitch Helix round-trip used to assemble the viewer's followed
/// channels: the live "Following" rail (`fetchLiveFollowedChannels`), the full
/// Following directory (`fetchFollowingDirectory`), the raw follow list
/// (`fetchFollowedBroadcasters`), and the follow-category profile
/// (`fetchChannelCategoryCounts`). It is a pure data layer — it never touches
/// observable state, demo data, or UI; the service composes it and owns
/// orchestration, error messaging, and publishing.
///
/// `@MainActor` only to preserve the exact isolation the methods had when they
/// lived on the `@MainActor` service, so scheduling/ordering is unchanged.
/// Foundation-only so it can back a future iOS target.
@MainActor
struct FollowedChannelsFetcher {
  func fetchLiveFollowedChannels(clientID: String, accessToken: String, userID: String)
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

        // Live streams and profile images both derive only from `follows`, so
        // fetch them concurrently rather than back to back.
        async let liveByBroadcasterIDTask = fetchLiveStreamsByBroadcasterID(
          clientID: clientID,
          accessToken: accessToken,
          broadcasterIDs: follows.map(\.broadcasterID)
        )
        async let profileImagesByUserIDTask = fetchProfileImagesByUserID(
          clientID: clientID,
          accessToken: accessToken,
          userIDs: follows.map(\.broadcasterID)
        )
        let liveByBroadcasterID = try await liveByBroadcasterIDTask
        let profileImagesByUserID = try await profileImagesByUserIDTask

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

  /// Assembles the full directory: every followed broadcaster (paginated),
  /// enriched with live status + viewer counts (`/streams`), identity + profile
  /// and offline images (`/users`), and last/current title + game (`/channels`),
  /// all batched at 100 IDs per request, then sorted live-first.
  func fetchFollowingDirectory(clientID: String, accessToken: String, userID: String)
    async throws -> [FollowedChannel]
  {
    let broadcasters = try await fetchAllFollowedBroadcasters(
      clientID: clientID, accessToken: accessToken, userID: userID)
    guard !broadcasters.isEmpty else { return [] }

    let ids = broadcasters.map(\.broadcasterID)
    // These three lookups all key off the same broadcaster ids and don't depend
    // on one another, so run them concurrently instead of waiting for each in
    // turn — it cuts the directory load from three sequential round-trip groups
    // (each up to N/100 batches) down to one wall-clock group.
    async let liveByIDTask = fetchLiveStreamsForBroadcasterIDs(
      clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
    async let usersByIDTask = fetchUsersByID(
      clientID: clientID, accessToken: accessToken, userIDs: ids)
    async let infoByIDTask = fetchChannelInfoByID(
      clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
    let liveByID = try await liveByIDTask
    let usersByID = try await usersByIDTask
    let infoByID = try await infoByIDTask

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

  func fetchFollowedBroadcasters(clientID: String, accessToken: String, userID: String)
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

    return try TwitchAPIClient.decode(FollowedChannelsEnvelope.self, from: data).data
  }

  /// Tallies last/current broadcast categories for the given broadcasters via
  /// Helix Get Channel Information (batched at 100 IDs per request).
  func fetchChannelCategoryCounts(
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

      let payload = try TwitchAPIClient.decode(ChannelInformationEnvelope.self, from: data)
      for channel in payload.data {
        let name = channel.gameName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { continue }
        counts[name, default: 0] += 1
      }
    }

    return counts
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

      let envelope = try TwitchAPIClient.decode(FollowedChannelsEnvelope.self, from: data)
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

      let streams = try TwitchAPIClient.decode(FollowedStreamsEnvelope.self, from: data).data
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

      let payload = try TwitchAPIClient.decode(HelixUsersEnvelope.self, from: data)
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

      let payload = try TwitchAPIClient.decode(ChannelInformationEnvelope.self, from: data)
      for channel in payload.data {
        if let id = channel.broadcasterID {
          result[id] = channel
        }
      }
    }

    return result
  }

  private func fetchCurrentUserID(clientID: String, accessToken: String) async throws -> String {
    let req = TwitchAPIClient.helixRequest(
      url: URL(string: "https://api.twitch.tv/helix/users")!, accessToken: accessToken,
      clientID: clientID, accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, status) = try await performHelixRequest(req)
    guard (200...299).contains(status) else {
      throw makeHelixError(context: "resolving current Twitch user", status: status, data: data)
    }

    let payload = try TwitchAPIClient.decode(HelixUsersEnvelope.self, from: data)
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

    return try TwitchAPIClient.decode(FollowedStreamsEnvelope.self, from: data).data
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

    let streams = try TwitchAPIClient.decode(FollowedStreamsEnvelope.self, from: data).data
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

    let payload = try TwitchAPIClient.decode(HelixUsersEnvelope.self, from: data)
    return Dictionary(
      uniqueKeysWithValues: payload.data.compactMap { user in
        guard let profileURL = user.profileImageURL else {
          return nil
        }
        return (user.id, profileURL)
      })
  }

  private func mapStream(_ stream: HelixStream, profileImageURL: URL?) -> FollowedChannel {
    // 640x360 is the *ceiling*: this is a live preview, so it renders through
    // `LiveThumbnail`, which downsizes the request to the bucket that fits the
    // card (e.g. 320x180 for 6-across) and adds a cache-busting token. We keep
    // the full size here so large cards still have a sharp source to scale from.
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
    let payload = try? TwitchAPIClient.decode(TwitchHelixErrorPayload.self, from: data)
    let message = payload?.message ?? payload?.error ?? String(data: data, encoding: .utf8)
    return TwitchHelixRequestError(context: context, status: status, message: message)
  }
}
