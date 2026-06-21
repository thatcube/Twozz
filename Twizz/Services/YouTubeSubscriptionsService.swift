import Foundation
import Observation

/// A YouTube channel the signed-in viewer is subscribed to.
struct YouTubeSubscription: Identifiable, Hashable {
  let channelID: String
  let title: String
  let thumbnailURL: URL?

  var id: String { channelID }
}

/// Fetches the signed-in viewer's YouTube subscriptions via
/// `subscriptions.list(mine=true)` (5 quota units per 50-channel page — cheap and
/// OAuth-gated). Returns the subscribed channel IDs so the rest of the app can
/// look up their live status from the shared `YouTubeLiveSnapshotService`
/// snapshot rather than calling the quota-heavy `search.list eventType=live`.
///
/// Results are cached on disk so a relaunch shows the directory immediately while
/// a fresh list loads in the background.
@MainActor
@Observable
final class YouTubeSubscriptionsService {
  private(set) var subscriptions: [YouTubeSubscription]
  private(set) var isLoading = false
  private(set) var lastError: String?

  private static let cacheFileName = "YouTubeSubscriptions.cache.json"
  /// Don't refetch the (slowly-changing) subscription list more than this often.
  private static let minFetchInterval: TimeInterval = 6 * 60 * 60
  private static let lastFetchDefaultsKey = PersistenceKey.youTubeSubscriptionsLastFetch
  private static let pageSize = 50

  init() {
    subscriptions = Self.loadCached() ?? []
  }

  /// True once we have any subscriptions to show (cached or freshly fetched).
  var hasSubscriptions: Bool { !subscriptions.isEmpty }

  /// Refreshes the subscription list from the API using the signed-in session.
  /// Throttled unless `force` is set. Silently keeps the cached list on failure.
  func refresh(using auth: YouTubeAuthSession, force: Bool = false) async {
    guard auth.isAuthenticated else {
      // Signed out: drop any stale cached list so the directory clears.
      subscriptions = []
      Self.clearCache()
      return
    }

    let defaults = UserDefaults.standard
    if !force, !subscriptions.isEmpty,
      let last = defaults.object(forKey: Self.lastFetchDefaultsKey) as? Date,
      Date().timeIntervalSince(last) < Self.minFetchInterval {
      return
    }

    guard !isLoading else { return }
    isLoading = true
    lastError = nil
    defer { isLoading = false }

    do {
      let token = try await auth.validAccessToken()
      let collected = try await fetchAllPages(accessToken: token)
      // Stable, case-insensitive alphabetical order for a predictable directory.
      subscriptions = collected.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      Self.writeCache(subscriptions)
      defaults.set(Date(), forKey: Self.lastFetchDefaultsKey)
    } catch {
      lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func fetchAllPages(accessToken: String) async throws -> [YouTubeSubscription] {
    var results: [YouTubeSubscription] = []
    var seen = Set<String>()
    var pageToken: String?
    // Cap pages so an enormous subscription list can't loop unbounded.
    var pagesRemaining = 40

    repeat {
      let page = try await fetchPage(accessToken: accessToken, pageToken: pageToken)
      for item in page.items {
        let channelID = item.snippet.resourceId.channelId
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty, seen.insert(channelID).inserted else { continue }
        results.append(
          YouTubeSubscription(
            channelID: channelID,
            title: item.snippet.title,
            thumbnailURL: item.snippet.thumbnails?.bestURL))
      }
      pageToken = page.nextPageToken
      pagesRemaining -= 1
    } while pageToken != nil && pagesRemaining > 0

    return results
  }

  private func fetchPage(accessToken: String, pageToken: String?) async throws -> SubscriptionsResponse {
    var components = URLComponents(
      url: YouTubeConfig.apiBaseURL.appendingPathComponent("subscriptions"),
      resolvingAgainstBaseURL: false)!
    var query = [
      URLQueryItem(name: "part", value: "snippet"),
      URLQueryItem(name: "mine", value: "true"),
      URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
      URLQueryItem(name: "order", value: "alphabetical"),
    ]
    if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    components.queryItems = query

    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20

    let (data, response) = try await NetworkClient.api.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      let message = String(data: data, encoding: .utf8)
      throw YouTubeAuthHTTPError(
        context: "fetching YouTube subscriptions", status: status, error: nil, message: message)
    }
    return try YouTubeConfig.sharedDecoder.decode(SubscriptionsResponse.self, from: data)
  }

  // MARK: - Caching

  private struct CacheEntry: Codable {
    let channelID: String
    let title: String
    let thumbnail: String?
  }

  private static func writeCache(_ subscriptions: [YouTubeSubscription]) {
    guard let url = cacheURL else { return }
    let entries = subscriptions.map {
      CacheEntry(channelID: $0.channelID, title: $0.title, thumbnail: $0.thumbnailURL?.absoluteString)
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private static func loadCached() -> [YouTubeSubscription]? {
    guard let url = cacheURL, let data = try? Data(contentsOf: url),
      let entries = try? YouTubeConfig.sharedDecoder.decode([CacheEntry].self, from: data)
    else { return nil }
    return entries.map {
      YouTubeSubscription(
        channelID: $0.channelID, title: $0.title, thumbnailURL: $0.thumbnail.flatMap(URL.init(string:)))
    }
  }

  private static func clearCache() {
    guard let url = cacheURL else { return }
    try? FileManager.default.removeItem(at: url)
    UserDefaults.standard.removeObject(forKey: lastFetchDefaultsKey)
  }

  private static var cacheURL: URL? {
    guard
      let dir = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    return dir.appendingPathComponent(cacheFileName)
  }
}

// MARK: - Wire models

private struct SubscriptionsResponse: Decodable {
  let items: [Item]
  let nextPageToken: String?

  struct Item: Decodable {
    let snippet: Snippet
  }

  struct Snippet: Decodable {
    let title: String
    let resourceId: ResourceId
    let thumbnails: Thumbnails?
  }

  struct ResourceId: Decodable {
    let channelId: String
  }

  struct Thumbnails: Decodable {
    let `default`: Thumb?
    let medium: Thumb?
    let high: Thumb?

    /// Highest-resolution thumbnail available.
    var bestURL: URL? {
      (high ?? medium ?? `default`)?.url.flatMap(URL.init(string:))
    }
  }

  struct Thumb: Decodable {
    let url: String?
  }
}
