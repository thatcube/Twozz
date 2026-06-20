import Foundation

/// Best-effort fetch of full channel detail for the channel page. Uses the same
/// anonymous Twitch GQL endpoint and public web client-id the rest of the app
/// relies on, so all data is public and no auth is required.
struct ChannelProfileService {
  private static let clientID = TwitchConfig.webPublicClientID

  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config)
  }()

  /// ISO8601 parsers are reused across calls: each `ISO8601DateFormatter()` is
  /// expensive to allocate, and a single profile fetch parses several timestamps
  /// (`createdAt`, stream/broadcast `startedAt`, …). The formatters are immutable
  /// once configured, so sharing them is safe.
  private nonisolated(unsafe) static let withFractionFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// Parses Twitch's ISO-8601 timestamps, which sometimes include fractional
  /// seconds (e.g. `2012-11-03T15:50:32.87847Z`) and sometimes don't.
  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let date = withFractionFormatter.date(from: raw) { return date }
    return plainFormatter.date(from: raw)
  }

  static func fetch(login: String) async -> ChannelProfile? {
    let normalized = login.lowercased()

    let query = """
      query ChannelPage($login: String!) {
        user(login: $login) {
          login
          displayName
          description
          profileImageURL(width: 300)
          bannerImageURL
          createdAt
          roles { isPartner isAffiliate }
          followers { totalCount }
          stream { id title viewersCount createdAt type game { displayName } }
          lastBroadcast { startedAt title game { displayName } }
          channel { socialMedias { name title url } }
        }
      }
      """

    var req = TwitchAPIClient.graphQLRequest(
      clientID: clientID, clientIDField: "Client-ID", userAgent: TwitchConfig.apiUserAgent)
    req.httpBody = try? JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["login": normalized])
    )

    guard let (data, response) = try? await session.data(for: req) else { return nil }
    guard TwitchAPIClient.isSuccess(response) else { return nil }

    guard
      let decoded = try? JSONDecoder().decode(GQLEnvelope.self, from: data),
      let user = decoded.data?.user
    else { return nil }

    let socialLinks: [ChannelSocialLink] = (user.channel?.socialMedias ?? []).compactMap { media in
      guard let url = media.url, !url.isEmpty else { return nil }
      let title = media.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = media.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let resolvedTitle = (title?.isEmpty == false ? title! : name)
      return ChannelSocialLink(
        id: media.name ?? url,
        name: name,
        title: resolvedTitle.isEmpty ? url : resolvedTitle,
        url: url
      )
    }

    let isLive = user.stream != nil

    return ChannelProfile(
      login: user.login ?? normalized,
      displayName: user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? (user.login ?? normalized),
      description: user.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      profileImageURL: user.profileImageURL.flatMap(URL.init(string:)),
      bannerImageURL: user.bannerImageURL.flatMap(URL.init(string:)),
      createdAt: parseDate(user.createdAt),
      isPartner: user.roles?.isPartner ?? false,
      isAffiliate: user.roles?.isAffiliate ?? false,
      followerCount: user.followers?.totalCount,
      isLive: isLive,
      liveTitle: user.stream?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      liveGame: user.stream?.game?.displayName,
      liveViewerCount: user.stream?.viewersCount,
      liveStartedAt: parseDate(user.stream?.createdAt),
      lastBroadcastTitle: user.lastBroadcast?.title?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      lastBroadcastGame: user.lastBroadcast?.game?.displayName,
      lastBroadcastStartedAt: parseDate(user.lastBroadcast?.startedAt),
      socialLinks: socialLinks
    )
  }

  // MARK: - Decoding

  private struct GQLEnvelope: Decodable { let data: GQLData? }
  private struct GQLData: Decodable { let user: UserNode? }

  private struct UserNode: Decodable {
    let login: String?
    let displayName: String?
    let description: String?
    let profileImageURL: String?
    let bannerImageURL: String?
    let createdAt: String?
    let roles: Roles?
    let followers: Followers?
    let stream: StreamNode?
    let lastBroadcast: LastBroadcast?
    let channel: Channel?

    struct Roles: Decodable {
      let isPartner: Bool?
      let isAffiliate: Bool?
    }
    struct Followers: Decodable { let totalCount: Int? }
    struct StreamNode: Decodable {
      let title: String?
      let viewersCount: Int?
      let createdAt: String?
      let game: Game?
    }
    struct LastBroadcast: Decodable {
      let startedAt: String?
      let title: String?
      let game: Game?
    }
    struct Game: Decodable { let displayName: String? }
    struct Channel: Decodable { let socialMedias: [SocialMedia]? }
    struct SocialMedia: Decodable {
      let name: String?
      let title: String?
      let url: String?
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
