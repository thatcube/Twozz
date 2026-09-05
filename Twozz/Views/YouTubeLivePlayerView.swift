import AVKit
import SwiftUI

/// Full-screen native player for a YouTube-only live stream. Resolves the live
/// HLS manifest for the given video ID and plays it with the system `AVPlayer`
/// transport controls (so we get tvOS-native scrubbing, focus, and Now Playing
/// for free). Used for subscribed YouTube streamers who aren't on Twitch.
struct YouTubeLivePlayerView: View {
  let videoID: String
  let title: String?

  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer?
  @State private var errorMessage: String?
  @State private var isLoading = true

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let player {
        VideoPlayer(player: player)
          .ignoresSafeArea()
      } else if isLoading {
        VStack(spacing: 24) {
          ProgressView()
            .scaleEffect(1.6)
          Text(title ?? "Loading YouTube stream…")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.85))
        }
      } else if let errorMessage {
        VStack(spacing: 28) {
          Icon(glyph: .brandYoutube, size: 64)
            .foregroundStyle(Color(red: 1, green: 0, blue: 0))
          Text(errorMessage)
            .font(.title3)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 900)
          Button("Close") { dismiss() }
            .buttonStyle(.bordered)
        }
        .padding(60)
      }
    }
    .task {
      await loadStream()
    }
    .onDisappear {
      player?.pause()
      player = nil
    }
  }

  private func loadStream() async {
    isLoading = true
    errorMessage = nil
    do {
      let url = try await YouTubeStreamResolver.hlsManifestURL(forVideoID: videoID)
      guard !Task.isCancelled else { return }
      let asset = AVURLAsset(
        url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": AltSourceService.mediaHTTPHeaders])
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      player.allowsExternalPlayback = true
      self.player = player
      player.play()
    } catch {
      errorMessage =
        (error as? LocalizedError)?.errorDescription ?? "Couldn't load the YouTube stream."
    }
    isLoading = false
  }
}
