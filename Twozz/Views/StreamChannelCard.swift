import AVFoundation
import SwiftUI

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
      cardCornerRadius: CGFloat = CardMetrics.gridCardCornerRadius,
      mediaCornerRadius: CGFloat = CardMetrics.gridMediaCornerRadius,
      contentInset: CGFloat = CardMetrics.gridContentInset
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
        CardMetrics.railAvatarSize
      case .grid:
        CardMetrics.gridAvatarSize
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
  var presentation: CardPresentation = .framed
  var showsGameName: Bool = false
  /// When provided, a press-and-hold context menu exposes "Watch".
  var onWatch: ((FollowedChannel) -> Void)? = nil
  /// When provided, a press-and-hold context menu exposes "Go to Channel".
  var onGoToChannel: ((FollowedChannel) -> Void)? = nil
  /// When provided, a press-and-hold context menu exposes "Not Interested",
  /// letting the viewer banish a recommendation they don't want to see.
  var onNotInterested: ((FollowedChannel) -> Void)? = nil

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
    cardBody
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
        onGoToChannel: onGoToChannel,
        onNotInterested: onNotInterested
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var cardBody: some View {
    switch presentation {
    case .framed:
      framedCard
    case .poster:
      posterCard
    }
  }

  private var framedCard: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionSpacing) {
      media
      caption
    }
    .padding(.horizontal, layout.focusHorizontalInset)
    .padding(.vertical, layout.focusVerticalInset)
    .frame(width: railCardWidth, alignment: .leading)
    .twozzLiquidGlassCard(
      cornerRadius: layout.cardCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .shadow(
      color: Color.black.opacity(layout.usesFocusedShadow && isFocused ? focusedShadowOpacity : 0),
      radius: layout.usesFocusedShadow ? CardMetrics.focusShadowRadius : 0,
      y: layout.usesFocusedShadow ? CardMetrics.focusShadowY : 0
    )
  }

  private var posterCard: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionSpacing + CardMetrics.focusCaptionPush) {
      media
      caption
        .offset(y: isFocused ? 0 : -CardMetrics.focusCaptionPush)
    }
    .padding(.horizontal, layout.focusHorizontalInset)
    .frame(width: railCardWidth, alignment: .leading)
    .compositingGroup()
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
  }

  private var caption: some View {
    HStack(alignment: .top, spacing: CardMetrics.avatarTextSpacing) {
      CachedAsyncImage(url: channel.profileImageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Circle()
          .fill(Color.primary.opacity(0.14))
      }
      .frame(width: layout.avatarSize, height: layout.avatarSize)
      .clipShape(Circle())

      VStack(alignment: .leading, spacing: CardMetrics.captionLineSpacing) {
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
    if channel.isLive, let viewerCount = channel.combinedViewerCount {
      parts.append("\(viewerCount) watching")
    }
    return Text(parts.joined(separator: ", "))
  }

  @ViewBuilder
  private var media: some View {
    // The placeholder color is the layout anchor; the thumbnail, preview, scrim
    // and badge are overlays so the media always sizes to the fixed 16:9 frame.
    // A `scaledToFill` thumbnail with a non-16:9 source (e.g. a 4:3 YouTube
    // hqdefault) overflows its bounds; as a ZStack sibling that overflow would
    // grow the stack taller than the frame, which then centers and clips it —
    // pushing the bottom-aligned LiveBadge off the visible thumbnail. As an
    // overlay it can't affect the anchor's size, so the badge stays in frame.
    Color.primary.opacity(0.08)
      .overlay {
        LiveThumbnail(url: channel.thumbnailURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Color.clear
        }
      }
      .overlay {
        if isShowingLivePreviewSurface {
          PreviewVideoSurface(player: previewPlayer, cornerRadius: activeMediaCornerRadius)
            .opacity(livePreviewOpacity)
            .transition(.opacity)
        }
      }
      .overlay {
        LinearGradient(
          colors: [Color.clear, Color.black.opacity(0.82)],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .overlay(alignment: .bottomLeading) {
        LiveBadge(isLive: channel.isLive, viewerCount: channel.combinedViewerCount)
          .padding(12)
      }
    .frame(width: layout.mediaWidth, height: layout.mediaHeight)
    .frame(maxWidth: layout.mediaWidth == nil ? .infinity : nil, alignment: .leading)
    .mediaAspectRatio(layout.mediaWidth == nil ? 16 / 9 : nil)
    .clipShape(RoundedRectangle(cornerRadius: activeMediaCornerRadius, style: .continuous))
    .twozzMediaEdge(cornerRadius: activeMediaCornerRadius)
    .twozzFocusHalo(
      cornerRadius: activeMediaCornerRadius,
      focusScale: AppLayout.focusedCardScale,
      isFocused: presentation == .poster && isFocused
    )
    .animation(.easeOut(duration: 0.22), value: livePreviewOpacity)
  }

  private var activeMediaCornerRadius: CGFloat {
    presentation == .poster ? layout.cardCornerRadius : layout.mediaCornerRadius
  }

  private var railCardWidth: CGFloat? {
    guard let mediaWidth = layout.mediaWidth else { return nil }
    return mediaWidth + (layout.focusHorizontalInset * 2)
  }

  private var usesLiftFocusedText: Bool {
    presentation == .framed
      && twozzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
  }

  /// Focused drop-shadow strength. Light mode uses a softer shadow: against a
  /// light page the dark shadow otherwise muddies into the focused card's
  /// darkening tint, so the lift reads as a smudge rather than a float.
  private var focusedShadowOpacity: Double {
    palette.isLight ? CardMetrics.focusShadowOpacityLight : CardMetrics.focusShadowOpacity
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
    onGoToChannel: ((FollowedChannel) -> Void)?,
    onNotInterested: ((FollowedChannel) -> Void)?
  ) -> some View {
    if onWatch == nil && onGoToChannel == nil && onNotInterested == nil {
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
        if let onNotInterested {
          Button(role: .destructive) {
            onNotInterested(channel)
          } label: {
            Label("Not Interested", systemImage: "hand.thumbsdown")
          }
        }
      }
    }
  }
}

private extension View {
  /// Applies a fixed media aspect ratio only when a ratio is supplied. Passing
  /// `nil` leaves the view's existing (fixed-frame) sizing untouched — unlike
  /// `aspectRatio(nil, contentMode:)`, which would make the view adopt its
  /// content's intrinsic ratio (e.g. a 4:3 YouTube thumbnail) and overflow the
  /// 16:9 rail frame.
  @ViewBuilder
  func mediaAspectRatio(_ ratio: CGFloat?) -> some View {
    if let ratio {
      aspectRatio(ratio, contentMode: .fit)
    } else {
      self
    }
  }
}
