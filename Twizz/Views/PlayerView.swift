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
  @AppStorage("chatTextSize") private var chatTextSizeRaw = ChatTextSizeOption.medium.rawValue
  @AppStorage("chatLineHeight") private var chatLineHeightRaw = ChatLineHeightOption.normal.rawValue
  @AppStorage("chatLineSpacing") private var chatLineSpacingRaw = ChatLineSpacingOption.normal.rawValue
  @AppStorage("chatWidthMode") private var chatWidthModeRaw = ChatWidthMode.medium.rawValue
  @AppStorage("chatLayoutMode") private var chatLayoutModeRaw = ChatLayoutMode.side.rawValue
  @AppStorage("chatSyncToStream") private var chatSyncToStream = false
  @AppStorage("experimentalYouTubeMergeEnabled") private var experimentalYouTubeMergeEnabled = false
  @AppStorage("experimentalYouTubeMergeChannelOrURL") private var experimentalYouTubeMergeChannelOrURL = ""
  @AppStorage(LowLatencyHLSProxy.settingsKey) private var lowLatencyProxyEnabled = true
  @AppStorage("showLatencyDiagnostics") private var showLatencyDiagnostics = false

  @State private var chat = ChatService()
  @State private var player = AVPlayer()
  /// Retained for the player's lifetime: `AVURLAsset` only holds its resource
  /// loader delegate weakly, so the proxy must be owned here to stay alive.
  @State private var lowLatencyProxy = LowLatencyHLSProxy(headers: PlaybackService.streamHeaders)
  @State private var playback: StreamPlayback?
  @State private var errorMessage: String?
  @State private var isLoading = true
  @State private var showChat: Bool = UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool ?? true
  @State private var chatReplayStartMessageID: ChatMessage.ID?
  /// Live resolution AVPlayer's adaptive (Auto) selection is currently showing,
  /// e.g. "1080p60". Drives the "Auto (1080p60)" label on the quality button.
  @State private var resolvedQualityName: String?
  @State private var showSignInSheet = false
  @State private var showChatSettings = false
  @State private var showControls = false
  @State private var streamTitle: String = ""
  @State private var channelDisplayName: String = ""
  @State private var channelAvatarURL: URL?
  @State private var chatDraft: String = ""
  @State private var chatInputActivationToken: Int = 0
  @State private var isSendingChat = false
  @State private var chatSendError: String?
  /// When chat sync is active, a sent message is held until it appears in the
  /// delayed stream. This is the wall-clock moment it should surface.
  @State private var chatSyncSendDeadline: Date?
  @State private var chatSyncSendDelay: Double = 0
  @State private var chatSyncSendClearTask: Task<Void, Never>?
  @State private var hideTask: Task<Void, Never>?
  @State private var focusRecoveryTask: Task<Void, Never>?
  @State private var showQualityDialog = false
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
    case chatSend
    case chatSettingsButton
    case chatTextSizeOption(Int)
    case chatLineHeightOption(Int)
    case chatLineSpacingOption(Int)
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
    case chatSyncToggle
    case chatLowLatencyToggle
    case chatDiagnosticsToggle
    case youtubeMergeToggle
    case youtubeMergeURL
    case raidFollow
    case raidStay
  }

  private var chatTextSize: ChatTextSizeOption {
    ChatTextSizeOption(rawValue: chatTextSizeRaw) ?? .medium
  }

  private var chatLineHeight: ChatLineHeightOption {
    ChatLineHeightOption(rawValue: chatLineHeightRaw) ?? .normal
  }

  private var chatLineSpacing: ChatLineSpacingOption {
    ChatLineSpacingOption(rawValue: chatLineSpacingRaw) ?? .normal
  }

  private var chatWidthMode: ChatWidthMode {
    ChatWidthMode(rawValue: chatWidthModeRaw) ?? .medium
  }

  private var chatLayoutMode: ChatLayoutMode {
    ChatLayoutMode(rawValue: chatLayoutModeRaw) ?? .side
  }

  private var chatWidth: CGFloat {
    chatWidthMode.width
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
    }
    .onChange(of: chat.pendingRaid) { _, newRaid in
      guard newRaid != nil else { return }
      raidBannerDismissTask?.cancel()
      raidBannerDismissTask = Task {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        withAnimation { chat.pendingRaid = nil }
      }
      withAnimation { focus = .raidFollow }
    }
    .task {
      if activeChannel.isEmpty { activeChannel = channel }
      configurePlayerForLive()
      resetDiagnostics()
      applyExperimentalYouTubeSettings()
      chat.connect(to: activeChannel)
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
      stopPlaybackWatchdog()
      stopLatencyMonitor()
      player.pause()
      chat.disconnect()
      setIdleTimer(disabled: false)
    }
    .onExitCommand {
      if showChatSettings {
        showChatSettings = false
        focus = .chatSettingsButton
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
      } else if newFocus == nil, !showQualityDialog {
        // tvOS can briefly drop focus to nil after system surfaces
        // dismiss. Re-assert the last control if focus doesn't come back.
        focusRecoveryTask?.cancel()
        let target = lastControlFocus
        focusRecoveryTask = Task {
          try? await Task.sleep(for: .milliseconds(140))
          guard !Task.isCancelled else { return }
          await MainActor.run {
            guard showControls, !showChatSettings, !showQualityDialog else { return }
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

  private var videoColumn: some View {
    ZStack(alignment: .bottom) {
      VideoSurface(player: player)
        .ignoresSafeArea()

      if showControls, !isLoading,
        errorMessage == nil
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
      if !showControls {
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

      if let errorMessage {
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

  private var bottomOverlay: some View {
    HStack(alignment: .top, spacing: 24) {
      HStack(alignment: .top, spacing: 12) {
        Button {
          scheduleHide()
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
          .fixedSize(horizontal: false, vertical: true)
          .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Spacer(minLength: 18)

      HStack(spacing: 14) {
        // Use a native confirmation dialog with explicit presentation state so
        // focus handoff is deterministic when opening/closing quality options.
        Button {
          focusRecoveryTask?.cancel()
          lastControlFocus = .quality
          showQualityDialog = true
          // While the system dialog is open, let tvOS own focus entirely.
          focus = nil
        } label: {
          Text(qualityButtonLabel)
            .font(.subheadline)
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Quality, \(qualityButtonLabel)")
        }
        .focused($focus, equals: .quality)
        .confirmationDialog("Quality", isPresented: $showQualityDialog, titleVisibility: .visible) {
          ForEach(Array(qualityOptions.enumerated()), id: \.element) { index, option in
            Button(option == preferredQuality ? "Current: \(qualityDisplayLabel(option))" : qualityDisplayLabel(option)) {
              selectQuality(at: index)
            }
          }
        }
        .onChange(of: showQualityDialog) { _, isPresented in
          if isPresented { return }
          focusRecoveryTask?.cancel()
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            focus = .quality
          }
          scheduleHide()
        }
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
        // Don't auto-hide while the quality picker is engaged. During system
        // dialog presentation tvOS owns focus and app focus may be nil.
        if focus == .quality || (focus == nil && lastControlFocus == .quality) {
          scheduleHide()
          return
        }
        if showQualityDialog {
          scheduleHide()
          return
        }
        hideControls()
      }
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
      .chatTextSizeOption,
      .chatLineHeightOption,
      .chatLineSpacingOption,
      .chatWidthOption,
      .chatLayoutOption,
      .chatSyncToggle,
      .chatLowLatencyToggle,
      .chatDiagnosticsToggle,
      .youtubeMergeToggle,
      .youtubeMergeURL:
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
        messageSpacing: chatLineSpacing,
        lineHeight: chatLineHeight,
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
    // Float the settings above the glass clip so the expanding panel is never
    // cut off by the rounded glass shape.
    .overlay(alignment: .topTrailing) {
      chatSettingsFloating
        .padding(.top, isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16)
        .padding(.trailing, isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16)
    }
  }

  // MARK: - Floating chat settings

  /// A compact settings control that floats in the top-right of the chat.
  /// It is only reachable by pressing up from the chat input, so it never
  /// steals focus while the user is scrolling or typing.
  private var chatSettingsFloating: some View {
    VStack(alignment: .trailing, spacing: 10) {
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
          let selected = ChatTextSizeOption.allCases.firstIndex(of: chatTextSize) ?? 0
          focus = .chatTextSizeOption(selected)
        } else if direction == .down {
          focus = .chatInput
        }
      }

      if showChatSettings {
        chatSettingsPanel
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.18), value: showChatSettings)
  }

  private var chatSettingsPanel: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 7) {
        Text("Text Size")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatTextSizeOption.allCases.enumerated()), id: \.element) { index, option in
            settingsPill(
              title: option.title,
              isSelected: option == chatTextSize,
              focusTag: .chatTextSizeOption(index)
            ) {
              chatTextSizeRaw = option.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Line Height")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatLineHeightOption.allCases.enumerated()), id: \.element) { index, option in
            settingsPill(
              title: option.title,
              isSelected: option == chatLineHeight,
              focusTag: .chatLineHeightOption(index)
            ) {
              chatLineHeightRaw = option.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Message Spacing")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatLineSpacingOption.allCases.enumerated()), id: \.element) { index, option in
            settingsPill(
              title: option.title,
              isSelected: option == chatLineSpacing,
              focusTag: .chatLineSpacingOption(index)
            ) {
              chatLineSpacingRaw = option.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Chat Width")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatWidthMode.allCases.enumerated()), id: \.element) { index, mode in
            settingsPill(
              title: mode.title,
              isSelected: mode == chatWidthMode,
              focusTag: .chatWidthOption(index)
            ) {
              chatWidthModeRaw = mode.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Chat Position")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
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

      VStack(alignment: .leading, spacing: 7) {
        Text("Stream Sync")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

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
        Text("Playback")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

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

        Text(
          "Low-Latency Mode rewrites Twitch prefetch segments to reduce delay. Diagnostics shows live render/bitrate/buffer and freeze/jump events."
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      }
      .focusSection()

      VStack(alignment: .leading, spacing: 7) {
        Text("Experimental")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.84))
          .textCase(.uppercase)

        settingsPill(
          title: "Merge with YouTube Chat",
          isSelected: experimentalYouTubeMergeEnabled,
          focusTag: .youtubeMergeToggle
        ) {
          experimentalYouTubeMergeEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        TextField("YouTube handle/URL (defaults to @\(activeChannel))", text: $experimentalYouTubeMergeChannelOrURL)
          .textFieldStyle(.plain)
          .font(.callout)
          .foregroundStyle(focus == .youtubeMergeURL ? .black : .white)
          .tint(focus == .youtubeMergeURL ? .black : .white)
          .lineLimit(1)
          .padding(.horizontal, 14)
          .focusEffectDisabled()
          .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(focus == .youtubeMergeURL ? 0.86 : 0.09), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
          RoundedRectangle(cornerRadius: 11)
            .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        .clipped()
        .focused($focus, equals: .youtubeMergeURL)
        .onMoveCommand { direction in
          if direction == .left {
            focus = .chatSettingsButton
          }
        }

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
      .padding(.vertical, 18)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 620)
    .frame(maxHeight: 680)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(.white.opacity(0.20), lineWidth: 1)
    )
    // Intentionally avoid clipShape here: tvOS focus effects can scale beyond
    // bounds, and clipping reintroduces visibly cut-off hover/focus states.
    .shadow(color: .black.opacity(0.30), radius: 22, x: 0, y: 10)
    .focusSection()
  }

  private func settingsPill(
    title: String,
    isSelected: Bool,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    let isFocused = focus == focusTag

    return Button(action: action) {
      HStack(spacing: 8) {
        if isSelected {
          Icon(glyph: .check, size: 24)
        }
        Text(title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(
            .white.opacity(
              isFocused
                ? (isSelected ? 0.30 : 0.18)
                : (isSelected ? 0.20 : 0.08)
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(
            .white.opacity(
              isFocused
                ? (isSelected ? 0.78 : 0.58)
                : (isSelected ? 0.42 : 0.18)
            ),
            lineWidth: 1
          )
      )
    }
    // Keep this custom button style (instead of .plain) so tvOS focus visuals
    // remain consistent with the rest of the player controls.
    .buttonStyle(ChatSettingsPillButtonStyle())
    .focusEffectDisabled()
    .focused($focus, equals: focusTag)
  }

  private func toggleChatSettings() {
    showChatSettings.toggle()
    if showChatSettings {
      let selected = ChatTextSizeOption.allCases.firstIndex(of: chatTextSize) ?? 0
      let target: Focusable = .chatTextSizeOption(selected)
      lastChatSettingsFocus = target
      focus = target
    } else {
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
            ZStack(alignment: .leading) {
              ChatKeyboardHostField(
                text: $chatDraft,
                activationToken: chatInputActivationToken,
                onSubmit: submitChatMessage
              )
              .allowsHitTesting(false)
              .frame(maxWidth: .infinity, maxHeight: .infinity)

              Text(chatDraft.isEmpty ? "Send a message" : chatDraft)
                .font(.subheadline)
                .foregroundStyle(focus == .chatInput
                  ? .black.opacity(chatDraft.isEmpty ? 0.55 : 1.0)
                  : .white.opacity(chatDraft.isEmpty ? 0.5 : 1.0))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .frame(height: chatComposerRowHeight)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput))
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

  @ViewBuilder
  private func raidBanner(_ raid: RaidEvent) -> some View {
    VStack {
      Spacer()
      HStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(raid.displayName) is raiding!")
            .font(.title2).bold()
            .foregroundStyle(.white)
          Text("\(raid.viewerCount) viewers incoming")
            .font(.headline)
            .foregroundStyle(.white.opacity(0.8))
        }
        Spacer()
        Button {
          withAnimation { followRaid(raid.login) }
        } label: {
          Text("Follow Raid")
            .font(.headline).bold()
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background(Color.purple)
        .clipShape(Capsule())
        .focused($focus, equals: .raidFollow)

        Button {
          raidBannerDismissTask?.cancel()
          withAnimation { chat.pendingRaid = nil }
        } label: {
          Text("Stay Here")
            .font(.headline)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.18))
        .clipShape(Capsule())
        .focused($focus, equals: .raidStay)
      }
      .padding(32)
      .background(.black.opacity(0.75))
      .clipShape(RoundedRectangle(cornerRadius: 20))
      .padding(.horizontal, 60)
      .padding(.bottom, 60)
    }
    .ignoresSafeArea()
  }

  private func followRaid(_ login: String) {
    raidBannerDismissTask?.cancel()
    chat.pendingRaid = nil
    activeChannel = login
    stopPlaybackWatchdog()
    stopLatencyMonitor()
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentSourceURL = nil
    chat.disconnect()
    resetDiagnostics()
    isLoading = true
    errorMessage = nil
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
    guard !isLoading, errorMessage == nil
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
    isRecoveringPlayback = true
    diagReloadCount += 1
    if showLatencyDiagnostics { logDiagnosticsEvent("reload (\(reason))") }
    // A reload restarts the timeline, so clear the jump baseline to avoid
    // counting the discontinuity as a playhead jump.
    diagLastPlayheadSeconds = nil
    diagLastSampleAt = nil
    await load(maxAttempts: 2, reason: reason, resetMetadata: false)
    isRecoveringPlayback = false
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

/// A completely passthrough button style for the chat input surface.
/// Suppresses all platform button visuals (hover, scale, ring) so only
/// the SwiftUI glass shell controls the appearance.
private struct ChatInputButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Gives the chat composer field a Liquid Glass capsule at rest and the standard
/// tvOS focus treatment when focused: a solid white fill with a subtle lift and
/// drop shadow, matching every other focusable control. Falls back to
/// `.ultraThinMaterial` on systems older than tvOS 26.
private struct ChatGlassFieldStyle: ViewModifier {
  let isFocused: Bool

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if isFocused {
      content
        .background(.white, in: shape)
        .scaleEffect(1.05)
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
    } else if #available(tvOS 26.0, *) {
      content
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
    }
  }
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

  func makeUIView(context: Context) -> UITextField {
    let field = UITextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.backgroundColor = .clear
    field.textColor = .clear
    field.tintColor = .clear
    field.font = .preferredFont(forTextStyle: .callout)
    field.returnKeyType = .send
    field.enablesReturnKeyAutomatically = true
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.onSubmit()
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
