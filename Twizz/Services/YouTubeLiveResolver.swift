import Foundation
import Observation

/// Resolves which of the signed-in viewer's *own* subscribed YouTube channels are
/// live right now, plus their concurrent viewers, using the cheap, ToS-compliant
/// path (no scraping): a channel's uploads playlist ID is derived deterministically
/// (`"UU" + channelID.dropFirst(2)`), `playlistItems.list` returns its most recent
/// video IDs (1 unit/channel), and a single batched `videos.list`
/// (`part=snippet,liveStreamingDetails`, 1 unit/50) reports which are currently
/// live and how many are watching.
///
/// **Why on-device here (vs. the shared snapshot used for Twitch-followed dual
/// streamers):** a viewer's arbitrary subscriptions aren't in the curated backend
/// catalog, so their liveness can't come from the public snapshot. These calls run
/// against the OAuth project's quota, so the channel count is capped and results
/// are throttled/cached — fine at personal scale.
@MainActor
@Observable
final class YouTubeLiveResolver {
  /// YouTube channel ID -> current live presence (only live channels are kept).
  private(set) var presences: [String: YouTubePresence] = [:]
  private(set) var isResolving = false

  /// Bound on how many subscriptions we check per refresh, to cap quota.
  private static let maxChannels = 200
  /// Most-recent uploads to inspect per channel (a live broadcast is normally the
  /// latest item, but a regular upload can sit on top of it).
  private static let recentPerChannel = 3
  /// Concurrent `playlistItems` requests in flight.
  private static let maxConcurrency = 8
  private static let minRefreshInterval: TimeInterval = 150
  private var lastRefresh: Date?

  func presence(forChannelID channelID: String) -> YouTubePresence? {
    presences[channelID]
  }

  /// Refreshes liveness for the given subscribed channel IDs. Throttled unless
  /// `force`. Silently keeps prior results on failure.
  func refresh(channelIDs: [String], using auth: YouTubeAuthSession, force: Bool = false) async {
    guard auth.isAuthenticated, !channelIDs.isEmpty else {
      presences = [:]
      return
    }
    if !force, let last = lastRefresh, Date().timeIntervalSince(last) < Self.minRefreshInterval {
      return
    }
    guard !isResolving else { return }
    isResolving = true
    defer { isResolving = false }

    let token: String
    do {
      token = try await auth.validAccessToken()
    } catch {
      return
    }

    // Only standard "UC" channel IDs have a deterministic "UU" uploads playlist.
    let targets = channelIDs
      .filter { $0.hasPrefix("UC") && $0.count > 2 }
      .prefix(Self.maxChannels)
    guard !targets.isEmpty else {
      presences = [:]
      return
    }

    let recentVideoIDs = await collectRecentVideoIDs(channels: Array(targets), token: token)
    guard !recentVideoIDs.isEmpty else {
      presences = [:]
      lastRefresh = Date()
      return
    }

    let live = await fetchLivePresences(videoIDs: recentVideoIDs, token: token)
    presences = live
    lastRefresh = Date()
  }

  // MARK: - Step 1: recent uploads per channel

  private func collectRecentVideoIDs(channels: [String], token: String) async -> [String] {
    await withTaskGroup(of: [String].self) { group in
      var collected: [String] = []
      var index = 0
      var active = 0

      func enqueueNext() {
        guard index < channels.count else { return }
        let channelID = channels[index]
        index += 1
        active += 1
        let playlistID = "UU" + channelID.dropFirst(2)
        group.addTask { [weak self] in
          await self?.recentVideoIDs(playlistID: playlistID, token: token) ?? []
        }
      }

      for _ in 0..<min(Self.maxConcurrency, channels.count) { enqueueNext() }

      while active > 0 {
        if let ids = await group.next() {
          collected.append(contentsOf: ids)
          active -= 1
          enqueueNext()
        }
      }
      return collected
    }
  }

  private func recentVideoIDs(playlistID: String, token: String) async -> [String] {
    var components = URLComponents(
      url: YouTubeConfig.apiBaseURL.appendingPathComponent("playlistItems"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "part", value: "contentDetails"),
      URLQueryItem(name: "playlistId", value: playlistID),
      URLQueryItem(name: "maxResults", value: String(Self.recentPerChannel)),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let decoded = try? YouTubeConfig.sharedDecoder.decode(PlaylistItemsResponse.self, from: data)
    else { return [] }

    return decoded.items.compactMap { $0.contentDetails.videoId }
  }

  // MARK: - Step 2: which of those videos are live now

  private func fetchLivePresences(videoIDs: [String], token: String) async -> [String: YouTubePresence] {
    var result: [String: YouTubePresence] = [:]
    // videos.list accepts up to 50 IDs per call.
    for batch in stride(from: 0, to: videoIDs.count, by: 50) {
      let slice = Array(videoIDs[batch..<min(batch + 50, videoIDs.count)])
      let videos = await fetchVideos(ids: slice, token: token)
      for video in videos where video.snippet?.liveBroadcastContent == "live" {
        guard let channelID = video.snippet?.channelId else { continue }
        // Keep the most-watched live video if a channel somehow has two.
        let viewers = video.liveStreamingDetails?.concurrentViewerCount
        let existing = result[channelID]
        if existing == nil || (viewers ?? 0) > (existing?.viewerCount ?? 0) {
          result[channelID] = YouTubePresence(
            channelID: channelID,
            isLive: true,
            viewerCount: viewers,
            videoID: video.id,
            title: video.snippet?.title)
        }
      }
    }
    return result
  }

  private func fetchVideos(ids: [String], token: String) async -> [VideosResponse.Item] {
    var components = URLComponents(
      url: YouTubeConfig.apiBaseURL.appendingPathComponent("videos"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "part", value: "snippet,liveStreamingDetails"),
      URLQueryItem(name: "id", value: ids.joined(separator: ",")),
      URLQueryItem(name: "maxResults", value: "50"),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let decoded = try? YouTubeConfig.sharedDecoder.decode(VideosResponse.self, from: data)
    else { return [] }
    return decoded.items
  }
}

// MARK: - Wire models

private struct PlaylistItemsResponse: Decodable {
  let items: [Item]
  struct Item: Decodable { let contentDetails: ContentDetails }
  struct ContentDetails: Decodable { let videoId: String? }
}

private struct VideosResponse: Decodable {
  let items: [Item]

  struct Item: Decodable {
    let id: String
    let snippet: Snippet?
    let liveStreamingDetails: LiveStreamingDetails?
  }

  struct Snippet: Decodable {
    let title: String?
    let channelId: String?
    let liveBroadcastContent: String?
  }

  struct LiveStreamingDetails: Decodable {
    let concurrentViewers: String?
    /// API returns concurrentViewers as a string; expose it as an Int.
    var concurrentViewerCount: Int? { concurrentViewers.flatMap { Int($0) } }
  }
}
