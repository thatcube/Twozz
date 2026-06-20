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
  /// How hard a title that echoes streams the viewer rejected is pushed down.
  /// Deliberately conservative: a strong title match roughly cancels a perfect
  /// category match, enough to bury a rejected look-alike without nuking an
  /// otherwise great recommendation over one shared word.
  private static let titlePenaltyWeight = 0.5

  private static let seedCategoryCount = 3
  private static let candidatesPerCategory = 40
  private static let maxResults = 12

  /// Returns recommended live channels ranked by similarity to the channel
  /// described by `signals`. Returns an empty list if there is not enough signal
  /// (e.g. a brand-new channel with no broadcast history).
  ///
  /// - Parameters:
  ///   - seedLimit: How many of the channel's top categories to search from.
  ///   - resultLimit: Maximum channels to return.
  ///   - maxPerCategory: When set, no single category may occupy more than this
  ///     many slots — diversifying rails that would otherwise be swept by the
  ///     viewer's single strongest category. `nil` keeps the pure score ranking.
  ///   - feedback: The viewer's "Not interested" signal. Blocklisted channels are
  ///     dropped outright; titles echoing rejected streams are down-ranked.
  ///
  /// Results are always filtered to the viewer's `StreamLanguagePreference` (a
  /// hard filter — unlike the soft language *score*), so an English-only viewer
  /// never sees, say, French GTA streams just because the category matches.
  static func recommend(
    using signals: ChannelSignals,
    seedLimit: Int = seedCategoryCount,
    resultLimit: Int = maxResults,
    maxPerCategory: Int? = nil,
    feedback: RecommendationFeedback = .empty
  ) async -> [FollowedChannel] {
    // Seed the search from the channel's most defining categories. Prefer its
    // *specific* niches over generic catch-alls (Just Chatting, etc.) so a
    // sanctuary seeds from "Animals, Aquariums, and Zoos" rather than the
    // sprawling Just Chatting directory — only falling back to generic seeds when
    // that's all the channel has.
    let ranked = signals.rankedCategories
    let specific = ranked.filter { !ChannelContentService.isGeneric($0) }
    let seedSource = specific.isEmpty ? ranked : specific
    let seeds = Array(seedSource.prefix(max(seedLimit, 1)))
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
    // itself plus any channels the viewer marked "Not interested".
    var byLogin: [String: CandidateStream] = [:]
    for candidate in pool {
      let key = candidate.login.lowercased()
      guard key != signals.login.lowercased() else { continue }
      guard !feedback.blockedLogins.contains(key) else { continue }
      if let existing = byLogin[key], existing.viewers >= candidate.viewers { continue }
      byLogin[key] = candidate
    }

    // Hard language filter: keep only streams in the viewer's chosen language
    // (Twitch returns `broadcastSettings.language` as an uppercase enum token, so
    // these compare directly). Streams with an unknown language are dropped while
    // a filter is active so non-matching streams can't leak through.
    let requiredLanguage = StreamLanguagePreference.currentToken()
    let candidates = byLogin.values.filter { candidate in
      guard let required = requiredLanguage else { return true }
      return candidate.language?.uppercased() == required
    }

    let ranking = candidates
      .map { (candidate: $0, score: score($0, against: signals, feedback: feedback)) }
      .sorted { $0.score > $1.score }

    let selected = select(from: ranking, limit: resultLimit, maxPerCategory: maxPerCategory)
    return selected.map { $0.candidate.asFollowedChannel }
  }

  /// Applies the optional per-category diversity cap to a score-ranked list,
  /// backfilling by score if the cap leaves fewer than `limit` results.
  private static func select(
    from ranked: [(candidate: CandidateStream, score: Double)],
    limit: Int,
    maxPerCategory: Int?
  ) -> [(candidate: CandidateStream, score: Double)] {
    guard let cap = maxPerCategory, cap > 0 else {
      return Array(ranked.prefix(limit))
    }

    var counts: [String: Int] = [:]
    var picked: [(candidate: CandidateStream, score: Double)] = []
    for item in ranked {
      guard picked.count < limit else { break }
      let key = (item.candidate.gameName ?? item.candidate.gameDisplayName ?? "").lowercased()
      if counts[key, default: 0] >= cap { continue }
      counts[key, default: 0] += 1
      picked.append(item)
    }

    if picked.count < limit {
      let pickedLogins = Set(picked.map { $0.candidate.login.lowercased() })
      for item in ranked where !pickedLogins.contains(item.candidate.login.lowercased()) {
        guard picked.count < limit else { break }
        picked.append(item)
      }
    }
    return picked
  }

  // MARK: - Scoring

  private static func score(
    _ candidate: CandidateStream,
    against signals: ChannelSignals,
    feedback: RecommendationFeedback
  ) -> Double {
    let category = categoryAffinity(candidate, signals)
    let language = languageMatch(candidate, signals)
    let tags = tagOverlap(candidate, signals)
    let tier = tierSimilarity(candidate, signals)
    let positive = category * categoryWeight
      + language * languageWeight
      + tags * tagWeight
      + tier * tierWeight
    return positive - titlePenalty(candidate, feedback) * titlePenaltyWeight
  }

  /// How strongly the candidate's title echoes streams the viewer rejected
  /// (0...1). Saturates at three shared distinctive words so a single coincidental
  /// match nudges rather than buries, while a title that clearly mirrors a
  /// rejected one is fully penalized.
  private static func titlePenalty(_ candidate: CandidateStream, _ feedback: RecommendationFeedback) -> Double {
    guard !feedback.mutedTitleTokens.isEmpty, !candidate.title.isEmpty else { return 0 }
    let tokens = RecommendationFeedbackService.tokens(in: candidate.title)
    guard !tokens.isEmpty else { return 0 }
    let matches = tokens.filter { feedback.mutedTitleTokens[$0] != nil }.count
    guard matches > 0 else { return 0 }
    return min(1, Double(matches) / 3.0)
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

  /// Looks up which of `logins` are **live right now** and returns them as
  /// recommendation cards. Used by affinity expansion ("because you watch X")
  /// to surface a watched channel's similar streamers regardless of category.
  /// Applies the same hard `StreamLanguagePreference` filter as the main engine.
  static func liveChannels(forLogins logins: [String]) async -> [FollowedChannel] {
    let unique = Array(Set(logins.map { $0.lowercased() }.filter { !$0.isEmpty })).prefix(90)
    guard !unique.isEmpty else { return [] }

    let query = """
      query AffinityLive($logins: [String!]) {
        users(logins: $logins) {
          login displayName
          profileImageURL(width: 70)
          broadcastSettings { language }
          stream {
            id title viewersCount
            previewImageURL(width: 320, height: 180)
            game { name displayName }
            freeformTags { name }
          }
        }
      }
      """

    guard
      let data = try? await ChannelContentService.perform(
        query: query, variables: ["logins": Array(unique)]),
      let decoded = try? JSONDecoder().decode(UsersEnvelope.self, from: data),
      let users = decoded.data?.users
    else { return [] }

    let requiredLanguage = StreamLanguagePreference.currentToken()

    return users.compactMap { user -> FollowedChannel? in
      guard let user,
            let login = user.login?.trimmingCharacters(in: .whitespaces), !login.isEmpty,
            let stream = user.stream
      else { return nil }

      if let required = requiredLanguage,
         user.broadcastSettings?.language?.uppercased() != required {
        return nil
      }

      let title = stream.title?.trimmingCharacters(in: .whitespaces) ?? ""
      return FollowedChannel(
        id: stream.id ?? login,
        login: login,
        displayName: user.displayName?.trimmingCharacters(in: .whitespaces) ?? login,
        title: title.isEmpty ? "Live now" : title,
        gameName: stream.game?.displayName?.trimmingCharacters(in: .whitespaces)
          ?? stream.game?.name?.trimmingCharacters(in: .whitespaces) ?? "Live",
        viewerCount: stream.viewersCount,
        thumbnailURL: stream.previewImageURL.flatMap(URL.init(string:)),
        profileImageURL: user.profileImageURL.flatMap(URL.init(string:)),
        isLive: true,
        isMature: false
      )
    }
  }

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

  private struct UsersEnvelope: Decodable { let data: UsersData? }
  private struct UsersData: Decodable { let users: [AffinityUser?]? }
  private struct AffinityUser: Decodable {
    let login: String?
    let displayName: String?
    let profileImageURL: String?
    let broadcastSettings: BroadcastSettings?
    let stream: AffinityStream?
  }
  private struct AffinityStream: Decodable {
    let id: String?
    let title: String?
    let viewersCount: Int?
    let previewImageURL: String?
    let game: Game?
    let freeformTags: [Tag]?
  }
}
