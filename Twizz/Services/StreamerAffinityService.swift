import Foundation
import Observation

/// A snapshot of streamer→similar-streamer relationships, passed into the
/// recommendation engine. Plain `Sendable` value so it can cross into the
/// engine's `async` work off the `@MainActor` service.
struct StreamerAffinityMap: Sendable {
  /// Lowercased login -> ordered list of similar lowercased logins.
  let neighbors: [String: [String]]

  static let empty = StreamerAffinityMap(neighbors: [:])

  var isEmpty: Bool { neighbors.isEmpty }

  /// Similar logins for `login`, best-first; empty when the channel is unmapped.
  func similar(to login: String) -> [String] {
    neighbors[login.lowercased()] ?? []
  }
}

/// Supplies the "viewers of X also watch Y" affinity graph that lets
/// recommendations jump across categories (e.g. Ludwig → Squeex) instead of
/// relying on shared game alone.
///
/// The graph is generated off-device (a monthly GitHub Action regenerates it
/// from the current top streamers and publishes a static JSON), so the data
/// stays fresh without an app update. The app only ever **downloads a public
/// static file** — it never uploads what the viewer watches — so this keeps the
/// app's "Data Not Collected" privacy posture.
///
/// Resolution order: freshly-fetched remote (cached on disk) → last cached →
/// the curated copy bundled with the app. So it always has *something* offline.
@MainActor
@Observable
final class StreamerAffinityService {
  /// Public, CDN-backed static file regenerated monthly by CI on the `data`
  /// branch. Parameter-free GET — no viewer data is ever sent.
  private static let remoteURL = URL(
    string: "https://raw.githubusercontent.com/thatcube/Twizz/data/streamer-affinity.json")!
  private static let bundledResource = "StreamerAffinity"
  private static let cacheFileName = "StreamerAffinity.cache.json"
  private static let etagDefaultsKey = "streamerAffinityETag"
  private static let lastFetchDefaultsKey = "streamerAffinityLastFetch"
  /// Don't re-check the remote more than once a day; the data changes monthly.
  private static let minFetchInterval: TimeInterval = 24 * 3600

  private(set) var map: StreamerAffinityMap = .empty

  init() {
    map = Self.loadCached() ?? Self.loadBundled() ?? .empty
  }

  /// Conditionally refreshes from the remote (throttled, ETag-aware). Falls back
  /// silently to whatever is already loaded on any failure — recommendations
  /// must never block on this.
  func refreshIfNeeded() async {
    let defaults = UserDefaults.standard
    if let last = defaults.object(forKey: Self.lastFetchDefaultsKey) as? Date,
       Date().timeIntervalSince(last) < Self.minFetchInterval {
      return
    }

    var request = URLRequest(url: Self.remoteURL)
    request.timeoutInterval = 12
    if let etag = defaults.string(forKey: Self.etagDefaultsKey) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return }

    // Mark the attempt regardless so a flaky remote can't hammer every launch.
    defaults.set(Date(), forKey: Self.lastFetchDefaultsKey)

    guard http.statusCode == 200 else { return }  // 304 -> keep current map
    guard let document = Self.decode(data), !document.neighbors.isEmpty else { return }

    Self.writeCache(data)
    if let etag = http.value(forHTTPHeaderField: "ETag") {
      defaults.set(etag, forKey: Self.etagDefaultsKey)
    }
    map = document
  }

  var snapshot: StreamerAffinityMap { map }

  // MARK: - Loading

  private struct Document: Decodable {
    let map: [String: [String]]
  }

  /// Parses an affinity document and normalizes every login to lowercase,
  /// dropping empty keys and self-references.
  private static func decode(_ data: Data) -> StreamerAffinityMap? {
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
    var neighbors: [String: [String]] = [:]
    for (rawKey, rawValues) in document.map {
      let key = rawKey.lowercased()
      guard !key.isEmpty else { continue }
      var seen: Set<String> = [key]
      var values: [String] = []
      for value in rawValues {
        let login = value.lowercased()
        guard !login.isEmpty, seen.insert(login).inserted else { continue }
        values.append(login)
      }
      guard !values.isEmpty else { continue }
      neighbors[key] = values
    }
    return neighbors.isEmpty ? nil : StreamerAffinityMap(neighbors: neighbors)
  }

  private static func loadBundled() -> StreamerAffinityMap? {
    guard let url = Bundle.main.url(forResource: bundledResource, withExtension: "json"),
          let data = try? Data(contentsOf: url)
    else { return nil }
    return decode(data)
  }

  private static func loadCached() -> StreamerAffinityMap? {
    guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
    return decode(data)
  }

  private static var cacheURL: URL? {
    guard let dir = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    return dir.appendingPathComponent(cacheFileName)
  }

  private static func writeCache(_ data: Data) {
    guard let url = cacheURL else { return }
    try? data.write(to: url, options: .atomic)
  }
}
