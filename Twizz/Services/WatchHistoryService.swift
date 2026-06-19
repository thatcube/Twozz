import Foundation
import Observation

/// User-facing preference keys for personalization. Kept in a non-isolated enum
/// so SwiftUI `@AppStorage` and other call sites can reference the key without
/// touching the `@MainActor`-isolated service.
enum RecommendationPreferences {
  /// Whether personalized "Recommended for you" is on. Defaults to enabled.
  static let enabledDefaultsKey = "personalizedRecommendationsEnabled"
}

/// One channel the viewer has watched, used purely to personalize recommendations.
struct WatchHistoryEntry: Codable, Identifiable, Sendable {
  var id: String { login }
  var login: String
  var displayName: String
  var gameName: String
  var viewerCount: Int?
  var lastWatchedAt: Date
  var watchCount: Int
}

/// Records which channels the viewer watches so recommendations can reflect their
/// actual taste — **entirely on-device**.
///
/// Privacy: history is stored only in this device's `UserDefaults`, is never
/// transmitted to Twizz, Twitch, or any third party, and can be turned off or
/// wiped from Settings. Because nothing leaves the device, this requires no App
/// Tracking Transparency prompt and counts as "Data Not Collected" on the App
/// Store privacy label.
@MainActor
@Observable
final class WatchHistoryService {
  private static let storageKey = "watchHistoryEntriesV1"
  private static let maxEntries = 120
  /// Watches this old contribute half the weight of a fresh watch.
  private static let recencyHalfLife: TimeInterval = 14 * 24 * 3600

  private(set) var entries: [WatchHistoryEntry] = []

  /// On-device personalization switch, mirrored from `UserDefaults` so the
  /// Settings toggle and this service always agree. Defaults to on.
  var isEnabled: Bool {
    UserDefaults.standard.object(forKey: RecommendationPreferences.enabledDefaultsKey) as? Bool ?? true
  }

  init() {
    load()
  }

  /// Records a watch of `channel`. No-op when personalization is disabled or the
  /// channel has no login. Existing channels are bumped to most-recent.
  func record(_ channel: FollowedChannel) {
    guard isEnabled else { return }
    let login = channel.login.lowercased()
    guard !login.isEmpty else { return }

    let now = Date()
    if let index = entries.firstIndex(where: { $0.login == login }) {
      var entry = entries.remove(at: index)
      entry.lastWatchedAt = now
      entry.watchCount += 1
      entry.displayName = channel.displayName
      if !channel.gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        entry.gameName = channel.gameName
      }
      if let viewers = channel.viewerCount { entry.viewerCount = viewers }
      entries.insert(entry, at: 0)
    } else {
      entries.insert(
        WatchHistoryEntry(
          login: login,
          displayName: channel.displayName,
          gameName: channel.gameName,
          viewerCount: channel.viewerCount,
          lastWatchedAt: now,
          watchCount: 1
        ),
        at: 0
      )
    }

    if entries.count > Self.maxEntries {
      entries = Array(entries.prefix(Self.maxEntries))
    }
    persist()
  }

  /// Permanently forgets all watch history from this device.
  func clear() {
    entries = []
    persist()
  }

  /// Logins (lowercased) the viewer has watched, most-recent first.
  var recentLogins: [String] {
    entries.map(\.login)
  }

  /// Category name -> recency-weighted affinity (unnormalized). Recent, repeated
  /// watches of a category count for more, so the profile tracks current taste.
  func categoryAffinities(now: Date = Date()) -> [String: Double] {
    var weights: [String: Double] = [:]
    for entry in entries {
      let game = entry.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !game.isEmpty, game.caseInsensitiveCompare("live") != .orderedSame else { continue }
      let age = now.timeIntervalSince(entry.lastWatchedAt)
      let recency = pow(0.5, max(age, 0) / Self.recencyHalfLife)
      weights[game, default: 0] += recency * Double(max(entry.watchCount, 1))
    }
    return weights
  }

  /// Median concurrent-viewer count across watched channels, used to favor
  /// similarly-sized peers when ranking recommendations.
  var medianViewerTier: Int? {
    let counts = entries.compactMap(\.viewerCount).filter { $0 > 0 }.sorted()
    guard !counts.isEmpty else { return nil }
    let mid = counts.count / 2
    return counts.count.isMultiple(of: 2) ? (counts[mid - 1] + counts[mid]) / 2 : counts[mid]
  }

  // MARK: - Persistence (local UserDefaults only)

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode([WatchHistoryEntry].self, from: data)
    else { return }
    entries = decoded
  }

  /// Serial queue so JSON encoding and the UserDefaults write happen off the
  /// main thread (record() runs at playback start) while preserving write order.
  private static let persistQueue = DispatchQueue(
    label: "com.thatcube.Twizz.watchHistory.persist", qos: .utility)

  private func persist() {
    let snapshot = entries
    Self.persistQueue.async {
      guard let data = try? JSONEncoder().encode(snapshot) else { return }
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}
