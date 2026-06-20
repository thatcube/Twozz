import AVFoundation
import SwiftUI
import UIKit

struct StreamChannelCard: View {
  enum Layout {
    case rail(
      mediaWidth: CGFloat,
      mediaHeight: CGFloat,
      focusHorizontalInset: CGFloat,
      focusVerticalInset: CGFloat,
      cardCornerRadius: CGFloat,
      mediaCornerRadius: CGFloat
    )
    case grid(
      cardCornerRadius: CGFloat = 16,
      mediaCornerRadius: CGFloat = 12,
      contentInset: CGFloat = 14
    )

    var cardCornerRadius: CGFloat {
      switch self {
      case .rail(_, _, _, _, let cardCornerRadius, _):
        cardCornerRadius
      case .grid(let cardCornerRadius, _, _):
        cardCornerRadius
      }
    }

    var mediaCornerRadius: CGFloat {
      switch self {
      case .rail(_, _, _, _, _, let mediaCornerRadius):
        mediaCornerRadius
      case .grid(_, let mediaCornerRadius, _):
        mediaCornerRadius
      }
    }

    var focusHorizontalInset: CGFloat {
      switch self {
      case .rail(_, _, let focusHorizontalInset, _, _, _):
        focusHorizontalInset
      case .grid(_, _, let contentInset):
        contentInset
      }
    }

    var focusVerticalInset: CGFloat {
      switch self {
      case .rail(_, _, _, let focusVerticalInset, _, _):
        focusVerticalInset
      case .grid(_, _, let contentInset):
        contentInset
      }
    }

    var mediaWidth: CGFloat? {
      switch self {
      case .rail(let mediaWidth, _, _, _, _, _):
        mediaWidth
      case .grid:
        nil
      }
    }

    var mediaHeight: CGFloat? {
      switch self {
      case .rail(_, let mediaHeight, _, _, _, _):
        mediaHeight
      case .grid:
        nil
      }
    }

    var avatarSize: CGFloat {
      switch self {
      case .rail:
        62
      case .grid:
        68
      }
    }

    var usesFocusedShadow: Bool {
      switch self {
      case .rail:
        true
      case .grid:
        false
      }
    }
  }

  let channel: FollowedChannel
  let isFocused: Bool
  var layout: Layout = .grid()
  var showsGameName: Bool = false
  /// When provided, a press-and-hold context menu exposes "Watch".
  var onWatch: ((FollowedChannel) -> Void)? = nil
  /// When provided, a press-and-hold context menu exposes "Go to Channel".
  var onGoToChannel: ((FollowedChannel) -> Void)? = nil

  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @State private var previewPlayer = AVPlayer()
  @State private var previewTask: Task<Void, Never>?
  @State private var revealVideoTask: Task<Void, Never>?
  @State private var previewSourceURL: URL?
  @State private var cachedPreviewURL: URL?
  @State private var isShowingLivePreviewSurface = false
  @State private var livePreviewOpacity = 0.0
  @State private var hasConfiguredPreviewPlayer = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      media

      HStack(alignment: .top, spacing: 10) {
        CachedAsyncImage(url: channel.profileImageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Circle()
            .fill(Color.primary.opacity(0.14))
        }
        .frame(width: layout.avatarSize, height: layout.avatarSize)
        .clipShape(Circle())

        VStack(alignment: .leading, spacing: 4) {
          Text(channel.displayName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

          Text(channel.title.isEmpty ? "No title" : channel.title)
            .font(.footnote)
            .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
            .lineLimit(2, reservesSpace: true)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)

          if showsGameName {
            Text(channel.gameName)
              .font(.caption2)
              .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, layout.focusHorizontalInset)
    .padding(.vertical, layout.focusVerticalInset)
    .frame(width: railCardWidth, alignment: .leading)
    .twizzLiquidGlassCard(
      cornerRadius: layout.cardCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .shadow(
      color: Color.black.opacity(layout.usesFocusedShadow && isFocused ? focusedShadowOpacity : 0),
      radius: layout.usesFocusedShadow ? 20 : 0,
      y: layout.usesFocusedShadow ? 10 : 0
    )
    .onAppear {
      configurePreviewPlayerIfNeeded()
      handleFocusChange(isFocused)
    }
    .onChange(of: isFocused) { _, focused in
      handleFocusChange(focused)
    }
    .onDisappear {
      stopPreviewPlayback(clearCachedURL: true)
    }
    .channelCardContextMenu(
      channel: channel,
      onWatch: onWatch,
      onGoToChannel: onGoToChannel
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// A single spoken description per card: name, live/offline state, title,
  /// game, and (when live) the viewer count — so VoiceOver reads one coherent
  /// sentence instead of disconnected avatar/name/title fragments.
  private var accessibilityLabel: Text {
    var parts: [String] = [channel.displayName]
    parts.append(channel.isLive ? "Live" : "Offline")
    if !channel.title.isEmpty {
      parts.append(channel.title)
    }
    if !channel.gameName.isEmpty {
      parts.append(channel.gameName)
    }
    if channel.isLive, let viewerCount = channel.viewerCount {
      parts.append("\(viewerCount) watching")
    }
    return Text(parts.joined(separator: ", "))
  }

  @ViewBuilder
  private var media: some View {
    ZStack(alignment: .bottomLeading) {
      Color.primary.opacity(0.08)

      AsyncImage(url: channel.thumbnailURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.clear
      }

      if isShowingLivePreviewSurface {
        PreviewVideoSurface(player: previewPlayer, cornerRadius: layout.mediaCornerRadius)
          .opacity(livePreviewOpacity)
          .transition(.opacity)
      }

      LinearGradient(
        colors: [Color.clear, Color.black.opacity(0.82)],
        startPoint: .top,
        endPoint: .bottom
      )

      LiveBadge(isLive: channel.isLive, viewerCount: channel.viewerCount)
        .padding(12)
    }
    .frame(width: layout.mediaWidth, height: layout.mediaHeight)
    .frame(maxWidth: layout.mediaWidth == nil ? .infinity : nil, alignment: .leading)
    .aspectRatio(layout.mediaWidth == nil ? 16 / 9 : nil, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: layout.mediaCornerRadius, style: .continuous))
    .overlay {
      // A hairline rim on the media edge. It matches the frosted-glass tone of
      // the card so it blends in, while quietly covering the ~1-2px that tvOS's
      // hardware video overlay plane bleeds past the rounded corners (that plane
      // ignores CALayer corner masks, so neither the SwiftUI clip nor rounding
      // the player layer fully contains it). Always on, so live and thumbnail
      // tiles share the same clean edge.
      RoundedRectangle(cornerRadius: layout.mediaCornerRadius, style: .continuous)
        .inset(by: -0.5)
        .stroke(mediaEdgeColor, lineWidth: 1.5)
    }
    .animation(.easeOut(duration: 0.22), value: livePreviewOpacity)
  }

  /// Frosted-glass tone of the card surface immediately around the media: the
  /// theme background nudged toward white to approximate the glass. Used for the
  /// media edge hairline so it blends with the card while still painting over
  /// the hardware video plane's corner bleed.
  private static var edgeColorCache: [UIColor: Color] = [:]

  private var mediaEdgeColor: Color {
    let base = UIColor(palette.backgroundColors.last ?? .black)
    if let cached = Self.edgeColorCache[base] { return cached }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    base.getRed(&r, green: &g, blue: &b, alpha: &a)
    let lift: CGFloat = 0.09
    let color = Color(
      red: Double(r + (1 - r) * lift),
      green: Double(g + (1 - g) * lift),
      blue: Double(b + (1 - b) * lift)
    )
    Self.edgeColorCache[base] = color
    return color
  }

  private var railCardWidth: CGFloat? {
    guard let mediaWidth = layout.mediaWidth else { return nil }
    return mediaWidth + (layout.focusHorizontalInset * 2)
  }

  private var usesLiftFocusedText: Bool {
    twizzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
  }

  /// Focused drop-shadow strength. Light mode uses a softer shadow: against a
  /// light page the dark shadow otherwise muddies into the focused card's
  /// darkening tint, so the lift reads as a smudge rather than a float.
  private var focusedShadowOpacity: Double {
    palette.isLight ? 0.20 : 0.36
  }

  @MainActor
  private func configurePreviewPlayerIfNeeded() {
    guard !hasConfiguredPreviewPlayer else { return }
    previewPlayer.isMuted = true
    previewPlayer.actionAtItemEnd = .pause
    previewPlayer.automaticallyWaitsToMinimizeStalling = true
    hasConfiguredPreviewPlayer = true
  }

  @MainActor
  private func handleFocusChange(_ focused: Bool) {
    guard focused, channel.isLive else {
      stopPreviewPlayback(clearCachedURL: false)
      return
    }

    guard previewTask == nil else { return }
    let login = channel.login
    let cachedURL = cachedPreviewURL

    previewTask = Task { [cachedURL, login] in
      do {
        async let hoverDelay: Void = Task.sleep(for: .seconds(2))
        async let sourceURLTask: URL = resolvePreviewURL(cachedURL: cachedURL, login: login)
        try await hoverDelay
        guard !Task.isCancelled else { return }
        let sourceURL = try await sourceURLTask
        guard !Task.isCancelled else { return }
        await MainActor.run {
          startPreviewPlayback(from: sourceURL)
          previewTask = nil
        }
      } catch is CancellationError {
        await MainActor.run {
          previewTask = nil
        }
      } catch {
        await MainActor.run {
          previewTask = nil
          stopPreviewPlayback(clearCachedURL: true)
        }
      }
    }
  }

  private func resolvePreviewURL(cachedURL: URL?, login: String) async throws -> URL {
    if let cachedURL {
      return cachedURL
    }
    return try await PlaybackService.previewHLSURL(for: login)
  }

  @MainActor
  private func startPreviewPlayback(from sourceURL: URL) {
    configurePreviewPlayerIfNeeded()
    cachedPreviewURL = sourceURL
    if previewSourceURL != sourceURL {
      let asset = AVURLAsset(
        url: sourceURL,
        options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
      )
      let item = AVPlayerItem(asset: asset)
      item.preferredForwardBufferDuration = 0.8
      item.preferredPeakBitRate = 2_200_000
      previewPlayer.replaceCurrentItem(with: item)
      previewSourceURL = sourceURL
    }
    livePreviewOpacity = 0
    isShowingLivePreviewSurface = true
    previewPlayer.play()
    beginLivePreviewRevealWhenReady()
  }

  @MainActor
  private func beginLivePreviewRevealWhenReady() {
    revealVideoTask?.cancel()
    guard let previewItem = previewPlayer.currentItem else { return }
    revealVideoTask = Task { [previewItem] in
      var isReadyToReveal = false
      for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        let readiness = await MainActor.run {
          (
            previewPlayer.currentItem === previewItem,
            previewItem.status == .readyToPlay,
            previewItem.isPlaybackLikelyToKeepUp || !previewItem.loadedTimeRanges.isEmpty,
            previewPlayer.timeControlStatus == .playing
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
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard previewPlayer.currentItem === previewItem else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
          livePreviewOpacity = 1
        }
        revealVideoTask = nil
      }
    }
  }

  @MainActor
  private func stopPreviewPlayback(clearCachedURL: Bool) {
    previewTask?.cancel()
    previewTask = nil
    revealVideoTask?.cancel()
    revealVideoTask = nil
    livePreviewOpacity = 0
    isShowingLivePreviewSurface = false
    previewPlayer.pause()
    previewPlayer.replaceCurrentItem(with: nil)
    previewSourceURL = nil
    if clearCachedURL {
      cachedPreviewURL = nil
    }
  }
}

private extension View {
  /// Attaches the channel card's press-and-hold context menu when at least one
  /// action is supplied. tvOS surfaces this on a long press of the focused card.
  @ViewBuilder
  func channelCardContextMenu(
    channel: FollowedChannel,
    onWatch: ((FollowedChannel) -> Void)?,
    onGoToChannel: ((FollowedChannel) -> Void)?
  ) -> some View {
    if onWatch == nil && onGoToChannel == nil {
      self
    } else {
      contextMenu {
        if let onWatch {
          Button {
            onWatch(channel)
          } label: {
            Label("Watch", systemImage: "play.fill")
          }
        }
        if let onGoToChannel {
          Button {
            onGoToChannel(channel)
          } label: {
            Label("Go to Channel", systemImage: "person.crop.circle")
          }
        }
      }
    }
  }
}
