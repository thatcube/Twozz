import Foundation

/// Resolves a playable HLS manifest URL for a live YouTube video so the native
/// `AVPlayer` can play it on tvOS (AVKit can't open a `youtube.com/watch` URL
/// directly). YouTube live broadcasts expose an `.m3u8` HLS manifest in their
/// player response; we request it from the unofficial InnerTube `player`
/// endpoint using the TVHTML5 client.
///
/// This is an unofficial endpoint (no Data API quota, separate from our OAuth
/// project) used only to obtain the live HLS URL for playback. It is best-effort
/// and may break if YouTube changes the response shape.
enum YouTubeStreamResolver {
  /// Public InnerTube key embedded in YouTube's own clients.
  private static let innerTubeKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
  private static let playerURL = URL(
    string: "https://www.youtube.com/youtubei/v1/player?key=\(innerTubeKey)&prettyPrint=false")!

  enum ResolveError: LocalizedError {
    case notPlayable(String?)
    case noLiveManifest
    case badResponse

    var errorDescription: String? {
      switch self {
      case .notPlayable(let reason):
        return reason.map { "This YouTube stream can't be played: \($0)." }
          ?? "This YouTube stream can't be played right now."
      case .noLiveManifest:
        return "Couldn't find a live video stream for this channel."
      case .badResponse:
        return "Couldn't load the YouTube stream."
      }
    }
  }

  /// Returns the HLS manifest URL for a live YouTube video ID, or throws.
  static func hlsManifestURL(forVideoID videoID: String) async throws -> URL {
    var request = URLRequest(url: playerURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // The TVHTML5 client mirrors what a real Apple TV YouTube app sends and
    // reliably returns the live HLS manifest.
    request.setValue(
      "com.google.ios.youtube/19.09.3 (tvOS)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    let body: [String: Any] = [
      "videoId": videoID,
      "context": [
        "client": [
          "clientName": "TVHTML5",
          "clientVersion": "7.20240101.00.00",
          "hl": "en",
        ]
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await NetworkClient.api.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw ResolveError.badResponse
    }

    let player: PlayerResponse
    do {
      player = try YouTubeConfig.sharedDecoder.decode(PlayerResponse.self, from: data)
    } catch {
      throw ResolveError.badResponse
    }

    if let status = player.playabilityStatus?.status, status != "OK" {
      throw ResolveError.notPlayable(player.playabilityStatus?.reason)
    }
    guard let manifest = player.streamingData?.hlsManifestUrl,
      let url = URL(string: manifest)
    else {
      throw ResolveError.noLiveManifest
    }
    return url
  }

  private struct PlayerResponse: Decodable {
    let streamingData: StreamingData?
    let playabilityStatus: PlayabilityStatus?

    struct StreamingData: Decodable {
      let hlsManifestUrl: String?
    }
    struct PlayabilityStatus: Decodable {
      let status: String?
      let reason: String?
    }
  }
}
