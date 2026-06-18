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

  /// Rebuilds recommendations from the current follows and watch history. Clears
  /// the rail when personalization is disabled or there isn't enough signal yet.
  func refresh(
    follows: [FollowedChannel],
    followedCategories: [String: Int],
    history: WatchHistoryService
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
    guard !profile.categoryWeights.isEmpty else {
      channels = []
      return
    }

    let signals = ChannelSignals(
      login: "",
      categoryWeights: profile.categoryWeights,
      language: nil,
      tags: [],
      viewerTier: profile.viewerTier
    )

    // Diversify: draw from more of the viewer's top categories and cap any single
    // category, so the rail isn't swept by their strongest one (e.g. all GTA V).
    let recommended = await SimilarChannelsEngine.recommend(
      using: signals,
      seedLimit: 6,
      resultLimit: 18,
      maxPerCategory: 3
    )

    // Don't recommend channels the viewer already follows or is currently being
    // shown elsewhere on Home — those live in the Following rail.
    let exclude = Set(follows.map { $0.login.lowercased() })
    channels = recommended.filter { !exclude.contains($0.login.lowercased()) }
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
