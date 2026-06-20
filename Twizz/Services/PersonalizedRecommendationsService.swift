import Foundation
import Observation

/// Powers the Home tab's "Recommended for you" rail with *genuinely personalized*
/// suggestions, not a top-streamers list.
///
/// It blends the viewer's signals — the categories of the channels they **follow**
/// and the categories they actually **watch** (recency-weighted, on-device) — into
/// a single "taste profile", then runs that profile through the same multi-signal
/// `SimilarChannelsEngine` used for "More like this". The result is live channels
/// similar to what the viewer already enjoys, with channels they already follow
/// removed (those have their own rail) and similarly-sized peers favored over the
/// few mega-streamers that top every directory.
@MainActor
@Observable
final class PersonalizedRecommendationsService {
  private(set) var channels: [FollowedChannel] = []
  private(set) var isLoading = false
  private(set) var lastUpdatedAt: Date?

  /// History is normalized independently and weighted more heavily than follows:
  /// what you actively choose to watch is a stronger, fresher taste signal than
  /// who you happen to follow. With both present at equal normalized strength,
  /// watching influences the profile ~2.5x as much as following.
  private static let followShare = 0.4
  private static let watchShare = 1.0
  /// Generic catch-all categories ("Just Chatting", etc.) say little about taste,
  /// so they're heavily discounted — same rationale as the channel-DNA engine.
  private static let genericWeight = 0.15

  /// At most this many "because you watch X" affinity picks lead the rail, so
  /// they sharpen results without drowning out category-based discovery.
  private static let maxAffinityPicks = 6
  /// How many of the viewer's channels seed the affinity expansion, and how many
  /// neighbor logins we'll check for being live — both bounded so the extra GQL
  /// lookup stays cheap.
  private static let maxAffinitySeeds = 10
  private static let maxAffinityCandidates = 30

  /// Rebuilds recommendations from the current follows and watch history. Clears
  /// the rail when personalization is disabled or there isn't enough signal yet.
  func refresh(
    follows: [FollowedChannel],
    followedCategories: [String: Int],
    followedLogins: Set<String>,
    history: WatchHistoryService,
    feedback: RecommendationFeedback = .empty,
    affinity: StreamerAffinityMap = .empty
  ) async {
    guard history.isEnabled else {
      channels = []
      lastUpdatedAt = Date()
      return
    }

    isLoading = true
    defer {
      isLoading = false
      lastUpdatedAt = Date()
    }

    let profile = Self.buildProfile(
      follows: follows, followedCategories: followedCategories, history: history)

    // Channels the viewer already follows or marked "Not interested" never
    // belong in the rail. Combine the full follow list (online + offline) with
    // the currently-live follows so nothing they follow can slip in.
    let exclude = followedLogins
      .union(follows.map { $0.login.lowercased() })
      .union(feedback.blockedLogins)

    // Two parallel sources:
    //  • Category engine — live peers that share the viewer's taste in *games*.
    //  • Affinity expansion — similar streamers of the channels the viewer
    //    actually watches, regardless of category (e.g. Ludwig → Squeex), from
    //    the "viewers of X also watch Y" graph. This is what lets a variety
    //    streamer surface a friend who streams something else entirely.
    let seedLogins = Self.affinitySeedLogins(follows: follows, history: history)
    let signals = ChannelSignals(
      login: "",
      categoryWeights: profile.categoryWeights,
      language: nil,
      tags: [],
      viewerTier: profile.viewerTier
    )

    async let categoryRecs: [FollowedChannel] = profile.categoryWeights.isEmpty
      ? []
      : SimilarChannelsEngine.recommend(
          using: signals, seedLimit: 6, resultLimit: 18, maxPerCategory: 3, feedback: feedback)
    async let affinityRecs: [FollowedChannel] = Self.affinityPicks(
      seedLogins: seedLogins, affinity: affinity, exclude: exclude)

    let recommended = await categoryRecs
    let picks = await affinityRecs

    // Lead with affinity picks (capped so they don't swamp the rail), then fill
    // with category-based peers, de-duplicating by login and dropping excludes.
    var seen = exclude
    var merged: [FollowedChannel] = []
    for channel in picks.prefix(Self.maxAffinityPicks) + recommended {
      let login = channel.login.lowercased()
      guard seen.insert(login).inserted else { continue }
      merged.append(channel)
      if merged.count >= 18 { break }
    }
    channels = merged
  }

  /// Immediately drops a channel from the current rail without a network refresh,
  /// so a "Not interested" tap removes the card instantly. A later refresh keeps
  /// it gone via the blocklist.
  func remove(login: String) {
    let key = login.lowercased()
    channels.removeAll { $0.login.lowercased() == key }
  }

  // MARK: - Affinity expansion ("viewers of X also watch Y")

  /// The viewer's most-watched and most-followed channels — the seeds whose
  /// similar streamers we expand into recommendations. Watched channels lead,
  /// since actively choosing to watch is the stronger taste signal.
  private static func affinitySeedLogins(
    follows: [FollowedChannel], history: WatchHistoryService
  ) -> [String] {
    let watched = history.entries
      .sorted { ($0.watchCount, $0.lastWatchedAt) > ($1.watchCount, $1.lastWatchedAt) }
      .map { $0.login.lowercased() }
    let followed = follows
      .sorted { ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) }
      .map { $0.login.lowercased() }

    var seeds: [String] = []
    var seen: Set<String> = []
    for login in watched + followed {
      guard !login.isEmpty, seen.insert(login).inserted else { continue }
      seeds.append(login)
      if seeds.count >= maxAffinitySeeds { break }
    }
    return seeds
  }

  /// Resolves the seeds' similar streamers (best-first, excluding follows/blocked)
  /// to those who are **live right now**, preserving affinity-priority order.
  private static func affinityPicks(
    seedLogins: [String], affinity: StreamerAffinityMap, exclude: Set<String>
  ) async -> [FollowedChannel] {
    guard !affinity.isEmpty, !seedLogins.isEmpty else { return [] }
    let seedSet = Set(seedLogins)

    var candidateOrder: [String] = []
    var seen: Set<String> = []
    for seed in seedLogins {
      for neighbor in affinity.similar(to: seed) {
        guard !exclude.contains(neighbor), !seedSet.contains(neighbor),
              seen.insert(neighbor).inserted
        else { continue }
        candidateOrder.append(neighbor)
        if candidateOrder.count >= maxAffinityCandidates { break }
      }
      if candidateOrder.count >= maxAffinityCandidates { break }
    }
    guard !candidateOrder.isEmpty else { return [] }

    let live = await SimilarChannelsEngine.liveChannels(forLogins: candidateOrder)
    let byLogin = Dictionary(
      live.map { ($0.login.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    return candidateOrder.compactMap { byLogin[$0] }
  }

  // MARK: - Taste profile

  private struct Profile {
    let categoryWeights: [String: Double]
    let viewerTier: Int?
  }

  private static func buildProfile(
    follows: [FollowedChannel],
    followedCategories: [String: Int],
    history: WatchHistoryService
  ) -> Profile {
    // Follow signal: prefer the full follow list (online + offline) when we have
    // it; otherwise fall back to the categories of currently-live follows.
    var followRaw: [String: Double] = [:]
    if followedCategories.isEmpty {
      for channel in follows {
        let game = channel.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !game.isEmpty, game.caseInsensitiveCompare("live") != .orderedSame else { continue }
        followRaw[game, default: 0] += 1
      }
    } else {
      for (game, count) in followedCategories {
        let name = game.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        followRaw[name, default: 0] += Double(count)
      }
    }

    // Normalize each signal to 0...1 on its own so the *relative* influence of
    // follows vs. watching is governed by the shares above, not by raw counts (a
    // category with 30 follows shouldn't automatically bury what you actually
    // watch).
    let normalizedFollows = normalize(followRaw)
    let normalizedHistory = normalize(history.categoryAffinities())

    var combined: [String: Double] = [:]
    for key in Set(normalizedFollows.keys).union(normalizedHistory.keys) {
      let value = followShare * (normalizedFollows[key] ?? 0)
        + watchShare * (normalizedHistory[key] ?? 0)
      combined[key] = value * (ChannelContentService.isGeneric(key) ? genericWeight : 1.0)
    }

    let weights = normalize(combined)
    return Profile(categoryWeights: weights, viewerTier: medianTier(follows: follows, history: history))
  }

  /// Scales a weight map so its strongest entry is 1.0; empty in, empty out.
  private static func normalize(_ weights: [String: Double]) -> [String: Double] {
    let maxWeight = weights.values.max() ?? 0
    return maxWeight > 0 ? weights.mapValues { $0 / maxWeight } : [:]
  }

  /// Median concurrent-viewer count across the channels the viewer follows and
  /// watches — the audience size their recommendations should gravitate toward.
  private static func medianTier(follows: [FollowedChannel], history: WatchHistoryService) -> Int? {
    var counts = follows.compactMap(\.viewerCount).filter { $0 > 0 }
    counts.append(contentsOf: history.entries.compactMap(\.viewerCount).filter { $0 > 0 })
    guard !counts.isEmpty else { return history.medianViewerTier }
    counts.sort()
    let mid = counts.count / 2
    return counts.count.isMultiple(of: 2) ? (counts[mid - 1] + counts[mid]) / 2 : counts[mid]
  }
}
