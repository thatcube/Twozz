import Foundation
import Observation

/// A snapshot of the viewer's "not interested" feedback, passed into the
/// recommendation engine. A plain `Sendable` value so it can cross into the
/// engine's `async` candidate scoring without touching the `@MainActor` service.
struct RecommendationFeedback: Sendable {
  /// Channel logins (lowercased) the viewer explicitly marked "Not interested".
  /// Removed from every recommendation rail.
  var blockedLogins: Set<String>
  /// Distinctive title words drawn from rejected streams -> accumulated weight.
  /// Used as a *soft* negative signal: candidates whose titles share these words
  /// are down-ranked, so a stream the viewer rejected doesn't keep resurfacing
  /// under a different channel.
  var mutedTitleTokens: [String: Double]

  static let empty = RecommendationFeedback(blockedLogins: [], mutedTitleTokens: [:])

  var isEmpty: Bool { blockedLogins.isEmpty && mutedTitleTokens.isEmpty }
}

/// Records the viewer's "Not interested" feedback on recommended channels so the
/// recommendation engine can stop surfacing them — **entirely on-device**.
///
/// Privacy: like watch history, this lives only in this device's `UserDefaults`,
/// is never transmitted anywhere, and can be wiped from Settings.
@MainActor
@Observable
final class RecommendationFeedbackService {
  private static let storageKey = "recommendationFeedbackV1"
  /// Keep the muted-token map bounded so it can't grow without limit; the
  /// lowest-weight tokens are dropped first when over the cap.
  private static let maxMutedTokens = 240
  /// Title words shorter than this carry too little meaning to mute on.
  private static nonisolated let minTokenLength = 4

  private(set) var blockedLogins: Set<String> = []
  private(set) var mutedTitleTokens: [String: Double] = [:]

  /// Common words that say nothing about a stream's subject, so muting on them
  /// would wrongly penalize unrelated streams.
  private static nonisolated let stopwords: Set<String> = [
    "the", "and", "for", "with", "your", "you", "this", "that", "live", "now",
    "stream", "streaming", "today", "playing", "play", "come", "lets", "road",
    "from", "have", "just", "more", "here", "what", "when", "will", "want",
    "back", "time", "watch", "game", "games", "gameplay", "twitch", "chat",
    "vods", "first", "best", "good", "night", "day", "week", "新", "での",
  ]

  init() {
    load()
  }

  /// Marks `channel` as "Not interested": blocklists its login and learns the
  /// distinctive words from its title as a soft negative signal.
  func markNotInterested(_ channel: FollowedChannel) {
    let login = channel.login.lowercased()
    guard !login.isEmpty else { return }

    blockedLogins.insert(login)
    for token in Self.tokens(in: channel.title) {
      mutedTitleTokens[token, default: 0] += 1
    }
    trimTokensIfNeeded()
    persist()
  }

  /// Forgets all "Not interested" feedback on this device.
  func clear() {
    guard !blockedLogins.isEmpty || !mutedTitleTokens.isEmpty else { return }
    blockedLogins = []
    mutedTitleTokens = [:]
    persist()
  }

  var hasFeedback: Bool { !blockedLogins.isEmpty || !mutedTitleTokens.isEmpty }

  func isBlocked(_ login: String) -> Bool {
    blockedLogins.contains(login.lowercased())
  }

  /// Immutable snapshot handed to the recommendation engine.
  var snapshot: RecommendationFeedback {
    RecommendationFeedback(blockedLogins: blockedLogins, mutedTitleTokens: mutedTitleTokens)
  }

  // MARK: - Title tokenization

  /// Splits a stream title into distinctive lowercase word tokens, dropping
  /// stopwords, short words, and pure numbers. Shared with the engine so the
  /// learned tokens and the candidate tokens are compared on equal footing.
  static nonisolated func tokens(in title: String) -> Set<String> {
    let lowered = title.lowercased()
    var result: Set<String> = []
    for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
      let token = String(raw)
      guard token.count >= minTokenLength else { continue }
      guard !stopwords.contains(token) else { continue }
      guard token.contains(where: { $0.isLetter }) else { continue }
      result.insert(token)
    }
    return result
  }

  private func trimTokensIfNeeded() {
    guard mutedTitleTokens.count > Self.maxMutedTokens else { return }
    let kept = mutedTitleTokens
      .sorted { $0.value > $1.value }
      .prefix(Self.maxMutedTokens)
    mutedTitleTokens = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
  }

  // MARK: - Persistence (local UserDefaults only)

  private struct Stored: Codable {
    var blockedLogins: [String]
    var mutedTitleTokens: [String: Double]
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode(Stored.self, from: data)
    else { return }
    blockedLogins = Set(decoded.blockedLogins)
    mutedTitleTokens = decoded.mutedTitleTokens
  }

  private func persist() {
    let stored = Stored(
      blockedLogins: Array(blockedLogins), mutedTitleTokens: mutedTitleTokens)
    guard let data = try? JSONEncoder().encode(stored) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}
