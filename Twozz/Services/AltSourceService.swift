import Foundation

/// Resolves a streamer's *alternate-platform* live stream to an HLS master URL
/// playable by AVPlayer, so the player can offer a lower-latency source than the
/// proxied Twitch path when a streamer simulcasts.
///
/// Uses YouTube's public player response for native HLS. No API key, login,
/// challenge solving, manifest rewriting, or restreaming.
enum AltSourceService {
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  // ANDROID_VR 1.65.10 now fails with HTTP 403 after ~30 seconds. Use the
  // maintained native-HLS profile instead (yt-dlp PR #17461). Keep API and
  // media identities together; a resolved manifest alone does not prove its
  // segments will remain playable.
  private static let nativeClientVersion = "1.02"
  private static let nativeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

  static let mediaHTTPHeaders = ["User-Agent": nativeUserAgent]
  static let resolverAttributes = [
    "resolver_client": "VISIONOS",
    "resolver_client_version": nativeClientVersion,
  ]

  enum ResolutionError: LocalizedError {
    case invalidTarget
    case noLiveVideo
    case httpStatus(Int)
    case notPlayable(String)
    case noNativeHLS
    case invalidManifest

    var errorDescription: String? {
      switch self {
      case .invalidTarget, .noLiveVideo, .noNativeHLS:
        return String(localized: "Couldn't find a live video stream for this channel.")
      case .httpStatus(let status):
        return String(localized: "YouTube request failed (HTTP \(status)).")
      case .notPlayable:
        return String(localized: "YouTube isn't allowing playback of this stream.")
      case .invalidManifest:
        return String(localized: "YouTube returned an invalid live stream.")
      }
    }
  }

  /// A resolved YouTube live source: the playable HLS master (when live) and the
  /// concurrent "watching now" viewer count, both derived from a single fetch.
  struct YouTubeLive {
    var hlsMaster: URL
    var concurrentViewers: Int?
  }

  /// Resolves a YouTube target (handle, channel URL, watch URL, or 11-char video
  /// id) to its currently-live HLS master playlist URL.
  static func youtubeHLSMaster(forTarget target: String) async throws -> URL {
    try await youtubeLive(forTarget: target).hlsMaster
  }

  /// Resolves a YouTube target to both its live HLS master and concurrent viewer
  /// count. The live watch page is fetched once and reused for the visitor token,
  /// and the "watching now" count — so surfacing viewers
  /// adds no extra network request over resolving the source, and stays on the
  /// free public web/InnerTube path (never the metered YouTube Data API).
  /// Rejections propagate rather than silently selecting the web manifest,
  /// whose media can be rejected after initially successful playback.
  static func youtubeLive(forTarget target: String) async throws -> YouTubeLive {
    let videoID = try await resolveLiveVideoID(from: target)
    let watchHTML = try await watchPageHTML(forVideoID: videoID)
    let viewers = concurrentViewers(inWatchHTML: watchHTML)
    let visitor = firstMatch(in: watchHTML, pattern: "\"visitorData\":\"([^\"]+)\"")
    let request = try nativePlayerRequest(forVideoID: videoID, visitor: visitor)
    let data = try await responseData(for: request)
    let master = try nativeHLSMaster(in: data)
    return YouTubeLive(hlsMaster: master, concurrentViewers: viewers)
  }

  // MARK: - Video resolution

  private static func resolveLiveVideoID(from input: String) async throws -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let direct = extractVideoID(from: trimmed) { return direct }

    guard !trimmed.isEmpty, let lookup = liveLookupURL(from: trimmed) else {
      throw ResolutionError.invalidTarget
    }
    var request = URLRequest(url: lookup)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    let (data, response) = try await NetworkClient.api.data(for: request)
    try validate(response)

    if let finalURL = response.url?.absoluteString, let id = extractVideoID(from: finalURL) {
      return id
    }
    let html = String(decoding: data, as: UTF8.self)
    guard let id = firstMatch(in: html, pattern: "\"videoId\":\"([A-Za-z0-9_-]{11})\"") else {
      throw ResolutionError.noLiveVideo
    }
    return id
  }

  private static func liveLookupURL(from input: String) -> URL? {
    if input.hasPrefix("http") {
      if input.contains("/live") { return URL(string: input) }
      let sep = input.hasSuffix("/") ? "" : "/"
      return URL(string: input + sep + "live")
    }
    let handle = input.hasPrefix("@") ? input : "@\(input)"
    return URL(string: "https://www.youtube.com/\(handle)/live")
  }

  private static func extractVideoID(from string: String) -> String? {
    if string.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
      return string
    }
    if let id = firstMatch(in: string, pattern: "[?&]v=([A-Za-z0-9_-]{11})") { return id }
    if let id = firstMatch(in: string, pattern: "youtu\\.be/([A-Za-z0-9_-]{11})") { return id }
    return nil
  }

  // MARK: - Manifest extraction

  static func nativePlayerRequest(forVideoID videoID: String, visitor: String?) throws -> URLRequest {
    var client: [String: Any] = [
      "clientName": "VISIONOS",
      "clientVersion": nativeClientVersion,
      "deviceMake": "Apple",
      "deviceModel": "RealityDevice17,1",
      "osName": "visionOS",
      "osVersion": "26.5.23O471",
      "hl": "en",
      "gl": "US",
      "userAgent": nativeUserAgent,
    ]
    if let visitor { client["visitorData"] = visitor }
    let body: [String: Any] = [
      "context": ["client": client],
      "videoId": videoID,
      "contentCheckOk": true,
      "racyCheckOk": true,
    ]
    var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(nativeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(nativeClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")

    return request
  }

  static func nativeHLSMaster(in data: Data) throws -> URL {
    struct PlayerResponse: Decodable {
      struct Playability: Decodable { var status: String }
      struct StreamingData: Decodable { var hlsManifestUrl: String? }
      var playabilityStatus: Playability
      var streamingData: StreamingData?
    }
    let response = try JSONDecoder().decode(PlayerResponse.self, from: data)
    guard response.playabilityStatus.status == "OK" else {
      throw ResolutionError.notPlayable(response.playabilityStatus.status)
    }
    guard let manifest = response.streamingData?.hlsManifestUrl else {
      throw ResolutionError.noNativeHLS
    }
    guard let url = URL(string: manifest), url.scheme == "https", url.host != nil else {
      throw ResolutionError.invalidManifest
    }
    return url
  }

  /// Fetches the public live watch page HTML. It carries everything we need from
  /// a single request: visitor context and the live "watching now" count.
  private static func watchPageHTML(forVideoID videoID: String) async throws -> String {
    guard let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
      throw ResolutionError.invalidTarget
    }
    var request = URLRequest(url: watch)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    let data = try await responseData(for: request)
    return String(decoding: data, as: UTF8.self)
  }

  /// Live concurrent ("watching now") viewer count parsed from a live watch page,
  /// or nil when the page isn't a live broadcast — so a channel whose `/live`
  /// fell back to a VOD never reports a stale total-view number. Ties the count
  /// to the live flag in the same renderer to avoid matching lifetime views.
  private static func concurrentViewers(inWatchHTML html: String) -> Int? {
    guard let raw = firstMatch(
      in: html, pattern: "\"isLive\":true,\"originalViewCount\":\"([0-9]+)\"")
    else { return nil }
    return Int(raw)
  }

  // MARK: - Helpers

  private static func responseData(for request: URLRequest) async throws -> Data {
    let (data, response) = try await NetworkClient.api.data(for: request)
    try validate(response)
    return data
  }

  private static func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200...299).contains(http.statusCode) else {
      throw ResolutionError.httpStatus(http.statusCode)
    }
  }

  /// Safe, bounded categories only: never response bodies, signed URLs, visitor
  /// context, or provider error prose.
  static func errorAttributes(_ error: Error) -> [String: String] {
    var attributes = resolverAttributes
    switch error {
    case ResolutionError.invalidTarget: attributes["resolver_outcome"] = "invalid_target"
    case ResolutionError.noLiveVideo: attributes["resolver_outcome"] = "no_live_video"
    case ResolutionError.httpStatus(let status):
      attributes["resolver_outcome"] = "http_error"
      attributes["http_status"] = String(status)
    case ResolutionError.notPlayable(let status):
      attributes["resolver_outcome"] = "not_playable"
      let known = ["LOGIN_REQUIRED", "UNPLAYABLE", "ERROR", "LIVE_STREAM_OFFLINE", "CONTENT_CHECK_REQUIRED"]
      attributes["playability_status"] = known.contains(status) ? status : "unknown"
    case ResolutionError.noNativeHLS: attributes["resolver_outcome"] = "no_native_hls"
    case ResolutionError.invalidManifest: attributes["resolver_outcome"] = "invalid_manifest"
    case is DecodingError: attributes["resolver_outcome"] = "invalid_response"
    default:
      attributes["resolver_outcome"] = "request_failed"
      attributes["error_domain"] = (error as NSError).domain
      attributes["error_code"] = String((error as NSError).code)
    }
    return attributes
  }

  /// Returns the first capture group of `pattern` in `text`, or nil.
  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
      let group = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[group])
  }
}
