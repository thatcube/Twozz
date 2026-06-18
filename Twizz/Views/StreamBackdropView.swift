import AVFoundation
import SwiftUI

/// Full-screen ambient backdrop driven by the currently focused stream card.
/// Shows a blurred thumbnail immediately, then swaps to a blurred live preview
/// after a short hover delay.
struct StreamBackdropView: View {
  let channel: FollowedChannel?

  @State private var player = AVPlayer()
  @State private var previewTask: Task<Void, Never>?
  @State private var revealVideoTask: Task<Void, Never>?
  @State private var thumbnailCleanupTask: Task<Void, Never>?
  @State private var activeChannelID: String?
  @State private var activeThumbnailURL: URL?
  @State private var fallbackThumbnailURL: URL?
  @State private var activeThumbnailOpacity = 0.0
  @State private var fallbackThumbnailOpacity = 0.0
  @State private var activeThumbnailDidLoad = false
  @State private var isShowingVideoPreview = false
  @State private var videoOpacity = 0.0
  @State private var hasConfiguredPlayer = false

  private let channelFade = Animation.easeInOut(duration: 0.55)
  private let videoFade = Animation.easeInOut(duration: 0.55)

  var body: some View {
    ZStack {
      if let fallbackThumbnailURL {
        AsyncImage(url: fallbackThumbnailURL) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          Color.clear
        }
        .opacity(fallbackThumbnailOpacity)
      }

      if let activeThumbnailURL {
        AsyncImage(url: activeThumbnailURL) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
              .onAppear {
                markActiveThumbnailLoaded(for: activeThumbnailURL)
              }
          case .empty:
            Color.clear
          case .failure:
            Color.clear
          @unknown default:
            Color.clear
          }
        }
        .opacity(activeThumbnailOpacity)
      }

      if isShowingVideoPreview {
        VideoSurface(player: player)
          .opacity(videoOpacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scaleEffect(1.24)
    .saturation(1.16)
    .blur(radius: 66)
    .overlay {
      LinearGradient(
        colors: [Color.black.opacity(0.5), Color.black.opacity(0.8)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .animation(channelFade, value: activeThumbnailOpacity)
    .animation(channelFade, value: fallbackThumbnailOpacity)
    .animation(videoFade, value: videoOpacity)
    .allowsHitTesting(false)
    .onAppear {
      configurePlayerIfNeeded()
      primeThumbnailState(channel)
      handleChannelChange(channel)
    }
    .onChange(of: channel?.id) { _, _ in
      handleChannelChange(channel)
    }
    .onDisappear {
      stopPreviewPlayback(clearItem: true)
      thumbnailCleanupTask?.cancel()
      thumbnailCleanupTask = nil
    }
  }

  @MainActor
  private func configurePlayerIfNeeded() {
    guard !hasConfiguredPlayer else { return }
    player.isMuted = true
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    hasConfiguredPlayer = true
  }

  @MainActor
  private func primeThumbnailState(_ channel: FollowedChannel?) {
    let initialThumbnailURL = channel?.thumbnailURL
    activeThumbnailURL = initialThumbnailURL
    fallbackThumbnailURL = nil
    activeThumbnailOpacity = initialThumbnailURL == nil ? 0 : 1
    fallbackThumbnailOpacity = 0
    activeThumbnailDidLoad = initialThumbnailURL != nil
  }

  @MainActor
  private func transitionToThumbnail(_ thumbnailURL: URL?) {
    guard activeThumbnailURL != thumbnailURL else { return }
    thumbnailCleanupTask?.cancel()
    thumbnailCleanupTask = nil

    fallbackThumbnailURL = activeThumbnailURL ?? fallbackThumbnailURL
    fallbackThumbnailOpacity = fallbackThumbnailURL == nil ? 0 : 1
    activeThumbnailURL = thumbnailURL
    activeThumbnailDidLoad = false
    activeThumbnailOpacity = 0
  }

  @MainActor
  private func markActiveThumbnailLoaded(for url: URL) {
    guard activeThumbnailURL == url else { return }
    guard !activeThumbnailDidLoad else { return }
    activeThumbnailDidLoad = true

    withAnimation(channelFade) {
      activeThumbnailOpacity = 1
      fallbackThumbnailOpacity = 0
    }

    thumbnailCleanupTask?.cancel()
    thumbnailCleanupTask = Task {
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard fallbackThumbnailOpacity == 0 else { return }
        fallbackThumbnailURL = nil
        thumbnailCleanupTask = nil
      }
    }
  }

  @MainActor
  private func handleChannelChange(_ channel: FollowedChannel?) {
    previewTask?.cancel()
    previewTask = nil
    revealVideoTask?.cancel()
    revealVideoTask = nil
    withAnimation(videoFade) {
      videoOpacity = 0
    }
    isShowingVideoPreview = false
    player.pause()
    player.replaceCurrentItem(with: nil)

    guard let channel else {
      activeChannelID = nil
      transitionToThumbnail(nil)
      return
    }

    activeChannelID = channel.id
    transitionToThumbnail(channel.thumbnailURL)
    guard channel.isLive else { return }

    let channelID = channel.id
    let login = channel.login

    previewTask = Task { [channelID, login] in
      do {
        async let hoverDelay: Void = Task.sleep(for: .seconds(2))
        async let sourceURLTask: URL = PlaybackService.hlsURL(for: login)
        try await hoverDelay
        guard !Task.isCancelled else { return }
        let sourceURL = try await sourceURLTask
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard activeChannelID == channelID else { return }
          startPreviewPlayback(from: sourceURL)
          previewTask = nil
        }
      } catch is CancellationError {
        await MainActor.run {
          previewTask = nil
        }
      } catch {
        await MainActor.run {
          guard activeChannelID == channelID else { return }
          stopPreviewPlayback(clearItem: true)
          previewTask = nil
        }
      }
    }
  }

  @MainActor
  private func startPreviewPlayback(from sourceURL: URL) {
    configurePlayerIfNeeded()
    let asset = AVURLAsset(
      url: sourceURL,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    let item = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: item)
    videoOpacity = 0
    isShowingVideoPreview = true
    player.play()
    beginVideoRevealWhenReady(item: item)
  }

  @MainActor
  private func beginVideoRevealWhenReady(item: AVPlayerItem) {
    revealVideoTask?.cancel()
    let channelID = activeChannelID
    revealVideoTask = Task { [channelID] in
      var isReadyToReveal = false
      for _ in 0..<35 {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }

        let readiness = await MainActor.run {
          (
            activeChannelID == channelID && player.currentItem === item,
            item.status == .readyToPlay,
            item.isPlaybackLikelyToKeepUp || !item.loadedTimeRanges.isEmpty,
            player.timeControlStatus == .playing
          )
        }

        let (isCurrentItem, isReady, hasBuffer, isPlaying) = readiness
        guard isCurrentItem else { return }
        if isReady && hasBuffer && isPlaying {
          isReadyToReveal = true
          break
        }
      }
      guard isReadyToReveal else { return }
      try? await Task.sleep(for: .milliseconds(260))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard activeChannelID == channelID, player.currentItem === item else { return }
        withAnimation(videoFade) {
          videoOpacity = 1
        }
        revealVideoTask = nil
      }
    }
  }

  @MainActor
  private func stopPreviewPlayback(clearItem: Bool) {
    previewTask?.cancel()
    previewTask = nil
    revealVideoTask?.cancel()
    revealVideoTask = nil
    withAnimation(videoFade) {
      videoOpacity = 0
    }
    isShowingVideoPreview = false
    player.pause()
    if clearItem {
      player.replaceCurrentItem(with: nil)
    }
  }
}
