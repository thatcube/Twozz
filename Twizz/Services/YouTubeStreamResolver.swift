import Foundation

/// Resolves a playable HLS manifest URL for a live YouTube video so the native
/// `AVPlayer` can play it on tvOS (AVKit can't open a `youtube.com/watch` URL
/// directly).
///
/// Resolution goes through `AltSourceService`'s login-free path: the **ANDROID_VR**
/// InnerTube client with a `visitorData` token scraped from the public watch
/// page. That manifest's segments are ungated, so AVPlayer plays them with no
/// login and no PO token. The previous TVHTML5 client (no visitor token) is now
/// bot-gated by YouTube — it returns `LOGIN_REQUIRED` ("Sign in to confirm you're
/// not a bot"), which is exactly the failure this avoids.
enum YouTubeStreamResolver {
  enum ResolveError: LocalizedError {
    case noLiveManifest

    var errorDescription: String? {
      switch self {
      case .noLiveManifest:
        return "Couldn't find a live video stream for this channel."
      }
    }
  }

  /// Returns the HLS manifest URL for a live YouTube video ID, or throws.
  static func hlsManifestURL(forVideoID videoID: String) async throws -> URL {
    // Resolve through the same ANDROID_VR + visitorData path AltSourceService
    // uses for simulcasts, whose live HLS manifest plays in AVPlayer with no
    // login and no PO token. Avoids the bot-gated TVHTML5 client.
    guard let url = await AltSourceService.youtubeHLSMaster(forTarget: videoID) else {
      throw ResolveError.noLiveManifest
    }
    return url
  }
}
