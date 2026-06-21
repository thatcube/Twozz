import Foundation

/// Resolves a streamer's *alternate-platform* live stream to an HLS master URL
/// playable by AVPlayer, so the player can offer a lower-latency source than the
/// proxied Twitch path when a streamer simulcasts.
///
/// Currently supports YouTube: it reuses the same public watch-page route the
/// experimental YouTube chat merge already relies on (`ChatService+YouTube`),
/// extracting `hlsManifestUrl` from the live watch page. No API key, no auth.
///
/// This is read-only and non-commercial: it fetches the public manifest the web
/// player would use and plays it as-is. It strips nothing and never restreams.
enum AltSourceService {
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  // ANDROID_VR Innertube client. YouTube now PO-token-gates the web client's
  // live HLS segments (they 403 without a BotGuard token), but the ANDROID_VR
  // client returns a manifest whose segments are ungated — so AVPlayer can play
  // it directly with no login and no PO token. Mirrors yt-dlp's `android_vr`
  // client; version/UA track that client and may need periodic bumps.
  private static let androidVRClientVersion = "1.65.10"
  private static let androidVRClientName = "28"
  private static let androidVRUserAgent =
    "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

  /// Resolves a YouTube target (handle, channel URL, watch URL, or 11-char video
  /// id) to its currently-live HLS master playlist URL, or `nil` when the target
  /// isn't live or the manifest isn't exposed.
  static func youtubeHLSMaster(forTarget target: String) async -> URL? {
    guard let videoID = await resolveLiveVideoID(from: target) else { return nil }
    return await hlsMaster(forVideoID: videoID)
  }

  // MARK: - Video resolution

  private static func resolveLiveVideoID(from input: String) async -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let direct = extractVideoID(from: trimmed) { return direct }

    guard let lookup = liveLookupURL(from: trimmed) else { return nil }
    var request = URLRequest(url: lookup)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
    else { return nil }

    if let finalURL = http.url?.absoluteString, let id = extractVideoID(from: finalURL) {
      return id
    }
    let html = String(decoding: data, as: UTF8.self)
    return firstMatch(in: html, pattern: "\"videoId\":\"([A-Za-z0-9_-]{11})\"")
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

  private static func hlsMaster(forVideoID videoID: String) async -> URL? {
    // Preferred: ANDROID_VR client (ungated segments). Fall back to the legacy
    // web watch-page scrape only if that fails — note the web manifest's
    // segments are PO-token-gated and will 403 in AVPlayer, so it's a last
    // resort that mainly preserves the old behavior.
    if let url = await androidVRHLSMaster(forVideoID: videoID) { return url }
    return await watchPageHLSMaster(forVideoID: videoID)
  }

  /// Resolves the live HLS master via the ANDROID_VR Innertube `player`
  /// endpoint. This is the path whose segments AVPlayer can actually fetch.
  private static func androidVRHLSMaster(forVideoID videoID: String) async -> URL? {
    guard let visitor = await visitorData(forVideoID: videoID),
      let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player")
    else { return nil }

    let body: [String: Any] = [
      "context": [
        "client": [
          "clientName": "ANDROID_VR",
          "clientVersion": androidVRClientVersion,
          "deviceMake": "Oculus",
          "deviceModel": "Quest 3",
          "androidSdkVersion": 32,
          "osName": "Android",
          "osVersion": "12L",
          "hl": "en",
          "gl": "US",
          "userAgent": androidVRUserAgent,
          "visitorData": visitor,
        ]
      ],
      "videoId": videoID,
      "contentCheckOk": true,
      "racyCheckOk": true,
    ]
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.httpBody = payload
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(androidVRUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(androidVRClientName, forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(androidVRClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let streaming = json["streamingData"] as? [String: Any],
      let manifest = streaming["hlsManifestUrl"] as? String
    else { return nil }
    return URL(string: manifest)
  }

  /// Fetches a `visitorData` token from the public watch page. ANDROID_VR's
  /// `player` request returns `LOGIN_REQUIRED` without one.
  private static func visitorData(forVideoID videoID: String) async -> String? {
    guard let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
    var request = URLRequest(url: watch)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
    else { return nil }

    let html = String(decoding: data, as: UTF8.self)
    return firstMatch(in: html, pattern: "\"visitorData\":\"([^\"]+)\"")
  }

  /// Legacy fallback: scrape `hlsManifestUrl` straight off the web watch page.
  /// Kept only as a backstop; its segments are PO-token-gated (403 in AVPlayer).
  private static func watchPageHLSMaster(forVideoID videoID: String) async -> URL? {
    guard let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
    var request = URLRequest(url: watch)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    guard let (data, response) = try? await NetworkClient.api.data(for: request),
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
    else { return nil }

    let html = String(decoding: data, as: UTF8.self)
    guard let raw = firstMatch(in: html, pattern: "hlsManifestUrl\":\"([^\"]+)\"") else {
      return nil
    }
    let unescaped = raw.replacingOccurrences(of: "\\u0026", with: "&")
    return URL(string: unescaped)
  }

  // MARK: - Helpers

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
