import Foundation

/// Finds channels genuinely similar to a given channel, entirely client-side from
/// anonymous public data — no login, no personalization API, no server.
///
/// The differentiator vs. a plain "top of category" list is multi-signal scoring:
/// a channel's category *DNA* (built from the games across its recent broadcasts)
/// is matched against live candidates and weighted by language, tag/vibe overlap,
/// and audience-tier similarity — so results favor relevant *peers* instead of the
/// same handful of mega-streamers that top every directory.
struct SimilarChannelsEngine {
  /// Scoring weights. Tuned so category fit dominates, with language/vibe/peer-size
  /// acting as tie-breakers that make results feel curated rather than generic.
  private static let categoryWeight = 0.45
  private static let languageWeight = 0.20
  private static let tagWeight = 0.20
  private static let tierWeight = 0.15

  private static let seedCategoryCount = 3
  private static let candidatesPerCategory = 40
  private static let maxResults = 12

  /// Returns up to `maxResults` recommended live channels ranked by similarity to
  /// the channel described by `signals`. Returns an empty list if there is not
  /// enough signal (e.g. a brand-new channel with no broadcast history).
  static func recommend(using signals: ChannelSignals) async -> [FollowedChannel] {
    // Seed the search from the channel's most defining categories. Prefer its
    // *specific* niches over generic catch-alls (Just Chatting, etc.) so a
    // sanctuary seeds from "Animals, Aquariums, and Zoos" rather than the
    // sprawling Just Chatting directory — only falling back to generic seeds when
    // that's all the channel has.
    let ranked = signals.rankedCategories
    let specific = ranked.filter { !ChannelContentService.isGeneric($0) }
    let seedSource = specific.isEmpty ? ranked : specific
    let seeds = Array(seedSource.prefix(seedCategoryCount))
    guard !seeds.isEmpty else { return [] }

    // Fetch candidate pools for each seed category in parallel.
    var pool: [CandidateStream] = []
    await withTaskGroup(of: [CandidateStream].self) { group in
      for category in seeds {
        group.addTask { await fetchCandidates(inCategory: category) }
      }
      for await candidates in group {
        pool.append(contentsOf: candidates)
      }
    }

    // Dedupe by login, keeping the higher-viewer instance, and drop the channel
    // itself.
    var byLogin: [String: CandidateStream] = [:]
    for candidate in pool {
      let key = candidate.login.lowercased()
      guard key != signals.login.lowercased() else { continue }
      if let existing = byLogin[key], existing.viewers >= candidate.viewers { continue }
      byLogin[key] = candidate
    }

    let scored = byLogin.values
      .map { (candidate: $0, score: score($0, against: signals)) }
      .sorted { $0.score > $1.score }
      .prefix(maxResults)

    return scored.map { $0.candidate.asFollowedChannel }
  }

  // MARK: - Scoring

  private static func score(_ candidate: CandidateStream, against signals: ChannelSignals) -> Double {
    let category = categoryAffinity(candidate, signals)
    let language = languageMatch(candidate, signals)
    let tags = tagOverlap(candidate, signals)
    let tier = tierSimilarity(candidate, signals)
    return category * categoryWeight
      + language * languageWeight
      + tags * tagWeight
      + tier * tierWeight
  }

  /// How central the candidate's current game is to the target's DNA (0...1).
  private static func categoryAffinity(_ candidate: CandidateStream, _ signals: ChannelSignals) -> Double {
    guard let game = candidate.gameName else { return 0 }
    return signals.categoryWeights[game] ?? 0
  }

  private static func languageMatch(_ candidate: CandidateStream, _ signals: ChannelSignals) -> Double {
    guard let target = signals.language, let other = candidate.language else { return 0 }
    return target.caseInsensitiveCompare(other) == .orderedSame ? 1 : 0
  }

  /// Jaccard similarity of freeform tags — captures shared "vibe" beyond category.
  private static func tagOverlap(_ candidate: CandidateStream, _ signals: ChannelSignals) -> Double {
    guard !signals.tags.isEmpty, !candidate.tags.isEmpty else { return 0 }
    let target = Set(signals.tags.map { $0.lowercased() })
    let other = Set(candidate.tags.map { $0.lowercased() })
    let intersection = target.intersection(other).count
    guard intersection > 0 else { return 0 }
    let union = target.union(other).count
    return Double(intersection) / Double(union)
  }

  /// Closeness in audience size on a log scale (0...1). Favors similarly-sized
  /// peers and downranks the few giant channels that top every category — the
  /// key to surfacing fresh, relevant recommendations.
  private static func tierSimilarity(_ candidate: CandidateStream, _ signals: ChannelSignals) -> Double {
    guard let target = signals.viewerTier, target > 0 else { return 0.5 }
    let a = log10(Double(target) + 1)
    let b = log10(Double(max(candidate.viewers, 0)) + 1)
    // ~2 orders of magnitude apart -> ~0 similarity.
    return max(0, 1 - abs(a - b) / 2.0)
  }

  // MARK: - Candidate fetch

  private static func fetchCandidates(inCategory category: String) async -> [CandidateStream] {
    let query = """
      query CategoryStreams($name: String!, $first: Int!) {
        game(name: $name) {
          streams(first: $first) {
            edges { node {
              id title viewersCount type
              previewImageURL(width: 320, height: 180)
              broadcaster {
                login displayName
                profileImageURL(width: 70)
                broadcastSettings { language }
              }
              game { name displayName }
              freeformTags { name }
            } }
          }
        }
      }
      """

    guard
      let data = try? await ChannelContentService.perform(
        query: query,
        variables: ["name": category, "first": candidatesPerCategory]
      ),
      let decoded = try? JSONDecoder().decode(CategoryEnvelope.self, from: data),
      let edges = decoded.data?.game?.streams?.edges
    else { return [] }

    return edges.compactMap { edge -> CandidateStream? in
      guard let node = edge.node,
            let broadcaster = node.broadcaster,
            let login = broadcaster.login?.trimmingCharacters(in: .whitespaces),
            !login.isEmpty
      else { return nil }

      return CandidateStream(
        id: node.id ?? login,
        login: login,
        displayName: broadcaster.displayName?.trimmingCharacters(in: .whitespaces) ?? login,
        title: node.title?.trimmingCharacters(in: .whitespaces) ?? "",
        gameName: node.game?.name?.trimmingCharacters(in: .whitespaces),
        gameDisplayName: node.game?.displayName?.trimmingCharacters(in: .whitespaces),
        viewers: node.viewersCount ?? 0,
        language: broadcaster.broadcastSettings?.language,
        tags: (node.freeformTags ?? []).compactMap { $0.name?.trimmingCharacters(in: .whitespaces) },
        thumbnailURL: node.previewImageURL.flatMap(URL.init(string:)),
        profileImageURL: broadcaster.profileImageURL.flatMap(URL.init(string:))
      )
    }
  }

  // MARK: - Types

  private struct CandidateStream: Sendable {
    let id: String
    let login: String
    let displayName: String
    let title: String
    let gameName: String?
    let gameDisplayName: String?
    let viewers: Int
    let language: String?
    let tags: [String]
    let thumbnailURL: URL?
    let profileImageURL: URL?

    var asFollowedChannel: FollowedChannel {
      FollowedChannel(
        id: id,
        login: login,
        displayName: displayName,
        title: title.isEmpty ? "Live now" : title,
        gameName: gameDisplayName ?? gameName ?? "Live",
        viewerCount: viewers,
        thumbnailURL: thumbnailURL,
        profileImageURL: profileImageURL,
        isLive: true,
        isMature: false
      )
    }
  }

  private struct CategoryEnvelope: Decodable { let data: CategoryData? }
  private struct CategoryData: Decodable { let game: GameConn? }
  private struct GameConn: Decodable { let streams: StreamsConn? }
  private struct StreamsConn: Decodable { let edges: [StreamEdge]? }
  private struct StreamEdge: Decodable { let node: StreamNode? }
  private struct StreamNode: Decodable {
    let id: String?
    let title: String?
    let viewersCount: Int?
    let type: String?
    let previewImageURL: String?
    let broadcaster: Broadcaster?
    let game: Game?
    let freeformTags: [Tag]?
  }
  private struct Broadcaster: Decodable {
    let login: String?
    let displayName: String?
    let profileImageURL: String?
    let broadcastSettings: BroadcastSettings?
  }
  private struct BroadcastSettings: Decodable { let language: String? }
  private struct Game: Decodable { let name: String?; let displayName: String? }
  private struct Tag: Decodable { let name: String? }
}
