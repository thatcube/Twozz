import Foundation

/// Bundles everything the channel page's content rows need: the channel's top
/// clips, recent past broadcasts, and the signals used to drive "More like this".
struct ChannelContent {
  var clips: [ChannelClip]
  var videos: [ChannelVOD]
  var signals: ChannelSignals
}

/// A channel's "taste DNA", derived purely from anonymous public data. Built from
/// the games in its recent broadcasts plus its current language/tags/audience, and
/// fed into `SimilarChannelsEngine` to find genuinely related channels.
struct ChannelSignals {
  let login: String
  /// Category name -> normalized affinity weight (0...1), where 1.0 is the
  /// channel's most-streamed game across its recent broadcasts.
  let categoryWeights: [String: Double]
  /// Broadcast language enum token (e.g. "EN"), if known.
  let language: String?
  /// Freeform stream tags (e.g. "Speedrun", "Cozy"), if currently live.
  let tags: Set<String>
  /// Current concurrent viewers, used to favor similarly-sized peers.
  let viewerTier: Int?

  /// Categories ordered by descending affinity — the seeds for candidate search.
  var rankedCategories: [String] {
    categoryWeights.sorted { $0.value > $1.value }.map(\.key)
  }
}

/// Fetches a channel's on-demand content (clips + VODs) and the signals that power
/// the recommendation engine, all from the anonymous Twitch GQL endpoint.
struct ChannelContentService {
  static let clientID = TwitchConfig.webPublicClientID

  static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config)
  }()

  /// Catch-all / "meta" categories that say little about what a channel is
  /// actually *about* — most niche channels technically sit in "Just Chatting"
  /// while really streaming animals, art, music, etc. They're heavily
  /// down-weighted so a channel's specific category drives its recommendation
  /// DNA instead of being buried by a generic directory.
  static let genericCategories: Set<String> = [
    "just chatting",
    "special events",
    "talk shows & podcasts",
    "watch parties",
    "politics",
    "travel & outdoors",
    "asmr",
    "pools, hot tubs, and beaches",
  ]
  private static let genericCategoryWeight = 0.15

  static func isGeneric(_ category: String) -> Bool {
    genericCategories.contains(category.lowercased())
  }

  /// Resolves a Twitch thumbnail template to a concrete URL. Twitch returns these
  /// with `{width}x{height}` (or `%{width}`) placeholders, and freshly-ended VODs
  /// hand back a "404_processing" placeholder image — drop those so the card
  /// shows our own fallback instead of a broken/ugly thumbnail.
  static func thumbnail(_ raw: String?, width: Int, height: Int) -> URL? {
    guard let raw = raw?.trimmed, !raw.isEmpty else { return nil }
    if raw.contains("404_processing") || raw.contains("404_preview") { return nil }
    let resolved = raw
      .replacingOccurrences(of: "%{width}", with: "\(width)")
      .replacingOccurrences(of: "%{height}", with: "\(height)")
      .replacingOccurrences(of: "{width}", with: "\(width)")
      .replacingOccurrences(of: "{height}", with: "\(height)")
    return URL(string: resolved)
  }

  /// Loads clips, VODs, and channel signals in a single GQL request.
  static func load(login: String) async -> ChannelContent? {
    let normalized = login.lowercased()

    let query = """
      query ChannelContent($login: String!) {
        user(login: $login) {
          login
          broadcastSettings { language }
          stream { viewersCount game { name } freeformTags { name } }
          clips(first: 12, criteria: { period: LAST_MONTH, sort: VIEWS_DESC }) {
            edges { node {
              slug title viewCount durationSeconds thumbnailURL createdAt
              game { name displayName }
            } }
          }
          videos(first: 24, sort: TIME, type: ARCHIVE) {
            edges { node {
              id title lengthSeconds previewThumbnailURL publishedAt viewCount status
              game { name displayName }
            } }
          }
        }
      }
      """

    guard let data = try? await perform(query: query, variables: ["login": normalized]),
          let decoded = try? JSONDecoder().decode(ContentEnvelope.self, from: data),
          let user = decoded.data?.user
    else { return nil }

    let clips: [ChannelClip] = (user.clips?.edges ?? []).compactMap { edge in
      guard let node = edge.node, let slug = node.slug, !slug.isEmpty else { return nil }
      return ChannelClip(
        slug: slug,
        title: node.title?.trimmed.nilIfEmpty ?? "Clip",
        viewCount: node.viewCount ?? 0,
        durationSeconds: Int(node.durationSeconds ?? 0),
        thumbnailURL: ChannelContentService.thumbnail(node.thumbnailURL, width: 480, height: 270),
        gameName: node.game?.displayName?.trimmed.nilIfEmpty,
        createdAt: parseDate(node.createdAt)
      )
    }

    let videos: [ChannelVOD] = (user.videos?.edges ?? []).compactMap { edge in
      guard let node = edge.node, let id = node.id, !id.isEmpty else { return nil }
      // Drop the channel's in-progress broadcast: while a channel is live and
      // "store past broadcasts" is on, the current stream shows up as the newest
      // ARCHIVE video with status "RECORDING" and a 404_processing thumbnail.
      // The live card at the top already covers watching it, so this duplicate
      // (thumbnail-less) tile would just be a confusing first "Past Broadcast".
      // A RECORDING status only exists during an active broadcast, so this never
      // affects offline channels or finished VODs.
      if node.status?.uppercased() == "RECORDING" { return nil }
      return ChannelVOD(
        id: id,
        title: node.title?.trimmed.nilIfEmpty ?? "Past Broadcast",
        lengthSeconds: node.lengthSeconds ?? 0,
        thumbnailURL: ChannelContentService.thumbnail(node.previewThumbnailURL, width: 480, height: 270),
        gameName: node.game?.displayName?.trimmed.nilIfEmpty,
        publishedAt: parseDate(node.publishedAt),
        viewCount: node.viewCount ?? 0
      )
    }

    let signals = buildSignals(user: user, videos: user.videos?.edges ?? [])
    return ChannelContent(clips: clips, videos: videos, signals: signals)
  }

  // MARK: - Signals (channel "DNA")

  private static func buildSignals(user: UserNode, videos: [VideoEdge]) -> ChannelSignals {
    var counts: [String: Double] = [:]
    for edge in videos {
      guard let name = edge.node?.game?.name?.trimmed, !name.isEmpty else { continue }
      counts[name, default: 0] += 1
    }
    // The currently-streamed game is the strongest single signal of what the
    // channel is "about" right now, so it gets extra weight.
    if let liveGame = user.stream?.game?.name?.trimmed, !liveGame.isEmpty {
      counts[liveGame, default: 0] += 2
    }

    // Down-weight generic catch-all categories so a channel's *specific* niche
    // (e.g. "Animals, Aquariums, and Zoos") wins over "Just Chatting" even when
    // it has fewer broadcasts, then normalize so the strongest signal is 1.0.
    var weighted: [String: Double] = [:]
    for (name, count) in counts {
      weighted[name] = count * (isGeneric(name) ? genericCategoryWeight : 1.0)
    }
    let maxWeight = weighted.values.max() ?? 0
    let weights: [String: Double] = maxWeight > 0
      ? weighted.mapValues { $0 / maxWeight }
      : [:]

    let tags = Set((user.stream?.freeformTags ?? []).compactMap { $0.name?.trimmed.nilIfEmpty })

    return ChannelSignals(
      login: (user.login ?? "").lowercased(),
      categoryWeights: weights,
      language: user.broadcastSettings?.language?.trimmed.nilIfEmpty,
      tags: tags,
      viewerTier: user.stream?.viewersCount
    )
  }

  // MARK: - GQL transport

  static func perform(query: String, variables: [String: Any]) async throws -> Data {
    var req = TwitchAPIClient.graphQLRequest(
      clientID: clientID, clientIDField: "Client-ID", userAgent: TwitchConfig.apiUserAgent)
    req.httpBody = try JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

    let (data, response) = try await session.data(for: req)
    return try TwitchAPIClient.validatedData(data, response)
  }

  static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }

  // MARK: - Decoding

  private struct ContentEnvelope: Decodable { let data: ContentData? }
  private struct ContentData: Decodable { let user: UserNode? }

  struct UserNode: Decodable {
    let login: String?
    let broadcastSettings: BroadcastSettings?
    let stream: StreamNode?
    let clips: ClipConn?
    let videos: VideoConn?
  }
  struct BroadcastSettings: Decodable { let language: String? }
  struct StreamNode: Decodable {
    let viewersCount: Int?
    let game: GameNode?
    let freeformTags: [Tag]?
  }
  struct Tag: Decodable { let name: String? }
  struct GameNode: Decodable { let name: String?; let displayName: String? }

  struct ClipConn: Decodable { let edges: [ClipEdge]? }
  struct ClipEdge: Decodable { let node: ClipNode? }
  struct ClipNode: Decodable {
    let slug: String?
    let title: String?
    let viewCount: Int?
    let durationSeconds: Double?
    let thumbnailURL: String?
    let createdAt: String?
    let game: GameNode?
  }

  struct VideoConn: Decodable { let edges: [VideoEdge]? }
  struct VideoEdge: Decodable { let node: VideoNode? }
  struct VideoNode: Decodable {
    let id: String?
    let title: String?
    let lengthSeconds: Int?
    let previewThumbnailURL: String?
    let publishedAt: String?
    let viewCount: Int?
    let status: String?
    let game: GameNode?
  }
}

private extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
