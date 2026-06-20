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

    guard let (data, response) = try? await URLSession.shared.data(for: request),
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
    guard let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
    var request = URLRequest(url: watch)
    request.timeoutInterval = 15
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("YES+1", forHTTPHeaderField: "Cookie")

    guard let (data, response) = try? await URLSession.shared.data(for: request),
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
