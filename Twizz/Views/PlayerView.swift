import AVKit
import SwiftUI
import UIKit

/// AVPlayer host that is intentionally non-interactive: Twizz handles all remote
/// input in SwiftUI and never lets AVKit consume transport/scrub commands.
private final class PassivePlayerViewController: AVPlayerViewController {
  override var canBecomeFirstResponder: Bool { false }
}

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twizz UI while preserving Apple's media rendering paths
/// better than a raw `AVPlayerLayer`.
struct VideoSurface: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = PassivePlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    // Keep output mode stable while toggling in-app layouts (chat on/off).
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    // Prevent AVKit's internal gesture/press recognizers from handling Siri
    // Remote input (seek/scrub/skip). Twizz UI remains fully interactive.
    controller.view.isUserInteractionEnabled = false
    controller.view.backgroundColor = .black
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    controller.view.isUserInteractionEnabled = false
  }
}

/// Full-screen player for a live channel. Video sits on the left and the chat
/// panel docks to the right at full height (the video shrinks to make room,
/// never overlapping). We use a custom `AVPlayerLayer` surface with our own
/// overlay UI rather than the native player transport — the native controls are
/// VOD/scrubbing-oriented and unsuited to a live, side-by-side chat layout.
/// Controls auto-hide and are revealed by pressing the remote.
struct PlayerView: View {
  let channel: String
  var auth: TwitchAuthSession

  /// The currently-active channel, which can change if the user follows a raid.
  @State private var activeChannel: String = ""

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @AppStorage("preferredQuality") private var preferredQuality = "Auto"
  @AppStorage("chatTextSizeValue") private var chatTextSizeValue = Double(ChatAppearance.defaultTextSize)
  @AppStorage("chatEmoteAuto") private var chatEmoteAuto = ChatAppearance.defaultEmoteAuto
  @AppStorage("chatEmoteSizeValue") private var chatEmoteSizeValue = Double(ChatAppearance.defaultEmoteSize)
  @AppStorage("chatLineHeightValue") private var chatLineHeightValue = Double(ChatAppearance.defaultLineHeight)
  @AppStorage("chatMessageSpacingValue") private var chatMessageSpacingValue = Double(ChatAppearance.defaultMessageSpacing)
  @AppStorage("chatWidthValue") private var chatWidthValue = Double(ChatAppearance.defaultWidth)
  @AppStorage("chatAnimatedEmotes") private var chatAnimatedEmotes = ChatAppearance.defaultAnimatedEmotes
  @AppStorage("chatFontStyle") private var chatFontStyleRaw = ChatAppearance.defaultFontStyle.rawValue
  @AppStorage("chatShowBadges") private var chatShowBadges = ChatAppearance.defaultShowBadges
  @AppStorage("chatLayoutMode") private var chatLayoutModeRaw = ChatLayoutMode.side.rawValue
  @AppStorage("chatSyncToStream") private var chatSyncToStream = false
  @AppStorage("experimentalYouTubeMergeEnabled") private var experimentalYouTubeMergeEnabled = false
  @AppStorage("experimentalYouTubeMergeChannelOrURL") private var experimentalYouTubeMergeChannelOrURL = ""
  @AppStorage(LowLatencyHLSProxy.settingsKey) private var lowLatencyProxyEnabled = true
  @AppStorage("showLatencyDiagnostics") private var showLatencyDiagnostics = false

  @State private var chat = ChatService()
  /// Detects *outgoing* raids (the watched channel raiding away) via EventSub.
  @State private var eventSub = EventSubService()
  @State private var player = AVPlayer()
  /// Drives the audio-only visualizer orb. Reacts to real audio when the player
  /// item exposes a tappable audio track (best effort on live HLS), otherwise
  /// runs an ambient animation.
  @State private var audioLevelMonitor = AudioLevelMonitor()
  /// Retained for the player's lifetime: `AVURLAsset` only holds its resource
  /// loader delegate weakly, so the proxy must be owned here to stay alive.
  @State private var lowLatencyProxy = LowLatencyHLSProxy(headers: PlaybackService.streamHeaders)
  @State private var playback: StreamPlayback?
  @State private var errorMessage: String?
  @State private var isOffline = false
  @State private var isLoading = true
  @State private var showChat: Bool = UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool ?? true
  @State private var chatReplayStartMessageID: ChatMessage.ID?
  /// Live resolution AVPlayer's adaptive (Auto) selection is currently showing,
  /// e.g. "1080p60". Drives the "Auto (1080p60)" label on the quality button.
  @State private var resolvedQualityName: String?
  @State private var showSignInSheet = false
  @State private var showChatSettings = false
  @State private var chatSettingsPage: ChatSettingsPage = .main
  /// Natural (content) height of the current settings page, used to size the
  /// floating panel to its content and animate when the page/content changes.
  @State private var chatSettingsContentHeight: CGFloat = 0
  @State private var showControls = false
  @State private var streamTitle: String = ""
  @State private var channelDisplayName: String = ""
  @State private var channelAvatarURL: URL?
  @State private var channelPageTarget: ChannelPageTarget?
  /// When the user picks a "More like this" channel from the channel page, we
  /// stash its login and switch to it once the page cover finishes dismissing.
  @State private var pendingSwitchLogin: String?
  @State private var chatDraft: String = ""
  @State private var chatInputActivationToken: Int = 0
  @State private var youtubeInputActivationToken: Int = 0
  @State private var isSendingChat = false
  @State private var chatSendError: String?
  /// When chat sync is active, a sent message is held until it appears in the
  /// delayed stream. This is the wall-clock moment it should surface.
  @State private var chatSyncSendDeadline: Date?
  @State private var chatSyncSendDelay: Double = 0
  @State private var chatSyncSendClearTask: Task<Void, Never>?
  @State private var hideTask: Task<Void, Never>?
  @State private var focusRecoveryTask: Task<Void, Never>?
  @State private var isQualityMenuPresented = false
  @State private var latencyTask: Task<Void, Never>?
  @State private var playbackWatchdogTask: Task<Void, Never>?
  @State private var wallClockLatencySeconds: Double?
  @State private var liveEdgeLatencySeconds: Double?
  @State private var smoothedLatencySeconds: Double?
  /// Total settled latency samples since playback became active.
  @State private var latencySampleCount = 0
  /// Consecutive samples whose smoothed value barely moved — i.e. the reading
  /// has stopped climbing off the live edge and looks trustworthy.
  @State private var latencyStableCount = 0
  // The real (pre-proxy) source URL of the currently loaded item, so we can tell
  // whether a quality switch actually needs to replace the item. AVURLAsset.url
  // is the rewritten twizz-ll:// URL in low-latency mode, so it can't be used
  // for this comparison directly.
  @State private var currentSourceURL: URL?
  @State private var isPlaybackActive = false
  @State private var didRequestPlayback = false
  @State private var lastHardCatchUpJumpAt = Date.distantPast
  @State private var lastWallClockCatchUpAt = Date.distantPast
  @State private var edgeLatencyLowConfidenceStreak = 0
  @State private var wallClockHighLatencyStreak = 0
  @State private var wallClockLowConfidenceStreak = 0
  @State private var lastPlaybackDateSample: Date?
  @State private var lastPlaybackTimeSampleSeconds: Double?
  @State private var lastObservedPlaybackTimeSeconds: Double?
  @State private var stalledPlaybackSamples = 0
  @State private var isRecoveringPlayback = false
  @State private var consecutiveLoadFailures = 0
  @State private var lastControlFocus: Focusable = .quality
  @State private var lastChatSettingsFocus: Focusable = .chatSettingsButton
  @State private var raidBannerDismissTask: Task<Void, Never>?
  /// The outgoing raid currently being followed (with a cancel window).
  @State private var outgoingRaid: OutgoingRaidEvent?
  @State private var outgoingRaidSecondsRemaining = 0
  @State private var outgoingRaidFollowTask: Task<Void, Never>?

  // MARK: Diagnostics (experimental troubleshooting overlay)
  // Counters and a rolling event log so freezes/jumps can be observed on-device
  // and reported back, rather than inferred. Only meaningful while the overlay
  // toggle is on; reset on each fresh load.
  @State private var diagStallCount = 0
  @State private var diagJumpCount = 0
  @State private var diagReloadCount = 0
  @State private var diagEvents: [DiagnosticsEvent] = []
  @State private var diagLastPlayheadSeconds: Double?
  @State private var diagLastSampleAt: Date?
  @State private var diagWasStalled = false
  @State private var diagIsFrozen = false
  @State private var diagFrozenSince: Date?
  @State private var diagSessionStartedAt: Date?
  @State private var diagInstabilityScore = 0
  @State private var diagLastInstabilityAt: Date?
  @State private var diagAdaptiveFallbackCount = 0

  private let controlsAutoHideSeconds: Double = 10
  // Latency tuning stays at the proven-stable baseline even in low-latency mode.
  // The latency win comes from the proxy promoting Twitch prefetch segments — not
  // from starving buffers or chasing the edge, both of which caused freezes and
  // blur on-device. Freeze-free playback is the top priority, then sharpness.
  private let targetLiveEdgeSeconds: Double = 3.5
  private let softCatchUpThresholdSeconds: Double = 8
  // In low-latency mode the proxy adds prefetch segments to the seekable window,
  // which inflates the seekable-edge latency metric. A zero-tolerance hard seek
  // against that inflated edge rebuffers and freezes, so disable hard seeks while
  // low-latency mode is on and rely on gentle rate correction + a healthy buffer.
  private var hardCatchUpThresholdSeconds: Double {
    lowLatencyProxyEnabled ? .greatestFiniteMagnitude : 14
  }
  private let hardCatchUpCooldownSeconds: Double = 20
  private let maxCatchUpRate: Float = 1.04
  private let edgeLatencyUnavailableEpsilonSeconds: Double = 0.2
  private let edgeLatencyUnavailableSamples = 4
  private let wallClockSoftCatchUpThresholdSeconds: Double = 12
  private let wallClockHardCatchUpThresholdSeconds: Double = 16
  private let wallClockHardCatchUpRequiredSamples = 10
  private let wallClockHardCatchUpCooldownSeconds: Double = 90
  private let targetWallClockSeconds: Double = 6.5
  private let wallClockUnavailableSamples = 4
  private let wallClockStaleDateDeltaEpsilonSeconds: Double = 0.08
  private let wallClockStalePlaybackAdvanceThresholdSeconds: Double = 0.6
  private let resolveTimeoutSeconds: Double = 18
  private let startupPlaybackTimeoutSeconds: Double = 14
  private let startupPlaybackPollMilliseconds: UInt64 = 500
  private let stalledPlaybackThresholdSamples = 6
  /// Warm-up gating for the latency badge. The live-edge gap reads ~0 right
  /// after playback starts and climbs to the true value over a few seconds, so
  /// we keep showing "Estimating latency…" until the reading settles: a couple
  /// of consecutive stable samples above a plausible floor. The max cap means a
  /// genuinely low-latency stream still resolves instead of estimating forever.
  private let latencyWarmUpMinSamples = 3
  private let latencyWarmUpMaxSamples = 10
  private let latencyStableSamplesRequired = 2
  private let latencyPlausibleFloorSeconds: Double = 2
  private let latencyStableDeltaSeconds: Double = 2
  private let playbackWatchdogIntervalSeconds: Double = 2
  // Diagnostics: how much unexplained playhead movement between 1s samples counts
  // as a "jump". Catch-up rate nudges (≤1.05x) only add a fraction of a second,
  // so a multi-second drift is a genuine AVPlayer skip, not normal catch-up.
  private let diagJumpForwardThresholdSeconds: Double = 2.0
  private let diagJumpBackwardThresholdSeconds: Double = 1.0
  // Stability guard: if stalls/jumps stack up within this rolling window while
  // pinned to a fixed rendition, fall back to Auto/adaptive before we keep
  // fighting the network with no ABR escape hatch.
  private let diagInstabilityWindowSeconds: Double = 75
  private let diagFallbackScoreThreshold = 3
  private let chatReplayMessageCount = 30
  private let chatComposerRowHeight: CGFloat = 62

  @FocusState private var focus: Focusable?
  private enum Focusable: Hashable {
    case video, streamInfo, quality, chatToggle, chatInput, errorBack
    case offlineViewChannel, offlineTryAgain
    case chatSend
    case raidFollowCancel
    case simulateRaidButton
    case simulateOfflineButton
    case chatSettingsButton
    // Main settings page
    case chatPresetOption(Int)
    case chatAdvancedButton
    case chatMoreButton
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
    case chatSyncToggle
    case chatLowLatencyToggle
    case chatDiagnosticsToggle
    case youtubeMergeToggle
    case youtubeMergeURL
    // Advanced settings page
    case chatAdvancedBack
    case chatStepperDec(ChatStepperField)
    case chatStepperInc(ChatStepperField)
    case chatEmoteAutoToggle
    case chatAnimatedToggle
    case chatFontOption(Int)
    case chatBadgesToggle
    case chatResetButton
  }

  /// Which page of the chat settings panel is currently shown.
  enum ChatSettingsPage: Hashable {
    /// Top-level: presets, layout, and drill-in rows.
    case main
    /// Fine-grained version of the Size preset (text/emote/line/spacing).
    case appearance
    /// Playback, stream sync, diagnostics, and experimental toggles.
    case playback
  }

  /// The granular dimensions adjusted by the Advanced page steppers.
  enum ChatStepperField: Hashable {
    case text
    case emote
    case lineHeight
    case messageSpacing
    case width
  }

  private var chatTextSize: CGFloat {
    CGFloat(chatTextSizeValue)
  }

  private var chatLineHeight: CGFloat {
    CGFloat(chatLineHeightValue)
  }

  private var chatMessageSpacing: CGFloat {
    CGFloat(chatMessageSpacingValue)
  }

  /// Resolved emote height: derived from the text size in Auto mode, otherwise
  /// the explicit stored value.
  private var chatEmoteSize: CGFloat {
    chatEmoteAuto
      ? ChatAppearance.autoEmoteHeight(forTextSize: chatTextSize)
      : CGFloat(chatEmoteSizeValue)
  }

  /// The active readability preset, or `nil` when the values are "Custom".
  private var activeChatPreset: ChatAppearancePreset? {
    ChatAppearancePreset.resolve(
      textSize: chatTextSize,
      lineHeight: chatLineHeight,
      messageSpacing: chatMessageSpacing,
      emoteIsAuto: chatEmoteAuto
    )
  }

  private var chatLayoutMode: ChatLayoutMode {
    ChatLayoutMode(rawValue: chatLayoutModeRaw) ?? .side
  }

  private var chatWidth: CGFloat {
    CGFloat(chatWidthValue)
  }

  private var chatFontStyle: ChatFontStyle {
    ChatFontStyle(rawValue: chatFontStyleRaw) ?? .standard
  }

  private var visibleChatMessages: [ChatMessage] {
    guard let startID = chatReplayStartMessageID else { return chat.messages }
    guard let startIndex = chat.messages.firstIndex(where: { $0.id == startID }) else {
      return chat.messages
    }
    return Array(chat.messages[startIndex...])
  }

  /// Trailing inset for the bottom control bar so its right-aligned buttons
  /// stay clear of (to the left of) the chat panel when chat floats over the
  /// full-width video in overlay/glass mode. In side mode the controls live in
  /// the shrunken video column, so the default edge padding is enough.
  private var controlsTrailingInset: CGFloat {
    guard showChat, chatLayoutMode.isOverlay else { return 48 }
    let gap: CGFloat = 24
    switch chatLayoutMode {
    case .glass:
      return chatWidth + GlassChatPaneStyle.edgeInset + gap
    case .overlay:
      return chatWidth + gap
    case .side:
      return 48
    }
  }

  var body: some View {
    ZStack {
      palette.playerBackdrop.ignoresSafeArea()
        // Attached to the backdrop (a child) rather than the root ZStack so it
        // doesn't collide with the sign-in `.fullScreenCover` below. Two
        // presentation modifiers on the *same* view conflict on tvOS and only
        // one fires, which previously left the avatar button doing nothing.
        .fullScreenCover(item: $channelPageTarget, onDismiss: { resumeAfterChannelPage() }) { target in
          ChannelPageView(
            target: target,
            onWatchChannel: { channel in
              // Tapping the live card of the channel we're already watching just
              // resumes playback; picking a *different* channel (e.g. from the
              // "More like this" rail) switches the player to it on dismiss.
              if channel.login.caseInsensitiveCompare(activeChannel) != .orderedSame {
                pendingSwitchLogin = channel.login
              }
              channelPageTarget = nil
            }
          )
          .environment(\.themePalette, palette)
        }

      if chatLayoutMode.isOverlay {
        videoColumn
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .ignoresSafeArea()

        if showChat {
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            chatPane
          }
          .ignoresSafeArea()
          .transition(.move(edge: .trailing))
        }
      } else {
        HStack(spacing: 0) {
          videoColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          if showChat {
            chatPane
              .transition(.move(edge: .trailing))
          }
        }
        .ignoresSafeArea()
      }

      if let raid = chat.pendingRaid {
        raidBanner(raid)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(10)
      }

      if let raid = outgoingRaid {
        outgoingRaidBanner(raid)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(11)
      }
    }
    .onChange(of: chat.pendingRaid) { _, newRaid in
      // Incoming raids (someone raiding the channel you're watching) are purely
      // informational: show a passive banner and auto-dismiss it. We never steal
      // focus or offer to "follow", because following would take you away from
      // the channel that is actually being raided.
      guard newRaid != nil else { return }
      raidBannerDismissTask?.cancel()
      raidBannerDismissTask = Task {
        try? await Task.sleep(for: .seconds(12))
        guard !Task.isCancelled else { return }
        withAnimation { chat.pendingRaid = nil }
      }
    }
    .onChange(of: eventSub.pendingOutgoingRaid) { _, newRaid in
      // Outgoing raids (the channel you're watching raiding someone else):
      // mirror Twitch's native behavior and follow by default, but give a brief
      // cancelable window first.
      guard let newRaid else { return }
      beginOutgoingRaidFollow(newRaid)
    }
    .task {
      if activeChannel.isEmpty { activeChannel = channel }
      configurePlayerForLive()
      resetDiagnostics()
      applyExperimentalYouTubeSettings()
      chat.connect(to: activeChannel)
      eventSub.start(forChannel: activeChannel, auth: auth)
      async let metadataTask: Void = refreshChannelMetadata()
      await load()
      _ = await metadataTask
      focus = .video
    }
    .onAppear {
      setIdleTimer(disabled: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) { notification in
      guard let stalledItem = notification.object as? AVPlayerItem else { return }
      guard stalledItem == player.currentItem else { return }
      markDiagnosticsStall(reason: "AVPlayerItemPlaybackStalled")
    }
    .onDisappear {
      hideTask?.cancel()
      focusRecoveryTask?.cancel()
      chatSyncSendClearTask?.cancel()
      outgoingRaidFollowTask?.cancel()
      stopPlaybackWatchdog()
      stopLatencyMonitor()
      audioLevelMonitor.stop()
      player.pause()
      chat.disconnect()
      eventSub.stop()
      setIdleTimer(disabled: false)
    }
    .onExitCommand {
      if showChatSettings {
        if chatSettingsPage != .main {
          closeSubpage()
        } else {
          showChatSettings = false
          focus = .chatSettingsButton
        }
      } else if showControls {
        hideControls()
      } else {
        dismiss()
      }
    }
    .onMoveCommand { direction in
      if !showControls {
        // Directional movement should immediately surface controls and
        // land on chat toggle so moving off chat feels instant.
        revealControls(preferredFocus: .chatToggle)
      } else {
        scheduleHide()
      }
    }
    .onChange(of: focus) { _, newFocus in
      if showChatSettings {
        guard let newFocus else {
          focus = lastChatSettingsFocus
          return
        }

        if isChatSettingsFocus(newFocus) {
          lastChatSettingsFocus = newFocus
        } else {
          focus = lastChatSettingsFocus
        }
        return
      }

      // Keep control navigation deterministic: if tvOS drops focus to nil
      // while controls are visible, immediately restore last valid control.
      guard showControls else {
        return
      }

      if let newFocus, isControlFocus(newFocus) {
        focusRecoveryTask?.cancel()
        lastControlFocus = newFocus
        scheduleHide()
      } else if newFocus == nil, !isQualityMenuPresented {
        // tvOS can briefly drop focus to nil after system surfaces (like Menu)
        // dismiss. Re-assert the last control if focus doesn't come back.
        focusRecoveryTask?.cancel()
        let target = lastControlFocus
        focusRecoveryTask = Task {
          try? await Task.sleep(for: .milliseconds(140))
          guard !Task.isCancelled else { return }
          await MainActor.run {
            guard showControls, !showChatSettings, !isQualityMenuPresented else { return }
            guard focus == nil else { return }
            focus = target
          }
        }
      }
    }
    .onChange(of: experimentalYouTubeMergeEnabled) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: experimentalYouTubeMergeChannelOrURL) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: lowLatencyProxyEnabled) { _, _ in
      // Rebuild the asset pipeline so the proxy is attached/detached cleanly.
      configurePlayerForLive()
      Task { await load(reason: "lowLatencyToggle", resetMetadata: false) }
    }
    .fullScreenCover(isPresented: $showSignInSheet) {
      SignInView(auth: auth)
    }
  }

  // MARK: - Video + controls

  /// True when the user has explicitly pinned the audio-only rendition, so the
  /// player surface is black and the visualizer should take over.
  private var isAudioOnlyActive: Bool {
    guard let playback else { return false }
    guard let audioName = playback.qualities.first(where: { $0.isAudioOnly })?.name else {
      return false
    }
    return audioName == preferredQuality
  }

  /// Direct media-playlist URL for the audio-only rendition, used by the
  /// visualizer's level decoder.
  private var audioOnlyPlaylistURL: URL? {
    playback?.qualities.first(where: { $0.isAudioOnly })?.url
  }

  private var videoColumn: some View {
    ZStack(alignment: .bottom) {
      VideoSurface(player: player)
        .ignoresSafeArea()

      if isAudioOnlyActive, !isLoading, errorMessage == nil, !isOffline {
        AudioVisualizerView(
          level: audioLevelMonitor.level,
          avatarURL: channelAvatarURL,
          palette: palette
        )
        .transition(.opacity)
        .onAppear {
          audioLevelMonitor.start(
            audioPlaylistURL: audioOnlyPlaylistURL,
            headers: PlaybackService.streamHeaders
          )
        }
        .onDisappear { audioLevelMonitor.stop() }
      }

      if showControls, !isLoading,
        errorMessage == nil, !isOffline
      {
        VStack {
          HStack {
            LatencyBadge(color: latencyColor, label: latencyLabel)
            Spacer()
          }
          if showLatencyDiagnostics {
            HStack {
              DiagnosticsPanel(lines: diagnosticsLines, events: diagEvents)
              Spacer()
            }
            .padding(.top, 12)
          }
          Spacer()
        }
        .padding(.top, 36)
        .padding(.leading, 40)
      }

      // Only expose the video focus target while controls are hidden.
      // Otherwise, left-edge movement from the control cluster can escape
      // into this invisible target and appear as lost focus.
      if !showControls, !isOffline {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .focusable()
          .focused($focus, equals: .video)
          .onTapGesture { revealControls(preferredFocus: .quality) }
      }

      if isLoading {
        ProgressView("Loading \(activeChannel)…")
          .font(.title3)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }

      if isOffline {
        offlineState
      } else if let errorMessage {
        VStack(spacing: 24) {
          Text("Couldn't play \(activeChannel)")
            .font(.title2).bold()
          Text(errorMessage)
            .foregroundStyle(.secondary)
          Button("Back") { dismiss() }
            .focused($focus, equals: .errorBack)
        }
        .padding(40)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
      } else if showControls {
        bottomOverlay
      }
    }
  }

  // MARK: - Offline empty state

  private var offlineDisplayName: String {
    channelDisplayName.isEmpty ? activeChannel : channelDisplayName
  }

  private var offlineState: some View {
    ZStack {
      // Opaque backdrop so the frozen last frame never bleeds through.
      palette.playerBackdrop.ignoresSafeArea()

      VStack(spacing: 28) {
        offlineAvatar

        VStack(spacing: 10) {
          Text("OFFLINE")
            .font(.caption.weight(.bold))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.white.opacity(0.10), in: Capsule())

          Text(offlineDisplayName)
            .font(.system(size: 46, weight: .bold))
            .foregroundStyle(.white)

          Text("The stream has ended.")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))

          Text("Catch up on recent videos and clips, or check back soon.")
            .font(.body)
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
        }

        HStack(spacing: 20) {
          Button {
            presentChannelPage()
          } label: {
            Label("View Channel", systemImage: "play.rectangle.on.rectangle")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .buttonStyle(.borderedProminent)
          .tint(ThemePalette.brandPurple)
          .focused($focus, equals: .offlineViewChannel)

          Button {
            retryFromOffline()
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .TwizzControlButtonStyle()
          .focused($focus, equals: .offlineTryAgain)
        }
        .padding(.top, 8)
      }
      .frame(maxWidth: 760)
      .padding(48)
    }
    .transition(.opacity)
  }

  @ViewBuilder
  private var offlineAvatar: some View {
    Group {
      if let channelAvatarURL {
        AsyncImage(url: channelAvatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          offlineAvatarPlaceholder
        }
      } else {
        offlineAvatarPlaceholder
      }
    }
    .frame(width: 132, height: 132)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .grayscale(0.6)
    .opacity(0.9)
  }

  private var offlineAvatarPlaceholder: some View {
    ZStack {
      Circle().fill(.white.opacity(0.10))
      Icon(glyph: .userCircle, size: 64)
        .foregroundStyle(.white.opacity(0.7))
    }
  }

  private var bottomOverlay: some View {
    HStack(alignment: .top, spacing: 24) {
      HStack(alignment: .top, spacing: 12) {
        Button {
          presentChannelPage()
        } label: {
          Group {
            if let channelAvatarURL {
              AsyncImage(url: channelAvatarURL) { image in
                image
                  .resizable()
                  .scaledToFill()
              } placeholder: {
                ZStack {
                  Circle().fill(.white.opacity(0.16))
                  Icon(glyph: .userCircle, size: 36)
                    .foregroundStyle(.white.opacity(0.85))
                }
              }
            } else {
              ZStack {
                Circle().fill(.white.opacity(0.16))
                Icon(glyph: .userCircle, size: 36)
                  .foregroundStyle(.white.opacity(0.85))
              }
            }
          }
          .frame(width: 36, height: 36)
          .clipShape(Circle())
        }
        .TwizzControlButtonStyle()
        .focused($focus, equals: .streamInfo)
        .onMoveCommand { direction in
          switch direction {
          case .right:
            focus = .quality
          case .left:
            focus = .streamInfo
          default:
            break
          }
        }

        Text(streamTitle.isEmpty ? channelDisplayName : streamTitle)
          .font(.headline)
          .foregroundStyle(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.5)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
          .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Spacer(minLength: 18)

      HStack(spacing: 14) {
        // The visible menu content is kept `.equatable()` so the player's
        // once-per-second latency churn doesn't re-render (and blink) the open
        // menu. The focus + navigation modifiers are applied OUTSIDE that
        // equatable boundary on purpose: `.equatable()` freezes the wrapped
        // subtree when its inputs are unchanged, and if `.focused` lived inside
        // it the focus binding would freeze too — so when the menu closed the
        // focus system had no live binding to restore to and focus only snapped
        // back on the next unrelated re-render (~1-2s later). Keeping `.focused`
        // here keeps the binding live so focus returns to the button instantly.
        QualityMenu(
          options: qualityOptions,
          selectedOption: preferredQuality,
          buttonLabel: qualityButtonLabel,
          reservedWidthLabels: qualityButtonLabelCandidates,
          displayLabel: { qualityDisplayLabel($0) },
          onSelect: { selectQuality(at: $0) },
          onMenuPresented: {
            focusRecoveryTask?.cancel()
            isQualityMenuPresented = true
            // Keep `focus == .quality` while the menu is open so tvOS keeps the
            // button visually "lifted" (its focus shadow) behind the popup for
            // the menu's whole lifetime, and so focus returns to it instantly
            // on dismiss.
          },
          onMenuDismissed: {
            isQualityMenuPresented = false
            focusRecoveryTask?.cancel()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              focus = .quality
            }
            focusRecoveryTask = Task {
              // Let close animation settle, then restore anchor focus if needed.
              try? await Task.sleep(for: .milliseconds(40))
              guard !Task.isCancelled else { return }
              await MainActor.run {
                guard showControls, !showChatSettings, !isQualityMenuPresented else { return }
                guard focus == nil || focus == .quality else { return }
                focus = .quality
              }
            }
          }
        )
        .equatable()
        .focused($focus, equals: .quality)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .streamInfo
          case .right:
            focus = .chatToggle
          default:
            break
          }
        }

        Button {
          toggleChatVisibility()
          if !showChat, focus == .chatInput {
            focus = .chatToggle
          }
          scheduleHide()
        } label: {
          Icon(glyph: showChat ? .sidebarRightCollapse : .sidebarRightExpand)
            .accessibilityLabel(showChat ? "Hide Chat" : "Show Chat")
        }
        .focused($focus, equals: .chatToggle)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .quality
          case .right:
            if showChat {
              focus = .chatInput
            }
          default:
            break
          }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .TwizzControlButtonStyle()
      .focusSection()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 48)
    .padding(.trailing, controlsTrailingInset)
    .padding(.top, 12)
    .padding(.bottom, 42)
    .background(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.72), location: 0.56),
          .init(color: .black.opacity(1.0), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity)
      .frame(height: 280)
      .allowsHitTesting(false),
      alignment: .bottom
    )
  }

  // MARK: - Diagnostics overlay

  /// The fixed metric rows, each computed live from the current item.
  private var diagnosticsLines: [String] {
    var lines: [String] = []

    let mode = lowLatencyProxyEnabled ? "LL proxy ON" : "LL proxy off"
    let pin = preferredQuality == "Auto" ? "Auto/adaptive" : "\(preferredQuality) (pinned)"
    lines.append("Mode: \(mode) · \(pin)")

    if let item = player.currentItem {
      let size = item.presentationSize
      if size.width > 0, size.height > 0 {
        lines.append(
          "Render: \(Int(size.width))×\(Int(size.height)) · Rate: \(diagFormat(Double(player.rate), decimals: 2))x"
        )
      } else {
        lines.append("Render: — · Rate: \(diagFormat(Double(player.rate), decimals: 2))x")
      }

      if let event = item.accessLog()?.events.last {
        lines.append(
          "Bitrate: \(diagBitrate(event.indicatedBitrate)) shown · \(diagBitrate(event.observedBitrate)) obs"
        )
        lines.append(
          "Dropped frames: \(event.numberOfDroppedVideoFrames) · AVStalls: \(event.numberOfStalls)"
        )
      } else {
        lines.append("Bitrate: — (no access log yet)")
      }

      lines.append("Buffer ahead: \(diagBufferAheadDescription(item))")
    } else {
      lines.append("No active item")
    }

    let edge = liveEdgeLatencySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "—"
    let wall = wallClockLatencySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "—"
    let chatHold =
      chatSyncToStream
      ? (chatSyncDelaySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "measuring")
      : "off"
    if diagIsFrozen {
      let frozenFor = diagFrozenSince.map { max(0, Int(Date().timeIntervalSince($0).rounded())) } ?? 0
      lines.append("State: FROZEN (\(frozenFor)s) · Waiting: \(diagWaitingReasonDescription())")
    } else {
      lines.append("State: Playing/waiting · Waiting: \(diagWaitingReasonDescription())")
    }
    lines.append("Edge gap: \(edge) · Encoder: \(wall)")
    lines.append("Chat hold: \(chatHold)")
    lines.append("Stalls: \(diagStallCount) · Jumps: \(diagJumpCount) · Reloads: \(diagReloadCount)")
    lines.append("Stability score: \(diagInstabilityScore) · Auto-fallbacks: \(diagAdaptiveFallbackCount)")

    return lines
  }

  private func diagFormat(_ value: Double, decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
  }

  private func diagBitrate(_ bitsPerSecond: Double) -> String {
    guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "—" }
    return "\(diagFormat(bitsPerSecond / 1_000_000, decimals: 1)) Mbps"
  }

  private func diagBufferAheadDescription(_ item: AVPlayerItem) -> String {
    let current = CMTimeGetSeconds(item.currentTime())
    guard current.isFinite else { return "—" }
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = CMTimeGetSeconds(range.start)
      let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
      if start.isFinite, end.isFinite, current >= start - 0.5, current <= end + 0.5 {
        return "\(diagFormat(max(0, end - current), decimals: 1))s"
      }
    }
    return "—"
  }

  private func diagWaitingReasonDescription() -> String {
    if player.timeControlStatus == .playing { return "none" }
    if let reason = player.reasonForWaitingToPlay {
      if reason == .toMinimizeStalls { return "toMinimizeStalls" }
      if reason == .evaluatingBufferingRate { return "evaluatingBufferingRate" }
      if reason == .noItemToPlay { return "noItemToPlay" }
      return String(describing: reason)
    }
    if player.currentItem?.isPlaybackBufferEmpty == true { return "bufferEmpty" }
    if player.currentItem?.isPlaybackLikelyToKeepUp == false { return "notLikelyToKeepUp" }
    return "unknown"
  }

  /// Records a diagnostics event, keeping only the most recent few (newest first).
  private func logDiagnosticsEvent(_ text: String) {
    diagEvents.insert(DiagnosticsEvent(at: Date(), text: text), at: 0)
    if diagEvents.count > 6 {
      diagEvents.removeLast(diagEvents.count - 6)
    }
  }

  private func markDiagnosticsStall(reason: String) {
    if !diagIsFrozen {
      diagIsFrozen = true
      diagFrozenSince = Date()
    }
    if !diagWasStalled {
      diagWasStalled = true
      diagStallCount += 1
      if showLatencyDiagnostics {
        logDiagnosticsEvent("stall (\(reason))")
      }
      registerInstability(points: 2, reason: reason)
    }
  }

  private func registerInstability(points: Int, reason: String) {
    let now = Date()
    if let last = diagLastInstabilityAt, now.timeIntervalSince(last) > diagInstabilityWindowSeconds {
      diagInstabilityScore = 0
    }
    diagLastInstabilityAt = now
    diagInstabilityScore += points
    maybeTriggerAdaptiveFallback(trigger: reason)
  }

  /// If fixed-quality playback becomes unstable, switch to Auto/adaptive so ABR
  /// can step down instead of stalling/jumping repeatedly.
  private func maybeTriggerAdaptiveFallback(trigger: String) {
    guard diagInstabilityScore >= diagFallbackScoreThreshold else { return }
    guard preferredQuality != "Auto" else { return }
    guard playback != nil else { return }

    preferredQuality = "Auto"
    applyQualityPreference("Auto")
    diagAdaptiveFallbackCount += 1
    diagInstabilityScore = 0

    if showLatencyDiagnostics {
      logDiagnosticsEvent("stability fallback -> Auto (\(trigger))")
    }
  }

  /// Detects forward/backward playhead jumps by comparing actual playhead
  /// advance against wall-clock × rate between 1s samples. A genuine AVPlayer
  /// skip-to-live shows up as several seconds of unexplained forward advance.
  private func sampleDiagnostics() {
    guard showLatencyDiagnostics else {
      diagLastPlayheadSeconds = nil
      diagLastSampleAt = nil
      return
    }
    guard isPlaybackActive, let item = player.currentItem else {
      diagLastPlayheadSeconds = nil
      diagLastSampleAt = nil
      return
    }

    let now = Date()
    let playhead = CMTimeGetSeconds(item.currentTime())
    guard playhead.isFinite else { return }

    if let lastPlayhead = diagLastPlayheadSeconds, let lastAt = diagLastSampleAt {
      let wall = now.timeIntervalSince(lastAt)
      let advanced = playhead - lastPlayhead
      let expected = wall * Double(max(player.rate, 0))
      let forwardDrift = advanced - expected

      if forwardDrift >= diagJumpForwardThresholdSeconds {
        diagJumpCount += 1
        logDiagnosticsEvent("jump +\(diagFormat(forwardDrift, decimals: 1))s forward")
        registerInstability(points: 1, reason: "jump forward")
      } else if advanced <= -diagJumpBackwardThresholdSeconds {
        diagJumpCount += 1
        logDiagnosticsEvent("jump \(diagFormat(advanced, decimals: 1))s back")
        registerInstability(points: 1, reason: "jump back")
      }

      if advanced >= 0.05 {
        diagIsFrozen = false
        diagFrozenSince = nil
        diagWasStalled = false
      }
    }

    diagLastPlayheadSeconds = playhead
    diagLastSampleAt = now
  }

  private func resetDiagnostics() {
    diagStallCount = 0
    diagJumpCount = 0
    diagReloadCount = 0
    diagEvents = []
    diagLastPlayheadSeconds = nil
    diagLastSampleAt = nil
    diagWasStalled = false
    diagIsFrozen = false
    diagFrozenSince = nil
    diagSessionStartedAt = Date()
    diagInstabilityScore = 0
    diagLastInstabilityAt = nil
    diagAdaptiveFallbackCount = 0
  }

  // MARK: - Controls visibility

  private func revealControls(preferredFocus: Focusable) {
    focusRecoveryTask?.cancel()
    if !showControls {
      showControls = true
    }
    if isControlFocus(preferredFocus) {
      lastControlFocus = preferredFocus
    }
    focus = preferredFocus
    scheduleHide()
  }

  private func hideControls() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    showControls = false
    focus = .video
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(controlsAutoHideSeconds))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        // Don't auto-hide while the quality menu is engaged. When the native
        // Menu is open, tvOS owns focus and our FocusState reads nil, while
        // `lastControlFocus` still points at `.quality`. In that case re-arm
        // instead of hiding so the control bar — and the menu anchored to it —
        // stay on screen. Normal auto-hide resumes once focus lands on another
        // control.
        if focus == .quality || (focus == nil && lastControlFocus == .quality) {
          scheduleHide()
          return
        }
        if isQualityMenuPresented {
          scheduleHide()
          return
        }
        hideControls()
      }
    }
  }

  // MARK: - Channel page

  /// Opens the full-screen channel page for the active channel. The live stream
  /// is paused while the page is up, and its latency monitor + watchdog are
  /// suspended so the non-advancing playhead isn't mistaken for a stall.
  private func presentChannelPage() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    stopPlaybackWatchdog()
    stopLatencyMonitor()
    player.pause()
    channelPageTarget = ChannelPageTarget(
      login: activeChannel,
      displayName: channelDisplayName.isEmpty ? activeChannel : channelDisplayName,
      profileImageURL: channelAvatarURL
    )
  }

  /// Resumes live playback once the channel page is dismissed — or switches to a
  /// different channel if the user picked one from the page's "More like this".
  private func resumeAfterChannelPage() {
    if let login = pendingSwitchLogin {
      pendingSwitchLogin = nil
      followRaid(login)
      return
    }
    // Don't resurrect a dead stream — if we entered the channel page from the
    // offline empty state, return straight back to it.
    if isOffline {
      focus = .offlineViewChannel
      return
    }
    startPlayback()
    startLatencyMonitor()
    startPlaybackWatchdog()
    if showControls {
      focus = .streamInfo
      scheduleHide()
    } else {
      focus = .video
    }
  }

  private func toggleChatVisibility() {
    showChat.toggle()
    if showChat {
      chatReplayStartMessageID = chat.messages.suffix(chatReplayMessageCount).first?.id
    } else {
      chatReplayStartMessageID = nil
      showChatSettings = false
    }
  }

  private func isControlFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .streamInfo, .quality, .chatToggle, .chatInput:
      return true
    default:
      return false
    }
  }

  private func isChatSettingsFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .chatSettingsButton,
      .chatPresetOption,
      .chatAdvancedButton,
      .chatMoreButton,
      .chatWidthOption,
      .chatLayoutOption,
      .chatSyncToggle,
      .chatLowLatencyToggle,
      .chatDiagnosticsToggle,
      .simulateRaidButton,
      .simulateOfflineButton,
      .youtubeMergeToggle,
      .youtubeMergeURL,
      .chatAdvancedBack,
      .chatStepperDec,
      .chatStepperInc,
      .chatEmoteAutoToggle,
      .chatAnimatedToggle,
      .chatFontOption,
      .chatBadgesToggle,
      .chatResetButton:
      return true
    default:
      return false
    }
  }

  private var chatPane: some View {
    let isGlass = chatLayoutMode == .glass
    let useLighterOverlayBackground = chatLayoutMode == .overlay
    return VStack(spacing: 0) {
      ChatView(
        channel: channel,
        messages: visibleChatMessages,
        textSize: chatTextSize,
        emoteSize: chatEmoteSize,
        messageSpacing: chatMessageSpacing,
        lineHeight: chatLineHeight,
        animatedEmotes: chatAnimatedEmotes,
        fontDesign: chatFontStyle.design,
        showBadges: chatShowBadges,
        isConnected: chat.isConnected,
        emoteURLs: chat.emoteURLs,
        badgeURLs: chat.badgeURLs,
        useGlassBackground: isGlass,
        useLighterOverlayBackground: useLighterOverlayBackground
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      chatComposerBar
    }
    .frame(width: chatWidth)
    .modifier(GlassChatPaneStyle(enabled: isGlass))
    // Prevent the glass container from showing a focus glow when interactive
    // elements inside (e.g. the chat input) receive focus.
    .focusEffectDisabled()
    // The settings panel floats to the LEFT of the chat so the whole chat stays
    // visible while you adjust it. It is attached *outside* GlassChatPaneStyle so
    // the glass pane's rounded clip never hides it in glass layout mode.
    .overlay(alignment: .topLeading) {
      if showChatSettings {
        let inset: CGFloat = isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16
        GeometryReader { geo in
          chatSettingsPanel(maxHeight: max(geo.size.height - inset * 2, 0))
            .frame(width: chatSettingsPanelWidth)
            .padding(.vertical, inset)
            .offset(x: -(chatSettingsPanelWidth + chatSettingsPanelGap))
        }
        .frame(width: chatSettingsPanelWidth)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    // Keep the settings button pinned to the top-right of the chat. It stays put
    // while the panel opens to the left — intentionally disconnected so the chat
    // is never covered.
    .overlay(alignment: .topTrailing) {
      chatSettingsButton
        .padding(.top, isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16)
        .padding(.trailing, isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16)
    }
    .animation(.easeOut(duration: 0.18), value: showChatSettings)
  }

  private let chatSettingsPanelWidth: CGFloat = 560
  private let chatSettingsPanelGap: CGFloat = 16

  // MARK: - Floating chat settings

  /// The compact button that toggles the settings panel. It is only reachable by
  /// pressing up from the chat input, so it never steals focus while the user is
  /// scrolling or typing.
  private var chatSettingsButton: some View {
    Button {
      toggleChatSettings()
    } label: {
      Icon(glyph: showChatSettings ? .x : .adjustmentsHorizontal)
        .frame(width: Icon.controlButtonSize, height: Icon.controlButtonSize)
    }
    .TwizzControlButtonStyle()
    .focused($focus, equals: .chatSettingsButton)
    .onMoveCommand { direction in
      if direction == .down, showChatSettings {
        focus = firstChatSettingsFocus
      } else if direction == .down {
        focus = .chatInput
      }
    }
  }

  /// The focus target for the first control on whichever settings page is shown.
  private var firstChatSettingsFocus: Focusable {
    switch chatSettingsPage {
    case .appearance, .playback:
      return .chatAdvancedBack
    case .main:
      let index = (activeChatPreset.flatMap { ChatAppearancePreset.allCases.firstIndex(of: $0) }) ?? 1
      return .chatPresetOption(index)
    }
  }

  private func chatSettingsPanel(maxHeight: CGFloat) -> some View {
    // Measured content height, capped to the space available beside the chat.
    // When the content is shorter than the cap the panel shrinks to fit; only
    // when it would overflow does the inner ScrollView start scrolling.
    let resolvedHeight = chatSettingsContentHeight > 0
      ? min(chatSettingsContentHeight, maxHeight)
      : maxHeight

    return ScrollView(.vertical, showsIndicators: false) {
      Group {
        switch chatSettingsPage {
        case .main:
          mainSettingsContent
        case .appearance:
          appearanceSettingsContent
        case .playback:
          playbackSettingsContent
        }
      }
      .padding(.vertical, 18)
      .padding(.horizontal, 30)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: ChatSettingsHeightKey.self,
            value: proxy.size.height
          )
        }
      )
    }
    .frame(maxWidth: .infinity)
    .frame(height: resolvedHeight, alignment: .top)
    .onPreferenceChange(ChatSettingsHeightKey.self) { height in
      chatSettingsContentHeight = height
    }
    // Match the chat pane's real Liquid Glass (`.glassEffect(.regular)`) so the
    // panel reads the same as the Glass chat layout, instead of a flatter
    // frosted material. Intentionally no clipShape: tvOS focus effects scale
    // beyond bounds, and clipping reintroduces visibly cut-off focus states.
    .modifier(ChatSettingsPanelGlassStyle())
    .shadow(color: .black.opacity(0.30), radius: 22, x: 0, y: 10)
    .animation(.easeOut(duration: 0.22), value: resolvedHeight)
    .focusSection()
  }

  // MARK: Main settings page

  private var mainSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Appearance")

        HStack(spacing: 8) {
          ForEach(Array(ChatAppearancePreset.allCases.enumerated()), id: \.element) { index, preset in
            settingsPill(
              title: preset.title,
              isSelected: activeChatPreset == preset,
              focusTag: .chatPresetOption(index)
            ) {
              applyChatPreset(preset)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        settingsDisclosureRow(
          title: "Advanced",
          detail: activeChatPreset?.title ?? "Custom",
          focusTag: .chatAdvancedButton
        ) {
          openSubpage(.appearance)
        }
        .focusSection()

        Text("Presets adjust text, emote, line height, and spacing together. Use Advanced for per-value control.")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Chat Width")
        settingsStepperRow(.width)
      }

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Chat Position")

        HStack(spacing: 8) {
          ForEach(Array(ChatLayoutMode.allCases.enumerated()), id: \.element) { index, mode in
            settingsPill(
              title: mode.title,
              isSelected: mode == chatLayoutMode,
              focusTag: .chatLayoutOption(index)
            ) {
              chatLayoutModeRaw = mode.rawValue
              // Switching layout restructures the view tree (chat moves
              // between docked and overlay), which drops focus. Re-assert it
              // on the just-selected pill once the new tree is laid out.
              Task { @MainActor in
                focus = .chatLayoutOption(index)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      settingsDisclosureRow(
        title: "Playback & Diagnostics",
        detail: lowLatencyProxyEnabled ? "Low-Latency On" : nil,
        focusTag: .chatMoreButton
      ) {
        openSubpage(.playback)
      }
      .focusSection()
    }
  }

  // MARK: Playback & diagnostics sub-page

  private var playbackSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      subpageHeader("Playback & Diagnostics")

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Stream Sync")

        settingsPill(
          title: chatSyncToStream ? "Synced to Stream Delay" : "Match Stream Delay",
          isSelected: chatSyncToStream,
          focusTag: .chatSyncToggle
        ) {
          chatSyncToStream.toggle()
          applyChatSyncSettings()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(chatSyncStatusDescription)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)
      }
      .focusSection()

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Playback")

        settingsPill(
          title: lowLatencyProxyEnabled ? "Low-Latency Mode On" : "Low-Latency Mode Off",
          isSelected: lowLatencyProxyEnabled,
          focusTag: .chatLowLatencyToggle
        ) {
          lowLatencyProxyEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: showLatencyDiagnostics ? "Diagnostics Overlay On" : "Diagnostics Overlay Off",
          isSelected: showLatencyDiagnostics,
          focusTag: .chatDiagnosticsToggle
        ) {
          showLatencyDiagnostics.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if showLatencyDiagnostics {
          // Debug-only: outgoing raids can't be triggered on demand, so this
          // injects a simulated one (raiding to Monstercat, a near-24/7 stream)
          // to exercise the auto-follow banner + redirect. Visible only while the
          // Diagnostics overlay is enabled.
          settingsPill(
            title: "Simulate Outgoing Raid",
            isSelected: false,
            focusTag: .simulateRaidButton
          ) {
            simulateOutgoingRaid()
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          // Debug-only: there's no way to force a watched channel offline, so
          // this drops straight into the offline empty state to exercise its
          // layout, copy, and View Channel / Try Again actions. Visible only
          // while the Diagnostics overlay is enabled.
          settingsPill(
            title: "Simulate Stream Offline",
            isSelected: false,
            focusTag: .simulateOfflineButton
          ) {
            showChatSettings = false
            presentOfflineState()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text(
          "Low-Latency Mode rewrites Twitch prefetch segments to reduce delay. Diagnostics shows live render/bitrate/buffer and freeze/jump events."
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      }
      .focusSection()

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Experimental")

        settingsPill(
          title: "Merge with YouTube Chat",
          isSelected: experimentalYouTubeMergeEnabled,
          focusTag: .youtubeMergeToggle
        ) {
          experimentalYouTubeMergeEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          // Seed the keyboard with the value the field is showing so editing
          // starts from the resolved default rather than a blank line.
          if experimentalYouTubeMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
             !youtubeMergeDefaultTarget.isEmpty {
            experimentalYouTubeMergeChannelOrURL = youtubeMergeDefaultTarget
          }
          youtubeInputActivationToken &+= 1
        } label: {
          Text(youtubeMergeDisplayText)
            .font(.subheadline)
            .foregroundStyle(focus == .youtubeMergeURL ? .black : .white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .youtubeMergeURL))
            .background(
              ChatKeyboardHostField(
                text: $experimentalYouTubeMergeChannelOrURL,
                activationToken: youtubeInputActivationToken,
                onSubmit: {},
                returnKeyType: .done,
                dismissesOnReturn: true,
                keyboardPrompt: "YouTube handle or channel URL"
              )
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            )
        }
        .buttonStyle(ChatInputButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .youtubeMergeURL)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: focus == .youtubeMergeURL)

        if let status = chat.youtubeStatusMessage, experimentalYouTubeMergeEnabled {
          HStack(spacing: 6) {
            if status.hasPrefix("YouTube chat connected") {
              Icon(glyph: .circleCheckFilled, size: 18)
                .foregroundStyle(.green)
            }

            Text(status)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.76))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .focusSection()
    }
  }

  // MARK: Appearance (Advanced) sub-page

  private var appearanceSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      subpageHeader("Advanced")

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Readability")

        settingsStepperRow(.text)
        settingsStepperRow(.lineHeight)
        settingsStepperRow(.messageSpacing)
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Emotes")

        settingsPill(
          title: chatEmoteAuto ? "Emote Size: Auto" : "Emote Size: Custom",
          isSelected: chatEmoteAuto,
          focusTag: .chatEmoteAutoToggle
        ) {
          chatEmoteAuto.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        if !chatEmoteAuto {
          settingsStepperRow(.emote)
        }

        settingsPill(
          title: chatAnimatedEmotes ? "Animated Emotes On" : "Animated Emotes Off",
          isSelected: chatAnimatedEmotes,
          focusTag: .chatAnimatedToggle
        ) {
          chatAnimatedEmotes.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        Text(chatEmoteAuto
          ? "Auto keeps emotes proportional to the text size."
          : "Custom sets emote height independently of the text size.")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Typeface")

        HStack(spacing: 8) {
          ForEach(Array(ChatFontStyle.allCases.enumerated()), id: \.element) { index, style in
            settingsPill(
              title: style.title,
              isSelected: style == chatFontStyle,
              focusTag: .chatFontOption(index)
            ) {
              chatFontStyleRaw = style.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Badges")

        settingsPill(
          title: chatShowBadges ? "Badges On" : "Badges Off",
          isSelected: chatShowBadges,
          focusTag: .chatBadgesToggle
        ) {
          chatShowBadges.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        Text("Hides the small mod, sub, and other badges shown before each name.")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize(horizontal: false, vertical: true)
      }

      Button {
        resetChatAppearance()
      } label: {
        Text("Reset to Normal")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 24)
          .padding(.vertical, 9)
          .modifier(ChatSettingsGlassStyle(isFocused: focus == .chatResetButton, isSelected: false))
      }
      .buttonStyle(ChatSettingsPillButtonStyle())
      .focusEffectDisabled()
      .focused($focus, equals: .chatResetButton)
      .focusSection()
    }
  }

  private func settingsSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.84))
      .textCase(.uppercase)
  }

  // MARK: Settings controls

  private func settingsPill(
    title: String,
    isSelected: Bool,
    icon: Glyph? = nil,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    let isFocused = focus == focusTag

    return Button(action: action) {
      HStack(spacing: 8) {
        if let icon {
          Icon(glyph: icon, size: 22)
        }

        Text(title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 8)
      .modifier(ChatSettingsGlassStyle(isFocused: isFocused, isSelected: isSelected))
    }
    // Passthrough press style; the focus lift comes from ChatSettingsGlassStyle
    // so it matches the app's liquid-glass focus treatment.
    .buttonStyle(ChatSettingsPillButtonStyle())
    .focusEffectDisabled()
    .focused($focus, equals: focusTag)
  }

  /// Full-width disclosure row (Apple-style): title on the left, optional detail
  /// plus a right-facing chevron on the right, used to drill into a sub-page.
  private func settingsDisclosureRow(
    title: String,
    detail: String? = nil,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    let isFocused = focus == focusTag

    return Button(action: action) {
      HStack(spacing: 10) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)

        Spacer(minLength: 12)

        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(isFocused ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.white.opacity(0.55)))
            .lineLimit(1)
        }

        // No dedicated right-chevron glyph exists, so reuse the left chevron
        // rotated 180°.
        Icon(glyph: .chevronLeft, size: 36)
          .rotationEffect(.degrees(180))
          .opacity(0.7)
      }
      .padding(.horizontal, 26)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(ChatSettingsGlassStyle(isFocused: isFocused, isSelected: false))
    }
    .buttonStyle(ChatSettingsPillButtonStyle())
    .focusEffectDisabled()
    .focused($focus, equals: focusTag)
  }

  /// The Back button + title shown at the top of a settings sub-page.
  private func subpageHeader(_ title: String) -> some View {
    HStack(spacing: 12) {
      Button {
        closeSubpage()
      } label: {
        HStack(spacing: 6) {
          Icon(glyph: .chevronLeft, size: 20)
          Text("Back")
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .modifier(ChatSettingsGlassStyle(isFocused: focus == .chatAdvancedBack, isSelected: false))
      }
      .buttonStyle(ChatSettingsPillButtonStyle())
      .focusEffectDisabled()
      .focused($focus, equals: .chatAdvancedBack)

      Text(title)
        .font(.headline)
        .foregroundStyle(.white)

      Spacer(minLength: 0)
    }
    .focusSection()
  }

  private func settingsStepperRow(_ field: ChatStepperField) -> some View {
    let config = chatStepperConfig(field)
    let canDecrement = config.value > config.range.lowerBound
    let canIncrement = config.value < config.range.upperBound

    return HStack(spacing: 12) {
      Text(config.title)
        .font(.subheadline)
        .foregroundStyle(.white)

      Spacer(minLength: 12)

      stepperButton(
        glyph: .minus,
        enabled: canDecrement,
        focusTag: .chatStepperDec(field)
      ) {
        adjustChatStepper(field, by: -1)
      }

      Text("\(Int(config.value.rounded()))")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(minWidth: 44)
        .monospacedDigit()

      stepperButton(
        glyph: .plus,
        enabled: canIncrement,
        focusTag: .chatStepperInc(field)
      ) {
        adjustChatStepper(field, by: 1)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 8)
    .background(Capsule(style: .continuous).fill(.white.opacity(0.06)))
    .focusSection()
  }

  private func stepperButton(
    glyph: Glyph,
    enabled: Bool,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    let isFocused = focus == focusTag

    return Button(action: action) {
      Icon(glyph: glyph, size: 22)
        .frame(width: 42, height: 34)
        .modifier(ChatSettingsGlassStyle(isFocused: isFocused, isSelected: false))
        .opacity(enabled ? 1.0 : 0.35)
    }
    .buttonStyle(ChatSettingsPillButtonStyle())
    .focusEffectDisabled()
    .focused($focus, equals: focusTag)
  }

  private func chatStepperConfig(
    _ field: ChatStepperField
  ) -> (title: String, range: ClosedRange<CGFloat>, step: CGFloat, value: CGFloat) {
    switch field {
    case .text:
      return ("Text Size", ChatAppearance.textSizeRange, ChatAppearance.textSizeStep, chatTextSize)
    case .emote:
      return ("Emote Size", ChatAppearance.emoteSizeRange, ChatAppearance.emoteSizeStep, CGFloat(chatEmoteSizeValue))
    case .lineHeight:
      return ("Line Height", ChatAppearance.lineHeightRange, ChatAppearance.lineHeightStep, chatLineHeight)
    case .messageSpacing:
      return ("Message Spacing", ChatAppearance.messageSpacingRange, ChatAppearance.messageSpacingStep, chatMessageSpacing)
    case .width:
      return ("Width", ChatAppearance.widthRange, ChatAppearance.widthStep, chatWidth)
    }
  }

  private func adjustChatStepper(_ field: ChatStepperField, by direction: CGFloat) {
    let config = chatStepperConfig(field)
    let next = ChatAppearance.snap(
      config.value + direction * config.step,
      to: config.range,
      step: config.step
    )
    switch field {
    case .text:
      chatTextSizeValue = Double(next)
    case .emote:
      chatEmoteAuto = false
      chatEmoteSizeValue = Double(next)
    case .lineHeight:
      chatLineHeightValue = Double(next)
    case .messageSpacing:
      chatMessageSpacingValue = Double(next)
    case .width:
      chatWidthValue = Double(next)
    }
  }

  private func applyChatPreset(_ preset: ChatAppearancePreset) {
    let values = preset.values
    chatTextSizeValue = Double(values.textSize)
    chatLineHeightValue = Double(values.lineHeight)
    chatMessageSpacingValue = Double(values.messageSpacing)
    chatEmoteAuto = true
  }

  private func resetChatAppearance() {
    applyChatPreset(.normal)
    chatEmoteSizeValue = Double(ChatAppearance.defaultEmoteSize)
    chatAnimatedEmotes = ChatAppearance.defaultAnimatedEmotes
  }

  private func openSubpage(_ page: ChatSettingsPage) {
    chatSettingsPage = page
    let target: Focusable = .chatAdvancedBack
    lastChatSettingsFocus = target
    Task { @MainActor in
      focus = target
    }
  }

  private func closeSubpage() {
    let returnFocus: Focusable = chatSettingsPage == .playback ? .chatMoreButton : .chatAdvancedButton
    chatSettingsPage = .main
    lastChatSettingsFocus = returnFocus
    Task { @MainActor in
      focus = returnFocus
    }
  }

  private func toggleChatSettings() {
    showChatSettings.toggle()
    if showChatSettings {
      let target = firstChatSettingsFocus
      lastChatSettingsFocus = target
      focus = target
    } else {
      chatSettingsPage = .main
      lastChatSettingsFocus = .chatSettingsButton
      focus = .chatSettingsButton
    }
  }

  private var hasChatDraft: Bool {
    !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var chatComposerBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let chatSendError {
        Text(chatSendError)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }

      if let deadline = chatSyncSendDeadline, chatSyncSendDelay > 0 {
        ChatSyncSendIndicator(deadline: deadline, total: chatSyncSendDelay)
      }

      if auth.isAuthenticated {
        HStack(spacing: 16) {
          Button {
            chatInputActivationToken &+= 1
          } label: {
            Text(chatDraft.isEmpty ? "Send a message" : chatDraft)
              .font(.subheadline)
              .foregroundStyle(focus == .chatInput
                ? .black.opacity(chatDraft.isEmpty ? 0.55 : 1.0)
                : .white.opacity(chatDraft.isEmpty ? 0.5 : 1.0))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 28)
              .frame(maxWidth: .infinity)
              .frame(height: chatComposerRowHeight)
              .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput))
              // The keyboard host sits *behind* the glass capsule as a full-size,
              // visually clear field. Keeping it out of the styled content (and at
              // full size) avoids a second nested background blob and stops tvOS
              // from resigning first responder on an undersized field.
              .background(
                ChatKeyboardHostField(
                  text: $chatDraft,
                  activationToken: chatInputActivationToken,
                  onSubmit: submitChatMessage
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
              )
          }
          .buttonStyle(ChatInputButtonStyle())
          .focusEffectDisabled()
          .focused($focus, equals: .chatInput)
          .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              revealControls(preferredFocus: .chatToggle)
            case .up:
              focus = .chatSettingsButton
            case .right:
              if hasChatDraft { focus = .chatSend }
            default:
              break
            }
          }

          if hasChatDraft {
            Button {
              submitChatMessage()
            } label: {
              if isSendingChat {
                ProgressView()
                  .frame(width: 24, height: 24)
              } else {
                Icon(glyph: .send, size: 24)
                  .frame(width: 24, height: 24)
              }
            }
            .TwizzControlButtonStyle()
            .frame(width: chatComposerRowHeight, height: chatComposerRowHeight)
            .disabled(isSendingChat)
            .focused($focus, equals: .chatSend)
            .transition(.opacity)
            .onMoveCommand { direction in
              switch direction {
              case .left:
                focus = .chatInput
              case .up:
                focus = .chatSettingsButton
              default:
                break
              }
            }
          }
        }
        .frame(height: chatComposerRowHeight)
        .animation(.easeOut(duration: 0.18), value: hasChatDraft)
      } else {
        Button {
          showSignInSheet = true
          scheduleHide()
        } label: {
          Text("Sign in to send messages")
            .font(.subheadline)
            .foregroundStyle(focus == .chatInput
              ? .black.opacity(0.7)
              : .white.opacity(0.45))
            .lineLimit(1)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: chatComposerRowHeight)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput))
            .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
        }
        .buttonStyle(ChatInputButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .chatInput)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            revealControls(preferredFocus: .chatToggle)
          case .up:
            focus = .chatSettingsButton
          default:
            break
          }
        }
        .frame(height: chatComposerRowHeight)
        .accessibilityLabel("Sign in to send messages")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      chatLayoutMode == .glass
        ? AnyShapeStyle(Color.black.opacity(0.22))
        : (chatLayoutMode == .overlay
            ? AnyShapeStyle(Color(white: 0.13).opacity(0.90))
            : AnyShapeStyle(Color(white: 0.07).opacity(0.96)))
    )
  }

  private func submitChatMessage() {
    let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isSendingChat else { return }
    // Dismiss the tvOS keyboard overlay before sending.
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    isSendingChat = true
    chatSendError = nil
    Task {
      do {
        try await auth.sendChatMessage(text, toChannel: activeChannel)
        chatDraft = ""
        beginChatSyncSendIndicatorIfNeeded()
      } catch {
        chatSendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      isSendingChat = false
    }
  }

  /// When stream-sync is holding chat, a sent message won't appear until it
  /// reaches the delayed video. Show a short progress countdown so the user
  /// knows it was sent and roughly when it will surface.
  private func beginChatSyncSendIndicatorIfNeeded() {
    guard chatSyncToStream, let delay = chatSyncDelaySeconds, delay >= 0.75 else {
      return
    }
    chatSyncSendClearTask?.cancel()
    chatSyncSendDelay = delay
    chatSyncSendDeadline = Date().addingTimeInterval(delay)
    chatSyncSendClearTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        chatSyncSendDeadline = nil
      }
    }
  }

  // MARK: - Raid banner

  /// A passive, non-interactive banner announcing an *incoming* raid (someone
  /// raiding the channel you're watching). It deliberately has no buttons and
  /// cannot take focus — you're already on the channel being raided, so there's
  /// nothing to follow.
  @ViewBuilder
  private func raidBanner(_ raid: RaidEvent) -> some View {
    VStack {
      Spacer()
      VStack(spacing: 4) {
        Text("\(raid.displayName) is raiding this channel")
          .font(.headline).bold()
          .foregroundStyle(.white)
        Text("\(raid.viewerCount) viewers incoming")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.85))
      }
      .multilineTextAlignment(.center)
      .padding(.horizontal, 32)
      .padding(.vertical, 18)
      .background(.purple.opacity(0.85), in: Capsule())
      .padding(.bottom, 60)
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
  }

  private func followRaid(_ login: String) {
    raidBannerDismissTask?.cancel()
    chat.pendingRaid = nil
    clearOutgoingRaidState()
    activeChannel = login
    stopPlaybackWatchdog()
    stopLatencyMonitor()
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentSourceURL = nil
    chat.disconnect()
    // Restart the outgoing-raid listener for the new channel so a stale
    // subscription from the previous channel never lingers.
    eventSub.stop()
    eventSub.start(forChannel: login, auth: auth)
    resetDiagnostics()
    isLoading = true
    errorMessage = nil
    isOffline = false
    streamTitle = ""
    channelDisplayName = ""
    channelAvatarURL = nil
    chat.connect(to: login)
    Task {
      async let metadataTask: Void = refreshChannelMetadata()
      await load(reason: "raid follow", resetMetadata: false)
      _ = await metadataTask
      focus = .video
    }
  }

  // MARK: - Outgoing raid (auto-follow)

  /// Banner shown when the watched channel is raiding away. Defaults to
  /// following after a short countdown; the focusable Cancel button opts out.
  @ViewBuilder
  private func outgoingRaidBanner(_ raid: OutgoingRaidEvent) -> some View {
    VStack {
      Spacer()
      HStack(spacing: 20) {
        Icon(glyph: .userPlus, size: 34)
          .foregroundStyle(.white)
        VStack(alignment: .leading, spacing: 4) {
          Text("Raiding to \(raid.toDisplayName)")
            .font(.headline).bold()
            .foregroundStyle(.white)
          Text("Auto-following in \(outgoingRaidSecondsRemaining)s · Cancel to stay here")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
        }
        Button("Cancel") {
          cancelOutgoingRaid()
        }
        .focused($focus, equals: .raidFollowCancel)
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 20)
      .background(Color(red: 0.40, green: 0.25, blue: 0.78).opacity(0.95), in: Capsule())
      .padding(.bottom, 60)
    }
    .ignoresSafeArea()
  }

  /// Start the cancelable countdown that ends in following the raid target.
  private func beginOutgoingRaidFollow(_ raid: OutgoingRaidEvent) {
    // Don't redirect onto the channel we're already watching.
    guard raid.toLogin.lowercased() != activeChannel.lowercased() else {
      eventSub.pendingOutgoingRaid = nil
      return
    }

    outgoingRaidFollowTask?.cancel()
    withAnimation {
      outgoingRaid = raid
      outgoingRaidSecondsRemaining = 6
    }
    focus = .raidFollowCancel

    let target = raid.toLogin
    outgoingRaidFollowTask = Task {
      while outgoingRaidSecondsRemaining > 0 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        outgoingRaidSecondsRemaining -= 1
      }
      guard !Task.isCancelled else { return }
      // followRaid clears outgoing state and restarts the listener.
      followRaid(target)
    }
  }

  private func cancelOutgoingRaid() {
    clearOutgoingRaidState()
    focus = .video
  }

  /// Debug-only: inject a simulated outgoing raid so the auto-follow flow can be
  /// tested without waiting for a real raid. Targets AlveusSanctuary.
  private func simulateOutgoingRaid() {
    showChatSettings = false
    eventSub.pendingOutgoingRaid = OutgoingRaidEvent(
      toLogin: "alveussanctuary",
      toDisplayName: "AlveusSanctuary",
      toBroadcasterID: "",
      viewerCount: 0
    )
  }

  private func clearOutgoingRaidState() {
    outgoingRaidFollowTask?.cancel()
    outgoingRaidFollowTask = nil
    eventSub.pendingOutgoingRaid = nil
    withAnimation { outgoingRaid = nil }
    outgoingRaidSecondsRemaining = 0
  }

  // MARK: - Quality picker

  private var qualityOptions: [String] {
    ["Auto"] + (playback?.qualities.map(\.name) ?? [])
  }

  /// Text shown on the player's quality button: the selected variant (e.g.
  /// "1080p60"), or "Auto (1080p60)" reflecting the live adaptive resolution.
  private var qualityButtonLabel: String {
    if preferredQuality == "Auto" {
      if let resolvedQualityName {
        return "Auto (\(resolvedQualityName))"
      }
      return "Auto"
    }
    return Self.shortQualityName(preferredQuality)
  }

  /// Every label the quality button could ever display for the current stream.
  /// The button reserves the width of the widest of these so the in-player
  /// title's available space stays constant as the live label changes (e.g.
  /// "Auto" -> "Auto (1080p60)"), preventing distracting title font reflow.
  private var qualityButtonLabelCandidates: [String] {
    var labels: Set<String> = ["Auto"]
    let videoVariants = (playback?.qualities ?? []).filter { !$0.isAudioOnly }
    for quality in videoVariants {
      let short = Self.shortQualityName(quality.name)
      labels.insert(short)
      labels.insert("Auto (\(short))")
    }
    return Array(labels)
  }

  /// Drops the "(Source)" suffix so the button reads "1080p60", not
  /// "1080p60 (Source)".
  private static func shortQualityName(_ name: String) -> String {
    name.replacingOccurrences(of: " (Source)", with: "")
      .replacingOccurrences(of: " (source)", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// Parses the vertical resolution from a variant name, e.g. "1080p60" -> 1080.
  private static func verticalResolution(from name: String) -> Int? {
    let lower = name.lowercased()
    guard let pIndex = lower.firstIndex(of: "p") else { return nil }
    let digits = lower[lower.startIndex..<pIndex].filter(\.isNumber)
    return Int(digits)
  }

  /// Maps AVPlayer's current presentation size to the closest known variant
  /// name while on the adaptive ("Auto") master playlist.
  private func updateResolvedQuality() {
    guard preferredQuality == "Auto" else {
      resolvedQualityName = nil
      return
    }
    guard let playback else { return }

    let videoVariants = playback.qualities.filter { !$0.isAudioOnly }
    // Named variants that advertise a parseable resolution, e.g. "720p60".
    let namedCandidates: [(Int, String)] = videoVariants.compactMap { quality in
      guard let resolution = Self.verticalResolution(from: quality.name) else { return nil }
      return (resolution, Self.shortQualityName(quality.name))
    }

    // Preferred path: match the live adaptive resolution to the nearest named
    // variant so we keep its exact label (including frame rate).
    if let size = player.currentItem?.presentationSize, size.height > 0 {
      let height = Int(size.height.rounded())
      if let best = namedCandidates.min(by: { abs($0.0 - height) < abs($1.0 - height) }) {
        resolvedQualityName = best.1
        return
      }
      // Variants don't expose a parseable resolution (e.g. transcoding
      // disabled, source named "chunked"): derive the label from the decoded
      // frame height directly so it still shows something accurate.
      resolvedQualityName = "\(height)p"
      return
    }

    // Presentation size not yet known. If the stream offers a single video
    // rendition, Auto is effectively that rendition — show it rather than
    // leaving the label stuck on a bare "Auto".
    if videoVariants.count == 1 {
      resolvedQualityName = Self.shortQualityName(videoVariants[0].name)
    }
  }

  /// Display label for a quality option. "Auto" is the adaptive-bitrate choice;
  /// when the low-latency proxy is on it's also the low-latency choice (and,
  /// because ABR can step down instead of stalling, the smoothest one), so we
  /// surface that in the picker. The stored/compared value stays plain "Auto".
  private func qualityDisplayLabel(_ option: String) -> String {
    guard option == "Auto" else { return option }
    return lowLatencyProxyEnabled ? "Auto (Low Latency)" : "Auto"
  }

  private func selectQuality(at index: Int) {
    guard qualityOptions.indices.contains(index) else { return }
    let option = qualityOptions[index]
    preferredQuality = option
    applyQualityPreference(option)
    updateResolvedQuality()
    focus = .quality
    scheduleHide()
  }

  /// The effective YouTube merge target shown in the settings input: the manual
  /// entry when present, otherwise the resolved default handle for the channel.
  private var youtubeMergeDisplayText: String {
    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    return youtubeMergeDefaultTarget.isEmpty ? "YouTube handle or channel URL" : youtubeMergeDefaultTarget
  }

  /// The handle the merge falls back to when no manual value is entered.
  private var youtubeMergeDefaultTarget: String {
    let base = activeChannel.isEmpty ? channel : activeChannel
    return base.isEmpty ? "" : "@\(base)"
  }

  private func applyExperimentalYouTubeSettings() {
    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let defaultTarget = channel
    let resolvedTarget = manual.isEmpty ? defaultTarget : manual

    chat.configureExperimentalYouTubeMerge(
      enabled: experimentalYouTubeMergeEnabled,
      channelOrURL: resolvedTarget
    )
  }

  /// The delay to hold chat by so it lines up with the on-screen video.
  ///
  /// This must be the *broadcast* (glass-to-glass) latency, i.e. how far behind
  /// real time the picture is — which is exactly what the wall-clock estimate
  /// (`now − EXT-X-PROGRAM-DATE-TIME`) measures. The live-edge value is only the
  /// small in-buffer gap to the playlist edge (a few seconds) and would leave
  /// chat running far ahead, so it's not used for syncing.
  private var chatSyncDelaySeconds: Double? {
    wallClockLatencySeconds
  }

  /// Push the current sync preference + measured latency into the chat service.
  /// Called when the toggle changes and on each latency sample.
  private func applyChatSyncSettings() {
    chat.configureChatSync(
      enabled: chatSyncToStream,
      delaySeconds: chatSyncDelaySeconds ?? 0
    )
  }

  /// Human-readable explanation shown under the Stream Sync toggle.
  private var chatSyncStatusDescription: String {
    guard chatSyncToStream else {
      return "Chat shows in real time, so it runs ahead of the delayed video."
    }
    if let seconds = chatSyncDelaySeconds, seconds >= 0.75 {
      return "Holding chat ~\(formatLatencySeconds(seconds)) to match the video."
    }
    return "Measuring stream delay… chat will sync once latency is known."
  }

  // MARK: - Loading

  private enum LoadTimeoutError: LocalizedError {
    case timedOut
    case noPlaybackProgress

    var errorDescription: String? {
      switch self {
      case .timedOut:
        return "Timed out while loading this stream."
      case .noPlaybackProgress:
        return "Stream did not start playback in time."
      }
    }
  }

  private func load(maxAttempts: Int = 3, reason: String = "initial", resetMetadata: Bool = true)
    async
  {
    isLoading = true
    errorMessage = nil
    isOffline = false
    if resetMetadata {
      streamTitle = ""
    }
    player.appliesMediaSelectionCriteriaAutomatically = true

    var lastError: Error?
    for attempt in 1...maxAttempts {
      do {
        let resolved = try await resolvePlaybackWithTimeout()
        playback = resolved
        player.replaceCurrentItem(with: makeItem(url: resolved.master))
        applyQualityPreference(preferredQuality)
        startPlayback()

        let started = await waitForPlaybackStart()
        if !started {
          throw LoadTimeoutError.noPlaybackProgress
        }

        startLatencyMonitor()
        startPlaybackWatchdog()
        consecutiveLoadFailures = 0
        isLoading = false
        return
      } catch {
        lastError = error
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentSourceURL = nil
        if attempt < maxAttempts {
          try? await Task.sleep(for: .seconds(Double(attempt)))
        }
      }
    }

    consecutiveLoadFailures += 1
    stopPlaybackWatchdog()
    stopLatencyMonitor()

    // Before surfacing a hard error, decide whether this is simply an offline /
    // ended stream. A definitive `.offline` resolve error is already a strong
    // signal; otherwise confirm authoritatively via GraphQL so we never show the
    // offline state for a transient failure on a channel that's actually live.
    let resolvedOffline = (lastError as? PlaybackError) == .offline
    if resolvedOffline || lastError == nil || lastError is LoadTimeoutError {
      let status = await PlaybackService.streamLiveStatus(for: activeChannel)
      if status == .offline || (resolvedOffline && status != .live) {
        presentOfflineState()
        return
      }
    }

    let fallback = "Failed to load stream (\(reason))."
    errorMessage = lastError?.localizedDescription ?? fallback
    isLoading = false
  }

  private func resolvePlaybackWithTimeout() async throws -> StreamPlayback {
    try await withThrowingTaskGroup(of: StreamPlayback.self) { group in
      group.addTask {
        try await PlaybackService.resolve(for: activeChannel)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(resolveTimeoutSeconds))
        throw LoadTimeoutError.timedOut
      }

      guard let first = try await group.next() else {
        throw LoadTimeoutError.timedOut
      }
      group.cancelAll()
      return first
    }
  }

  private func waitForPlaybackStart() async -> Bool {
    let deadline = Date().addingTimeInterval(startupPlaybackTimeoutSeconds)

    while Date() < deadline {
      if Task.isCancelled {
        return false
      }

      if let item = player.currentItem {
        if item.status == .failed {
          return false
        }

        let currentSeconds = CMTimeGetSeconds(item.currentTime())
        if player.timeControlStatus == .playing {
          return true
        }
        if currentSeconds.isFinite, currentSeconds > 0.2 {
          return true
        }
      }

      try? await Task.sleep(nanoseconds: startupPlaybackPollMilliseconds * 1_000_000)
    }

    return false
  }

  /// "Auto" plays the adaptive master playlist (ABR picks the rendition). Any
  /// explicit pick hard-pins that single rendition's media playlist instead, so
  /// ABR can't silently downshift to a blurrier variant. Note: on the master,
  /// `preferredPeakBitRate` is only a *ceiling* — ABR is still free to serve
  /// lower, which is exactly why selecting "1080p60" used to still look soft.
  /// In-band CEA-608 captions ride inside each rendition, so they survive the
  /// pin. The trade-off: a pinned rendition has no ABR fallback, so a stream
  /// whose bitrate exceeds the connection will rebuffer rather than drop down —
  /// "Auto" remains the safe choice for that case.
  private func applyQualityPreference(_ option: String) {
    guard let playback else { return }

    if option == "Auto" {
      switchToSourceIfNeeded(playback.master)
      player.currentItem?.preferredPeakBitRate = 0
      return
    }

    guard let match = playback.qualities.first(where: { $0.name == option }) else {
      switchToSourceIfNeeded(playback.master)
      player.currentItem?.preferredPeakBitRate = 0
      return
    }

    switchToSourceIfNeeded(match.url)
    player.currentItem?.preferredPeakBitRate = 0
  }

  /// Replaces the current item only when the underlying source actually changes,
  /// comparing against the real (pre-proxy) source URL.
  private func switchToSourceIfNeeded(_ url: URL) {
    guard currentSourceURL != url else { return }
    player.replaceCurrentItem(with: makeItem(url: url))
    startPlayback()
  }

  private func makeItem(url: URL) -> AVPlayerItem {
    currentSourceURL = url
    let assetURL: URL
    if lowLatencyProxyEnabled {
      assetURL = lowLatencyProxy.proxyURL(for: url)
    } else {
      assetURL = url
    }
    let asset = AVURLAsset(
      url: assetURL,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    if lowLatencyProxyEnabled {
      // Promotes Twitch's #EXT-X-TWITCH-PREFETCH segments (which AVPlayer would
      // otherwise ignore) into real segments, pulling playback closer to live.
      asset.resourceLoader.setDelegate(lowLatencyProxy, queue: lowLatencyProxy.callbackQueue)
    }
    let item = AVPlayerItem(asset: asset)
    // A deeper forward buffer in low-latency mode does double duty: it gives
    // ABR enough headroom to actually climb to the selected quality (fixes soft
    // 1080p) and it keeps AVPlayer from skipping forward to live when the buffer
    // runs thin (fixes the "jumps ahead"). The proxy keeps the *content* near
    // live regardless, so the only cost is a few seconds of latency — which the
    // user has ranked below freeze-free, smooth, sharp playback.
    item.preferredForwardBufferDuration = lowLatencyProxyEnabled ? 5 : 1
    return item
  }

  /// "Behind live" as the user experiences it: how far the playhead trails the
  /// freshest segment we can actually fetch (the seekable-edge gap, ~2-6s).
  ///
  /// We deliberately do NOT lead with the PROGRAM-DATE-TIME wall-clock delay.
  /// That measures distance from Twitch's *encoder* timestamp, which for a
  /// standard-latency stream is ~18-20s — and every other client (including the
  /// Twitch phone app) sits that far back too. So it reads "20s behind live"
  /// while you're visually in sync with your phone, which is just confusing.
  /// The edge gap is the number that tracks "am I near the freshest content."
  /// Wall-clock is kept only as a fallback when the edge gap is unavailable.
  private var rawLatencySeconds: Double? {
    liveEdgeLatencySeconds ?? wallClockLatencySeconds
  }

  /// Smoothed value actually shown in the UI, to stop the number jumping around.
  private var measuredLatencySeconds: Double? {
    smoothedLatencySeconds ?? rawLatencySeconds
  }

  /// True while playback is active but the latency reading hasn't settled yet.
  /// The live-edge gap reads ~0 right after playback starts and then climbs to
  /// the real value, so we wait for the number to stabilise (and clear a
  /// plausible floor) before trusting it, with a hard sample cap as a backstop.
  private var isLatencyWarmingUp: Bool {
    guard isPlaybackActive else { return false }
    guard let seconds = measuredLatencySeconds else { return true }
    if latencySampleCount >= latencyWarmUpMaxSamples { return false }
    if latencySampleCount < latencyWarmUpMinSamples { return true }
    if seconds < latencyPlausibleFloorSeconds { return true }
    return latencyStableCount < latencyStableSamplesRequired
  }

  private var latencyColor: Color {
    guard let seconds = measuredLatencySeconds, !isLatencyWarmingUp else { return .gray }
    if seconds <= 8 { return .green }
    if seconds <= 15 { return .yellow }
    return .orange
  }

  private var latencyLabel: String {
    guard isPlaybackActive else {
      return "Waiting for playback"
    }
    guard let seconds = measuredLatencySeconds else {
      return "Latency unavailable"
    }
    if isLatencyWarmingUp {
      return "Estimating latency…"
    }
    return "~\(formatLatencySeconds(seconds)) behind live"
  }

  private func formatLatencySeconds(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    if clamped < 10 {
      let tenths = (clamped * 10).rounded() / 10
      return "\(tenths)s"
    }
    return "\(Int(clamped.rounded()))s"
  }

  private func configurePlayerForLive() {
    // Always minimize stalling. Disabling this starves the buffer and caused
    // hard freezes on-device; the latency win comes from the proxy instead.
    player.automaticallyWaitsToMinimizeStalling = true
  }

  private func startPlayback() {
    didRequestPlayback = true
    player.playImmediately(atRate: 1.0)
  }

  private func startLatencyMonitor() {
    stopLatencyMonitor()
    latencyTask = Task {
      while !Task.isCancelled {
        await MainActor.run {
          updateLatencyMetrics()
          updateResolvedQuality()
          updateSmoothedLatency()
          sampleDiagnostics()
          applyChatSyncSettings()
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func stopLatencyMonitor() {
    latencyTask?.cancel()
    latencyTask = nil
    wallClockLatencySeconds = nil
    liveEdgeLatencySeconds = nil
    smoothedLatencySeconds = nil
    latencySampleCount = 0
    latencyStableCount = 0
    isPlaybackActive = false
    didRequestPlayback = false
    edgeLatencyLowConfidenceStreak = 0
    wallClockHighLatencyStreak = 0
    wallClockLowConfidenceStreak = 0
    lastPlaybackDateSample = nil
    lastPlaybackTimeSampleSeconds = nil
    diagIsFrozen = false
    diagFrozenSince = nil
  }

  private func startPlaybackWatchdog() {
    stopPlaybackWatchdog()
    playbackWatchdogTask = Task {
      while !Task.isCancelled {
        await MainActor.run {
          samplePlaybackHealth()
        }
        try? await Task.sleep(for: .seconds(playbackWatchdogIntervalSeconds))
      }
    }
  }

  private func stopPlaybackWatchdog() {
    playbackWatchdogTask?.cancel()
    playbackWatchdogTask = nil
    lastObservedPlaybackTimeSeconds = nil
    stalledPlaybackSamples = 0
    isRecoveringPlayback = false
  }

  private func samplePlaybackHealth() {
    guard !isLoading, errorMessage == nil, !isOffline
    else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      return
    }
    guard let item = player.currentItem else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      return
    }

    if item.status == .failed {
      if !isRecoveringPlayback {
        Task { await recoverFromPlaybackStall(reason: "item failed") }
      }
      return
    }

    guard didRequestPlayback else {
      stalledPlaybackSamples = 0
      return
    }

    let currentSeconds = CMTimeGetSeconds(item.currentTime())
    guard currentSeconds.isFinite else { return }

    if let last = lastObservedPlaybackTimeSeconds {
      let advanced = currentSeconds - last
      let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      let stalled = advanced < 0.05 && (waiting || isPlaybackActive)

      if stalled {
        stalledPlaybackSamples += 1
        markDiagnosticsStall(reason: "watchdog")
      } else {
        stalledPlaybackSamples = 0
        diagWasStalled = false
        diagIsFrozen = false
        diagFrozenSince = nil
      }
    }

    lastObservedPlaybackTimeSeconds = currentSeconds

    if stalledPlaybackSamples >= stalledPlaybackThresholdSamples, !isRecoveringPlayback {
      stalledPlaybackSamples = 0
      Task { await recoverFromPlaybackStall(reason: "watchdog stall") }
    }
  }

  private func recoverFromPlaybackStall(reason: String) async {
    guard !isRecoveringPlayback else { return }
    guard !isOffline else { return }
    isRecoveringPlayback = true
    defer { isRecoveringPlayback = false }

    // Before blindly reloading (which can loop forever on a frozen last frame
    // once a broadcast ends), authoritatively check whether the channel is still
    // live. Only act on a definitive `.offline`; `.live`/`.unknown` fall through
    // to the normal reload-based recovery for genuine transient stalls.
    if await PlaybackService.streamLiveStatus(for: activeChannel) == .offline {
      presentOfflineState()
      return
    }

    diagReloadCount += 1
    if showLatencyDiagnostics { logDiagnosticsEvent("reload (\(reason))") }
    // A reload restarts the timeline, so clear the jump baseline to avoid
    // counting the discontinuity as a playhead jump.
    diagLastPlayheadSeconds = nil
    diagLastSampleAt = nil
    await load(maxAttempts: 2, reason: reason, resetMetadata: false)
  }

  // MARK: - Offline empty state

  /// Switches the player into the clean "offline / stream ended" empty state.
  /// Tears down the live machinery and drops the current item so the frozen last
  /// frame is replaced by the empty-state backdrop.
  private func presentOfflineState() {
    stopPlaybackWatchdog()
    stopLatencyMonitor()
    audioLevelMonitor.stop()
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentSourceURL = nil
    isRecoveringPlayback = false
    hideTask?.cancel()
    showControls = false
    showChatSettings = false
    isLoading = false
    errorMessage = nil
    isOffline = true
    focus = .offlineViewChannel
  }

  /// Re-attempts playback from the offline empty state (e.g. the streamer just
  /// came back). `load()` clears `isOffline` and re-confirms offline on failure.
  private func retryFromOffline() {
    guard !isLoading else { return }
    isOffline = false
    Task {
      async let metadataTask: Void = refreshChannelMetadata()
      await load(reason: "offline retry", resetMetadata: false)
      _ = await metadataTask
      if !isOffline, errorMessage == nil {
        focus = .video
      }
    }
  }

  /// Exponential moving average of the raw latency estimate so the on-screen
  /// number is stable instead of flickering between samples. Snaps directly on
  /// large jumps (e.g. after a re-snap) rather than crawling toward the new value.
  private func updateSmoothedLatency() {
    guard isPlaybackActive, let raw = rawLatencySeconds else {
      smoothedLatencySeconds = nil
      latencySampleCount = 0
      latencyStableCount = 0
      return
    }
    guard let prev = smoothedLatencySeconds else {
      smoothedLatencySeconds = raw
      latencySampleCount = 1
      latencyStableCount = 0
      return
    }
    let next: Double
    if abs(raw - prev) >= 3 {
      next = raw
    } else {
      next = prev * 0.6 + raw * 0.4
    }
    smoothedLatencySeconds = next
    latencySampleCount += 1
    if abs(next - prev) <= latencyStableDeltaSeconds {
      latencyStableCount += 1
    } else {
      latencyStableCount = 0
    }
  }

  private func updateLatencyMetrics() {
    guard let item = player.currentItem else {
      wallClockLatencySeconds = nil
      liveEdgeLatencySeconds = nil
      isPlaybackActive = false
      wallClockLowConfidenceStreak = 0
      lastPlaybackDateSample = nil
      lastPlaybackTimeSampleSeconds = nil
      return
    }

    let status = player.timeControlStatus
    let hasSeekableRange = item.seekableTimeRanges.last?.timeRangeValue != nil
    let currentSeconds = CMTimeGetSeconds(item.currentTime())
    let hasAdvancedTime = currentSeconds.isFinite && currentSeconds > 0

    // Treat waiting/buffering as active once playback has been requested.
    isPlaybackActive =
      status == .playing
      || (didRequestPlayback && status == .waitingToPlayAtSpecifiedRate)
      || hasSeekableRange
      || hasAdvancedTime

    if !isPlaybackActive {
      wallClockLatencySeconds = nil
      liveEdgeLatencySeconds = nil
    }

    if let playbackDate = item.currentDate() {
      let wallClock = Date().timeIntervalSince(playbackDate)
      let playbackSeconds = CMTimeGetSeconds(item.currentTime())

      if let lastDate = lastPlaybackDateSample,
        let lastPlaybackSeconds = lastPlaybackTimeSampleSeconds,
        playbackSeconds.isFinite,
        lastPlaybackSeconds.isFinite
      {
        let playbackAdvance = playbackSeconds - lastPlaybackSeconds
        let dateAdvance = playbackDate.timeIntervalSince(lastDate)

        if playbackAdvance >= wallClockStalePlaybackAdvanceThresholdSeconds,
          abs(dateAdvance) <= wallClockStaleDateDeltaEpsilonSeconds
        {
          wallClockLowConfidenceStreak += 1
        } else if wallClockLowConfidenceStreak > 0 {
          wallClockLowConfidenceStreak -= 1
        }
      }

      lastPlaybackDateSample = playbackDate
      if playbackSeconds.isFinite {
        lastPlaybackTimeSampleSeconds = playbackSeconds
      }

      let hasValidWallClock = wallClock.isFinite && wallClock >= 0
      let hasReliableWallClock =
        hasValidWallClock
        && wallClockLowConfidenceStreak < wallClockUnavailableSamples

      if hasReliableWallClock {
        wallClockLatencySeconds = wallClock
      } else if !hasValidWallClock {
        wallClockLatencySeconds = nil
      } else {
        // Wall-clock telemetry appears stale. Keep the last reliable
        // value instead of counting up forever.
      }
    } else {
      wallClockLatencySeconds = nil
      wallClockLowConfidenceStreak = 0
      lastPlaybackDateSample = nil
      lastPlaybackTimeSampleSeconds = nil
    }

    if let range = item.seekableTimeRanges.last?.timeRangeValue {
      let liveEdge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
      let current = CMTimeGetSeconds(item.currentTime())
      if liveEdge.isFinite, current.isFinite, liveEdge > 0 {
        let liveEdgeLatencyRaw = max(0, liveEdge - current)
        if liveEdgeLatencyRaw <= edgeLatencyUnavailableEpsilonSeconds {
          edgeLatencyLowConfidenceStreak += 1
        } else {
          edgeLatencyLowConfidenceStreak = 0
        }

        let liveEdgeLatency: Double? =
          edgeLatencyLowConfidenceStreak >= edgeLatencyUnavailableSamples
          ? nil
          : liveEdgeLatencyRaw
        liveEdgeLatencySeconds = liveEdgeLatency
        applyLiveLatencyCorrection(
          item: item,
          range: range,
          wallClockLatency: wallClockLatencySeconds,
          liveEdgeLatency: liveEdgeLatency
        )
      } else {
        liveEdgeLatencySeconds = nil
        edgeLatencyLowConfidenceStreak = 0
      }
    } else {
      liveEdgeLatencySeconds = nil
      edgeLatencyLowConfidenceStreak = 0
      applyLiveLatencyCorrection(
        item: item,
        range: nil,
        wallClockLatency: wallClockLatencySeconds,
        liveEdgeLatency: nil
      )
    }
  }

  /// Keeps playback close to the live edge without constant hard seeks.
  private func applyLiveLatencyCorrection(
    item: AVPlayerItem,
    range: CMTimeRange?,
    wallClockLatency: Double?,
    liveEdgeLatency: Double?
  ) {
    guard isPlaybackActive else { return }
    let now = Date()

    if let liveEdgeLatency {
      // Ignore tiny/unstable values to avoid oscillation.
      guard liveEdgeLatency >= 0.8 else {
        if abs(player.rate - 1.0) > 0.01 {
          player.playImmediately(atRate: 1.0)
        }
        return
      }

      if liveEdgeLatency >= hardCatchUpThresholdSeconds {
        guard now.timeIntervalSince(lastHardCatchUpJumpAt) >= hardCatchUpCooldownSeconds else {
          return
        }

        guard let range else { return }

        let edge = CMTimeRangeGetEnd(range)
        let edgeSeconds = CMTimeGetSeconds(edge)
        let floorSeconds = CMTimeGetSeconds(range.start)
        let targetSeconds = max(floorSeconds, edgeSeconds - targetLiveEdgeSeconds)

        guard targetSeconds.isFinite else { return }
        let targetTime = CMTime(
          seconds: targetSeconds, preferredTimescale: edge.timescale == 0 ? 600 : edge.timescale)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: 1.0)
        lastHardCatchUpJumpAt = now
        wallClockHighLatencyStreak = 0
        return
      }

      if liveEdgeLatency > softCatchUpThresholdSeconds {
        // Mild speed-up only; prioritize smooth playback over aggressive chasing.
        let overshoot = liveEdgeLatency - softCatchUpThresholdSeconds
        let targetRate = min(maxCatchUpRate, 1.01 + Float(overshoot / 60.0))
        if abs(player.rate - targetRate) > 0.01 {
          player.playImmediately(atRate: targetRate)
        }
        wallClockHighLatencyStreak = 0
        return
      }

      wallClockHighLatencyStreak = 0
      if liveEdgeLatency <= targetLiveEdgeSeconds + 0.8, abs(player.rate - 1.0) > 0.01 {
        player.playImmediately(atRate: 1.0)
      }
      return
    }

    // Fallback for channels where seekable-range edge latency is unreliable.
    wallClockHighLatencyStreak = 0
    if abs(player.rate - 1.0) > 0.01 {
      player.playImmediately(atRate: 1.0)
    }
  }

  private func refreshChannelMetadata() async {
    guard let metadata = await PlaybackService.channelMetadata(for: activeChannel) else {
      channelDisplayName = activeChannel
      channelAvatarURL = nil
      return
    }
    channelDisplayName = metadata.displayName
    channelAvatarURL = metadata.profileImageURL
    streamTitle = metadata.title
  }

  private func setIdleTimer(disabled: Bool) {
    UIApplication.shared.isIdleTimerDisabled = disabled
  }
}

extension View {
  @ViewBuilder
  fileprivate func TwizzControlButtonStyle() -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.automatic)
    }
  }
}

private struct ChatSettingsPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.92 : 1.0)
  }
}

/// Reports the natural height of the chat-settings content so the floating panel
/// can size itself to fit (and animate) rather than always filling the pane.
private struct ChatSettingsHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// The focus/selection treatment for the compact chat-settings controls. Modeled
/// on `ChatGlassFieldStyle` (the chat input): one view subtree whose parameters
/// change with `isFocused`/`isSelected`, so it lifts as a single Liquid Glass
/// element — brightening (white-tinted glass), scaling slightly, and casting a
/// soft shadow on focus — instead of swapping in an opaque card or using manual
/// opacity stacks. Tuned more compact than the chat input to keep the efficient
/// pill sizing. Falls back to `.ultraThinMaterial` before tvOS 26.
private struct ChatSettingsGlassStyle: ViewModifier {
  let isFocused: Bool
  var isSelected: Bool = false

  // A Capsule keeps these controls fully rounded so they match the chat input
  // and the rest of the app's Liquid Glass controls.
  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  private var strokeOpacity: Double {
    if isFocused { return 0.0 }
    return isSelected ? 0.42 : 0.16
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    let tinted = content
      .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
    if #available(tvOS 26.0, *) {
      tinted
        // Same native Liquid Glass treatment as the chat input: real glass at
        // rest (lightly white-tinted when selected so the active pill reads),
        // a bright white glass + black text on focus, scaling and shadowing as
        // one element. No opaque dark base — these match the "Glass" chat look.
        .glassEffect(
          isFocused
            ? .regular.tint(.white)
            : (isSelected ? .regular.tint(.white.opacity(0.22)) : .regular),
          in: shape
        )
        .overlay(shape.strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.25 : 0.0),
                radius: isFocused ? 10 : 0, x: 0, y: isFocused ? 4 : 0)
    } else {
      tinted
        .background(shape.fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial)))
        .background(
          shape.fill(.white.opacity(
            isFocused ? 0.0 : (isSelected ? 0.18 : 0.08)
          ))
        )
        .overlay(shape.strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.25 : 0.0),
                radius: isFocused ? 10 : 0, x: 0, y: isFocused ? 4 : 0)
    }
  }
}

/// A completely passthrough button style for the chat input surface.
/// Suppresses all platform button visuals (hover, scale, ring) so only
/// the SwiftUI glass shell controls the appearance.
private struct ChatInputButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Gives the chat composer field a single Liquid Glass capsule that is the *same*
/// element at rest and when focused — it simply brightens (white-tinted glass) and
/// lifts slightly on focus, the way native tvOS controls do, instead of swapping in
/// a separate opaque card on top. Keeping one view subtree (only the parameters
/// change with `isFocused`) preserves view identity so SwiftUI animates it as one
/// element growing. Falls back to `.ultraThinMaterial` on systems older than tvOS 26.
private struct ChatGlassFieldStyle: ViewModifier {
  let isFocused: Bool

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .glassEffect(isFocused ? .regular.tint(.white) : .regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.22 : 0.18),
                radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    } else {
      content
        .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.22 : 0.18),
                radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    }
  }
}

/// The native quality picker, extracted into its own `Equatable` view so the
/// player's once-per-second latency/diagnostics state churn doesn't re-render
/// (and visibly re-focus / "blink") the open `Menu`. SwiftUI only re-evaluates
/// this view when one of the value inputs compared in `==` actually changes.
private struct QualityMenu: View, Equatable {
  let options: [String]
  let selectedOption: String
  let buttonLabel: String
  let reservedWidthLabels: [String]
  let displayLabel: (String) -> String
  let onSelect: (Int) -> Void
  let onMenuPresented: () -> Void
  let onMenuDismissed: () -> Void

  nonisolated static func == (lhs: QualityMenu, rhs: QualityMenu) -> Bool {
    lhs.options == rhs.options
      && lhs.selectedOption == rhs.selectedOption
      && lhs.buttonLabel == rhs.buttonLabel
      && lhs.reservedWidthLabels == rhs.reservedWidthLabels
  }

  /// Drives the inline `Picker` selection. Reading derives the current index
  /// from `selectedOption`; writing routes through `onSelect` so the player
  /// applies the quality change and its side effects.
  private var selection: Binding<Int> {
    Binding(
      get: { options.firstIndex(of: selectedOption) ?? 0 },
      set: { onSelect($0) }
    )
  }

  var body: some View {
    // Invisible barrier: hidden copies of every possible label reserve the
    // width of the widest one, so the in-player title's available space stays
    // constant. The barrier draws nothing and isn't focusable — only the Menu
    // is interactive, and its platter hugs the live label, so the visible
    // button stays variable-width. Trailing alignment parks the button against
    // the next control, letting the reserved slack sit (invisibly) on its left.
    ZStack(alignment: .trailing) {
      ForEach(reservedWidthLabels, id: \.self) { candidate in
        qualityLabelText(candidate).hidden()
      }

      Menu {
        // A `Picker` is Apple's recommended single-selection control inside a
        // menu: it renders a checkmark in a reserved leading gutter so every
        // row's text stays aligned (no per-row shift), unlike hand-placed
        // checkmark labels.
        Picker("Quality", selection: selection) {
          ForEach(Array(options.enumerated()), id: \.element) { index, option in
            Text(displayLabel(option)).tag(index)
          }
        }
        .pickerStyle(.inline)
        .onAppear(perform: onMenuPresented)
        .onDisappear(perform: onMenuDismissed)
      } label: {
        qualityLabelText(buttonLabel)
          .accessibilityLabel("Quality, \(buttonLabel)")
      }
    }
  }

  /// `true` for the live "Auto (1080p60)" form, which we render slightly
  /// smaller so the parenthetical resolution reads as a secondary detail.
  private func isAutoResolutionLabel(_ text: String) -> Bool {
    text.hasPrefix("Auto (")
  }

  @ViewBuilder
  private func qualityLabelText(_ text: String) -> some View {
    Group {
      if isAutoResolutionLabel(text) {
        Text(text)
          .font(.system(size: Self.compactQualityFontSize, weight: .semibold))
      } else {
        Text(text)
          .font(.subheadline)
          .fontWeight(.semibold)
      }
    }
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
  }

  /// 20% smaller than `.subheadline`, used for the "Auto (1080p60)" label.
  private static var compactQualityFontSize: CGFloat {
    UIFont.preferredFont(forTextStyle: .subheadline).pointSize * 0.8
  }
}

/// A `UITextField` subclass that refuses focus-engine focus on tvOS. The chat
/// composer's SwiftUI `Button` owns focus and draws the visible capsule; this
/// field exists only to host the keyboard via `becomeFirstResponder()`. Without
/// this, the tvOS focus engine focuses the embedded field too and paints its own
/// rounded platter, producing a "button inside the input" look.
private final class NonFocusableTextField: UITextField {
  override var canBecomeFocused: Bool { false }
}

/// Hosts the tvOS keyboard for the chat composer. The visible capsule and draft
/// text are drawn in SwiftUI; this `UITextField` stays visually clear so only
/// the Liquid Glass capsule shows. It deliberately keeps a normal (non‑zero)
/// alpha — tvOS treats near‑invisible views as hidden and instantly resigns
/// their first responder, which is why the previous version's keyboard vanished
/// the moment it appeared. Becoming first responder is also deferred off the
/// SwiftUI update pass so it isn't torn down by the in‑flight view update.
private struct ChatKeyboardHostField: UIViewRepresentable {
  @Binding var text: String
  var activationToken: Int = 0
  var onSubmit: () -> Void = {}
  /// Keyboard return-key label. The chat composer uses `.send`; the settings
  /// URL field uses `.done` (and dismisses on return rather than posting).
  var returnKeyType: UIReturnKeyType = .send
  /// When true, pressing return resigns first responder and dismisses the
  /// keyboard instead of keeping the field active.
  var dismissesOnReturn: Bool = false

  /// Shown only as the prompt at the top of the tvOS keyboard entry screen
  /// (the placeholder is surfaced there by the system). It is applied just
  /// before the keyboard presents and cleared when editing ends, so it never
  /// renders inline behind the resting glass capsule.
  var keyboardPrompt: String = "Your message posts to chat immediately"

  func makeUIView(context: Context) -> UITextField {
    let field = NonFocusableTextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.backgroundColor = .clear
    field.textColor = .clear
    field.tintColor = .clear
    field.font = .preferredFont(forTextStyle: .callout)
    field.returnKeyType = returnKeyType
    field.enablesReturnKeyAutomatically = !dismissesOnReturn
    field.autocorrectionType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.addTarget(
      context.coordinator,
      action: #selector(Coordinator.editingChanged(_:)),
      for: .editingChanged
    )
    return field
  }

  func updateUIView(_ uiView: UITextField, context: Context) {
    context.coordinator.parent = self
    if uiView.text != text {
      uiView.text = text
    }

    if context.coordinator.lastActivationToken != activationToken {
      context.coordinator.lastActivationToken = activationToken
      DispatchQueue.main.async {
        if !uiView.isFirstResponder {
          // Set the prompt right before presenting so the keyboard screen shows
          // it; it's cleared again in textFieldDidEndEditing to avoid leaking
          // behind the resting capsule.
          uiView.placeholder = self.keyboardPrompt
          uiView.becomeFirstResponder()
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self, lastActivationToken: activationToken)
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: ChatKeyboardHostField
    var lastActivationToken: Int

    init(_ parent: ChatKeyboardHostField, lastActivationToken: Int) {
      self.parent = parent
      self.lastActivationToken = lastActivationToken
    }

    @objc func editingChanged(_ field: UITextField) {
      parent.text = field.text ?? ""
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      // Clear the prompt so it never renders inline behind the resting capsule.
      textField.placeholder = nil
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.onSubmit()
      if parent.dismissesOnReturn {
        textField.resignFirstResponder()
        return true
      }
      return false
    }
  }
}

/// A small progress pill shown after sending a chat message while stream-sync
/// is holding chat back, counting down until the sent message reaches the
/// delayed video on screen.
private struct ChatSyncSendIndicator: View {
  let deadline: Date
  let total: Double

  var body: some View {
    TimelineView(.animation) { context in
      let remaining = max(0, deadline.timeIntervalSince(context.date))
      let progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 1
      HStack(spacing: 10) {
        Icon(glyph: .clock, size: 16)
          .foregroundStyle(.white.opacity(0.7))
        VStack(alignment: .leading, spacing: 4) {
          Text(remaining > 0.5
            ? "Sent — appears in \(Int(remaining.rounded()))s"
            : "Appearing now…")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.82))
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(.purple)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

/// Styles the chat pane as a floating, rounded Liquid Glass panel when enabled,
/// otherwise leaves it as a full-height docked panel.
private struct GlassChatPaneStyle: ViewModifier {
  let enabled: Bool

  /// Inset between the glass panel and the screen edges.
  static let edgeInset: CGFloat = 24

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 32, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      glassBody(content)
        .padding(.vertical, GlassChatPaneStyle.edgeInset)
        .padding(.trailing, GlassChatPaneStyle.edgeInset)
    } else {
      content.frame(maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func glassBody(_ content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

/// Gives the floating chat-settings panel the same real Liquid Glass surface as
/// the Glass chat pane (`.glassEffect(.regular)`), with a matching subtle white
/// hairline. Unlike `GlassChatPaneStyle` it does not clip or inset, so the
/// panel can size to its content and its inner focus effects can lift freely.
private struct ChatSettingsPanelGlassStyle: ViewModifier {
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 32, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

/// A single timestamped diagnostics event (stall, jump, or reload) shown in the
/// experimental latency overlay so playback hiccups can be observed directly.
private struct DiagnosticsEvent: Identifiable {
  let id = UUID()
  let at: Date
  let text: String
}

/// Passive latency HUD chip. Its own `View` type so the per-second latency
/// refresh only invalidates this chip, not the whole `PlayerView` body.
private struct LatencyBadge: View {
  let color: Color
  let label: String

  var body: some View {
    let shape = Capsule(style: .continuous)
    return HStack(spacing: 8) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)

      Text(label)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    // Frosted material rather than focusable Liquid Glass: this is a passive
    // HUD readout, so it should read as an info chip, not a pressable control.
    .background(.ultraThinMaterial, in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }
}

/// Live, read-off-the-screen diagnostics for troubleshooting freezes/jumps.
/// Its own `View` type so the per-second diagnostics refresh invalidates only
/// this panel. The parent computes `lines` (it owns the player state) and
/// passes them in; rendering lives here.
private struct DiagnosticsPanel: View {
  let lines: [String]
  let events: [DiagnosticsEvent]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text("DIAGNOSTICS")
        .font(.system(size: 13, weight: .heavy).monospaced())
        .foregroundStyle(.white.opacity(0.6))

      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.system(size: 14, weight: .semibold).monospaced())
          .foregroundStyle(.white)
      }

      if !events.isEmpty {
        Divider().overlay(.white.opacity(0.2)).padding(.vertical, 2)
        ForEach(events) { event in
          Text(Self.eventLine(event))
            .font(.system(size: 13, weight: .regular).monospaced())
            .foregroundStyle(.white.opacity(0.8))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 520, alignment: .leading)
    .background(.black.opacity(0.55), in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }

  private static func eventLine(_ event: DiagnosticsEvent) -> String {
    let ago = max(0, Int(Date().timeIntervalSince(event.at).rounded()))
    return "• \(event.text)  (\(ago)s ago)"
  }
}
