import Foundation
import Observation

/// Resolves the *live concurrent viewer* count ("watching now") for a YouTube
/// live broadcast from its public watch page, so a dual-platform streamer's Home
/// card can sum YouTube viewers even when the shared `youtube-live.json` snapshot
/// shipped a `null` viewer count (the official `videos.list` endpoint the CI
/// generator uses frequently omits `liveStreamingDetails.concurrentViewers`).
///
/// **Why scrape, and why anonymous:** YouTube's official concurrent-viewer field
/// is unreliable and per-project quota-bound, so it can't be polled per device.
/// The public watch page exposes the same number the web player shows in
/// `ytInitialData` as `"originalViewCount"`, gated by `"isLiveNow":true`. The
/// request is parameter-free and anonymous — no API key, no per-user OAuth, no
/// viewer data uploaded — so it preserves the app's "Data Not Collected" posture
/// and scales to any number of users (mirroring the existing anonymous watch-page
/// routes in `AltSourceService`/`ChatService+YouTube`).
///
/// **Bounded by design:** only the handful of tracked streamers who are *live on
/// YouTube right now* are ever fetched, capped at `maxVideos`, run at most
/// `maxConcurrency` at a time, and each video's count is cached and re-fetched no
/// more often than `minRefreshInterval`. The enrichment runs as part of the
/// existing throttled presence refresh, never per card render.
@MainActor
@Observable
final class YouTubeConcurrentViewersService {
  /// Live video ID -> most recently scraped concurrent viewer count.
  private(set) var counts: [String: Int] = [:]

  /// Hard cap on how many live videos we scrape per refresh.
  private static let maxVideos = 60
  /// Concurrent watch-page fetches in flight.
  private static let maxConcurrency = 6
  /// Don't re-scrape the same video more often than this.
  private static let minRefreshInterval: TimeInterval = 90
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  /// When each video's count was last fetched, to honor `minRefreshInterval`.
  private var lastFetched: [String: Date] = [:]

  /// The cached concurrent viewer count for a live video ID, if known.
  func count(forVideoID videoID: String) -> Int? { counts[videoID] }

  /// Scrapes concurrent viewers for the given live video IDs, skipping any
  /// fetched within `minRefreshInterval` (unless `force`). Bounded in volume and
  /// concurrency; silently keeps prior values on any failure so a transient
  /// network hiccup never wipes a card's YouTube count.
  func refresh(videoIDs: [String], force: Bool = false) async {
    let now = Date()
    var seen = Set<String>()
    let unique = videoIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
    let targets = unique
      .filter { id in
        force || lastFetched[id].map { now.timeIntervalSince($0) >= Self.minRefreshInterval } ?? true
      }
      .prefix(Self.maxVideos)
    guard !targets.isEmpty else {
      pruneStale(keeping: Set(unique))
      return
    }

    let resolved = await withTaskGroup(of: (String, Int?).self) { group in
      var collected: [(String, Int?)] = []
      var iterator = targets.makeIterator()
      var inFlight = 0

      func enqueueNext() {
        guard let id = iterator.next() else { return }
        inFlight += 1
        group.addTask { (id, await Self.fetchConcurrentViewers(videoID: id)) }
      }

      for _ in 0..<min(Self.maxConcurrency, targets.count) { enqueueNext() }
      while inFlight > 0 {
        if let pair = await group.next() {
          collected.append(pair)
          inFlight -= 1
          enqueueNext()
        }
      }
      return collected
    }

    for (id, count) in resolved {
      lastFetched[id] = now
      if let count { counts[id] = count }
    }
    // Drop counts for videos no longer reported live so stale numbers can't
    // linger across refreshes.
    pruneStale(keeping: Set(unique))
  }

  private func pruneStale(keeping live: Set<String>) {
    counts = counts.filter { live.contains($0.key) }
    lastFetched = lastFetched.filter { live.contains($0.key) }
  }

  // MARK: - Watch-page scrape

  /// Fetches the public watch page for `videoID` and returns its concurrent
  /// viewer count, but only when the page reports the broadcast is live now —
  /// otherwise `originalViewCount` would be a *total* view count, not viewers.
  private static func fetchConcurrentViewers(videoID: String) async -> Int? {
    guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
    else { return nil }

    let html = String(decoding: data, as: UTF8.self)
    guard firstMatch(in: html, pattern: "\"isLiveNow\":true") != nil else { return nil }
    if let raw = firstMatch(in: html, pattern: "\"originalViewCount\":\"([0-9]+)\""),
      let value = Int(raw), value > 0 {
      return value
    }
    // Fallback: the localized "N watching now" run if the machine field moves.
    if let raw = firstMatch(
      in: html, pattern: "\"runs\":\\[\\{\"text\":\"([0-9,]+)\"\\},\\{\"text\":\" watching now\""),
      let value = Int(raw.replacingOccurrences(of: ",", with: "")) {
      return value
    }
    return nil
  }

  /// Returns the first capture group of `pattern` in `text`, or the whole match
  /// when the pattern has no capture group.
  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
    guard let resolved = Range(group, in: text) else { return nil }
    return String(text[resolved])
  }
}
