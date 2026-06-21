import Foundation

/// Demo/fallback data source for `FollowedChannelsService`.
///
/// Supplies the channels shown when no real authenticated session is available
/// (or a followed-channels fetch fails): top live streams pulled anonymously
/// from Twitch GraphQL via `fetchTrendingChannels`, with a small hand-curated
/// `demoChannels` list as the last-resort fallback. Pure data — it never
/// touches observable state or UI; the service decides when to use it and owns
/// any user-facing error messaging.
///
/// `@MainActor` only to preserve the exact isolation these helpers had on the
/// `@MainActor` service. Foundation-only so it can back a future iOS target.
@MainActor
struct FollowedChannelsDemoProvider {
  /// Fetches top live streams anonymously from Twitch GraphQL.
  /// This powers demo mode when user auth is not configured yet.
  func fetchTrendingChannels(limit: Int = 20) async throws -> [FollowedChannel] {
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

    let (data, response) = try await NetworkClient.api.data(for: req)
    try TwitchAPIClient.validatedData(data, response)

    let decoded = try TwitchAPIClient.decode(TrendingEnvelope.self, from: data)
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

  static let demoChannels: [FollowedChannel] = [
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
