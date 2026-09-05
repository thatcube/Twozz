import Foundation

/// Resolves a playable HLS manifest URL for a live YouTube video so the native
/// `AVPlayer` can play it on tvOS (AVKit can't open a `youtube.com/watch` URL
/// directly).
///
/// Shares the public native-HLS resolver and media identity used by simulcasts.
enum YouTubeStreamResolver {
  /// Returns the HLS manifest URL for a live YouTube video ID, or throws.
  static func hlsManifestURL(forVideoID videoID: String) async throws -> URL {
    try await AltSourceService.youtubeHLSMaster(forTarget: videoID)
  }
}
