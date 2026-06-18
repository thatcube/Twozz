import AVKit
import SwiftUI
import UIKit

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twizz UI while preserving Apple's media rendering paths
/// better than a raw `AVPlayerLayer`.
struct VideoSurface: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.videoGravity = .resizeAspect
    // Keep output mode stable while toggling in-app layouts (chat on/off).
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    controller.view.backgroundColor = .black
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = false
    controller.videoGravity = .resizeAspect
    controller.appliesPreferredDisplayCriteriaAutomatically = false
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
  @State private var showQualityPicker = false
  @State private var showSignInSheet = false
  @State private var showChatSettings = false
  @State private var showControls = false
  @State private var isFollowing = false
  @State private var followInProgress = false
  @State private var followError: String?
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
  @State private var latencyTask: Task<Void, Never>?
  @State private var playbackWatchdogTask: Task<Void, Never>?
  @State private var wallClockLatencySeconds: Double?
  @State private var liveEdgeLatencySeconds: Double?
  @State private var smoothedLatencySeconds: Double?
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
  private let playbackWatchdogIntervalSeconds: Double = 2
  // Diagnostics: how much unexplained playhead movement between 1s samples counts
  // as a "jump". Catch-up rate nudges (≤1.05x) only add a fraction of a second,
  // so a multi-second drift is a genuine AVPlayer skip, not normal catch-up.
  private let diagJumpForwardThresholdSeconds: Double = 2.0
  private let diagJumpBackwardThresholdSeconds: Double = 1.0
  private let chatReplayMessageCount = 30
  private let chatComposerRowHeight: CGFloat = 62
  private let chatInputFocusedHeight: CGFloat = 62
  private let chatInputUnfocusedHeight: CGFloat = 54

  @FocusState private var focus: Focusable?
  private enum Focusable: Hashable {
    case video, streamInfo, quality, follow, chatToggle, chatInput, errorBack
    case chatSend
    case chatSettingsButton
    case qualityOption(Int)
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

      if showQualityPicker {
        qualityPicker
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
      async let followStateTask: Void = refreshFollowState()
      await load()
      _ = await metadataTask
      _ = await followStateTask
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
      if showQualityPicker {
        showQualityPicker = false
        focus = .quality
        scheduleHide()
      } else if showChatSettings {
        showChatSettings = false
        focus = .chatSettingsButton
      } else if showControls {
        hideControls()
      } else {
        dismiss()
      }
    }
    .onMoveCommand { direction in
      guard !showQualityPicker else { return }

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
      guard showControls, !showQualityPicker else {
        return
      }

      if let newFocus, isControlFocus(newFocus) {
        focusRecoveryTask?.cancel()
        lastControlFocus = newFocus
        scheduleHide()
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

      if showControls, !showQualityPicker, !isLoading,
        errorMessage == nil
      {
        VStack {
          HStack {
            latencyBadge
            Spacer()
            if let followError {
              Text(followError)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(
                  Capsule(style: .continuous)
                    .strokeBorder(.orange.opacity(0.6), lineWidth: 1)
                )
            }
          }
          if showLatencyDiagnostics {
            HStack {
              diagnosticsPanel
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
      if !showControls && !showQualityPicker {
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
      } else if showControls && !showQualityPicker {
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
                  Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.white.opacity(0.85))
                }
              }
            } else {
              ZStack {
                Circle().fill(.white.opacity(0.16))
                Image(systemName: "person.crop.circle.fill")
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
        Button {
          showQualityPicker = true
          hideTask?.cancel()
        } label: {
          Label("Quality", systemImage: "gauge.with.dots.needle.67percent")
            .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .quality)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .streamInfo
          case .right:
            focus = .follow
          default:
            break
          }
        }

        Button {
          toggleFollow()
        } label: {
          Label(
            isFollowing ? "Following" : "Follow",
            systemImage: isFollowing ? "heart.fill" : "heart"
          )
          .labelStyle(.iconOnly)
        }
        .disabled(followInProgress)
        .focused($focus, equals: .follow)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .quality
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
          Label(
            showChat ? "Hide Chat" : "Show Chat",
            systemImage: showChat ? "sidebar.right" : "bubble.left.and.bubble.right.fill"
          )
          .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .chatToggle)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .follow
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

  private var latencyBadge: some View {
    let shape = Capsule(style: .continuous)
    return HStack(spacing: 8) {
      Circle()
        .fill(latencyColor)
        .frame(width: 8, height: 8)

      Text(latencyLabel)
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

  // MARK: - Diagnostics overlay

  /// Live, read-off-the-screen diagnostics for troubleshooting freezes/jumps.
  /// Everything here is measured from the player/current item — no estimates.
  private var diagnosticsPanel: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text("DIAGNOSTICS")
        .font(.system(size: 13, weight: .heavy).monospaced())
        .foregroundStyle(.white.opacity(0.6))

      ForEach(diagnosticsLines, id: \.self) { line in
        Text(line)
          .font(.system(size: 14, weight: .semibold).monospaced())
          .foregroundStyle(.white)
      }

      if !diagEvents.isEmpty {
        Divider().overlay(.white.opacity(0.2)).padding(.vertical, 2)
        ForEach(diagEvents) { event in
          Text(diagnosticsEventLine(event))
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

    return lines
  }

  private func diagnosticsEventLine(_ event: DiagnosticsEvent) -> String {
    let ago = max(0, Int(Date().timeIntervalSince(event.at).rounded()))
    return "• \(event.text)  (\(ago)s ago)"
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
      } else if advanced <= -diagJumpBackwardThresholdSeconds {
        diagJumpCount += 1
        logDiagnosticsEvent("jump \(diagFormat(advanced, decimals: 1))s back")
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
        guard !showQualityPicker else { return }
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
    case .streamInfo, .quality, .follow, .chatToggle, .chatInput:
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
        Image(systemName: showChatSettings ? "xmark" : "slider.horizontal.3")
          .font(.system(size: 22, weight: .semibold))
          .frame(width: 30, height: 30)
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
          ForEach(Array(ChatTextSizeOption.allCases.enumerated()), id: \.offset) { index, option in
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
          ForEach(Array(ChatLineHeightOption.allCases.enumerated()), id: \.offset) { index, option in
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
          ForEach(Array(ChatLineSpacingOption.allCases.enumerated()), id: \.offset) { index, option in
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
          ForEach(Array(ChatWidthMode.allCases.enumerated()), id: \.offset) { index, mode in
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
          ForEach(Array(ChatLayoutMode.allCases.enumerated()), id: \.offset) { index, mode in
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

        ChatInputField(
          text: $experimentalYouTubeMergeChannelOrURL,
          placeholder: "YouTube handle/URL (defaults to @\(activeChannel))",
          isFocused: focus == .youtubeMergeURL
        )
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
              Image(systemName: "checkmark.circle.fill")
                .font(.caption)
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
          Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
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
        ZStack(alignment: .trailing) {
          Button {
            chatInputActivationToken &+= 1
          } label: {
            ZStack {
              ChatInputField(
                text: $chatDraft,
                placeholder: "Send a message",
                isFocused: focus == .chatInput,
                activationToken: chatInputActivationToken
              )
              .allowsHitTesting(false)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              Text(chatDraft.isEmpty ? "Send a message" : chatDraft)
                .font(.callout)
                .foregroundStyle(focus == .chatInput
                  ? (chatDraft.isEmpty ? Color.black.opacity(0.45) : Color.black)
                  : .white.opacity(chatDraft.isEmpty ? 0.45 : 1.0))
                .lineLimit(1)
                .padding(.leading, 18)
                .padding(.trailing, hasChatDraft ? 118 : 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: hasChatDraft ? chatInputFocusedHeight : (focus == .chatInput ? chatInputFocusedHeight : chatInputUnfocusedHeight))
            .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
            .padding(.trailing, hasChatDraft ? 108 : 0)
            .frame(maxWidth: .infinity)
            .modifier(ChatInputShellStyle(isFocused: focus == .chatInput))
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
            case .right:
              if hasChatDraft { focus = .chatSend } else { focus = .chatInput }
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
                Image(systemName: "paperplane.fill")
                  .font(.system(size: 20, weight: .semibold))
                  .frame(width: 24, height: 24)
              }
            }
            .TwizzControlButtonStyle()
            .frame(height: chatInputFocusedHeight)
            .padding(.trailing, 8)
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
          ZStack {
            ChatInputField(
              text: .constant(""),
              placeholder: "Sign in to send messages",
              isFocused: focus == .chatInput,
              allowsEditing: false
            )
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Sign in to send messages")
              .font(.callout)
              .foregroundStyle(.white.opacity(0.45))
              .lineLimit(1)
              .padding(.leading, 18)
              .padding(.trailing, 24)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: focus == .chatInput ? chatInputFocusedHeight : chatInputUnfocusedHeight)
          .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
          .frame(maxWidth: .infinity)
          .modifier(ChatInputShellStyle(isFocused: focus == .chatInput))
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
    isFollowing = false
    followError = nil
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
      async let followStateTask: Void = refreshFollowState()
      await load(reason: "raid follow", resetMetadata: false)
      _ = await metadataTask
      _ = await followStateTask
      focus = .video
    }
  }

  // MARK: - Quality picker

  private var qualityPicker: some View {
    ZStack {
      Color.black.opacity(0.5).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 8) {
        Text("Quality")
          .font(.title2).bold()
          .padding(.bottom, 8)

        ForEach(Array(qualityOptions.enumerated()), id: \.offset) { index, option in
          Button {
            selectQuality(at: index)
          } label: {
            HStack {
              Text(qualityDisplayLabel(option))
              Spacer()
              if option == preferredQuality {
                Image(systemName: "checkmark")
              }
            }
            .frame(width: 420)
          }
          .buttonStyle(.bordered)
          .focused($focus, equals: .qualityOption(index))
        }
      }
      .padding(40)
      .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 28))
      .focusSection()
    }
    .onAppear {
      // Move focus into the picker once it's on screen; the underlying
      // control bar is hidden while the picker is open so it can't steal focus.
      let target = qualityOptions.firstIndex(of: preferredQuality) ?? 0
      focus = .qualityOption(target)
    }
  }

  private var qualityOptions: [String] {
    ["Auto"] + (playback?.qualities.map(\.name) ?? [])
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
    showQualityPicker = false
    applyQualityPreference(option)
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

  private var latencyColor: Color {
    guard let seconds = measuredLatencySeconds else { return .gray }
    if seconds <= 8 { return .green }
    if seconds <= 15 { return .yellow }
    return .orange
  }

  private var latencyLabel: String {
    if !isPlaybackActive {
      return "Waiting for playback"
    }
    if let seconds = measuredLatencySeconds {
      return "~\(formatLatencySeconds(seconds)) behind live"
    }
    return "Latency unavailable"
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
    guard !isLoading, errorMessage == nil, !showQualityPicker
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
      return
    }
    guard let prev = smoothedLatencySeconds else {
      smoothedLatencySeconds = raw
      return
    }
    if abs(raw - prev) >= 3 {
      smoothedLatencySeconds = raw
    } else {
      smoothedLatencySeconds = prev * 0.6 + raw * 0.4
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

  // MARK: - Follow / unfollow

  private func refreshFollowState() async {
    guard auth.isAuthenticated else {
      isFollowing = false
      return
    }
    let target = activeChannel
    guard let following = try? await auth.isFollowing(channelLogin: target) else {
      return
    }
    // Ignore a stale result if the user raided to another channel meanwhile.
    guard target == activeChannel else { return }
    isFollowing = following
  }

  private func toggleFollow() {
    guard auth.isAuthenticated else {
      showSignInSheet = true
      return
    }
    guard !followInProgress else { return }

    let target = activeChannel
    let wantFollow = !isFollowing
    followInProgress = true
    followError = nil
    // Optimistically reflect the new state; revert if the request fails.
    isFollowing = wantFollow
    scheduleHide()

    Task {
      do {
        if wantFollow {
          try await auth.followChannel(login: target)
        } else {
          try await auth.unfollowChannel(login: target)
        }
      } catch {
        await MainActor.run {
          if target == activeChannel {
            isFollowing = !wantFollow
          }
          followError =
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          scheduleFollowErrorDismiss()
        }
      }
      await MainActor.run { followInProgress = false }
    }
  }

  private func scheduleFollowErrorDismiss() {
    Task {
      try? await Task.sleep(for: .seconds(5))
      await MainActor.run { followError = nil }
    }
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

/// Gives the chat composer field a glassy shell while preserving the UIKit
/// text field behavior and focus handling.
private struct ChatInputShellStyle: ViewModifier {
  let isFocused: Bool

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      if isFocused {
        content
          .background(.white, in: shape)
          .scaleEffect(1.02)
          .shadow(color: .white.opacity(0.25), radius: 12, x: 0, y: 0)
          .shadow(color: .black.opacity(0.22), radius: 7, x: 0, y: 3)
      } else {
        content
          .clipShape(shape)
          .glassEffect(.regular, in: shape)
          .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 2)
      }
    } else {
      if isFocused {
        content
          .background(.white, in: shape)
          .scaleEffect(1.02)
      } else {
        content
          .background(.ultraThinMaterial, in: shape)
          .overlay(
            shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
          )
      }
    }
  }
}

/// A fully custom chat input backed by a `UITextField` so we control the
/// background (clear — no native focus platter) and vertically center the text.
/// SwiftUI's `TextField` on tvOS draws its own opaque focus platter that can't
/// be removed and pins text near the top, which is why we drop down to UIKit.
private struct ChatInputField: UIViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let isFocused: Bool
  var activationToken: Int = 0
  var allowsEditing: Bool = true
  var onActivate: (() -> Void)? = nil

  func makeUIView(context: Context) -> UITextField {
    let field = UITextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.backgroundColor = .clear
    field.textColor = .white
    field.tintColor = .white
    field.font = .preferredFont(forTextStyle: .callout)
    field.contentVerticalAlignment = .center
    field.adjustsFontForContentSizeCategory = true
    field.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)]
    )
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.addTarget(
      context.coordinator,
      action: #selector(Coordinator.editingChanged(_:)),
      for: .editingChanged
    )
    field.alpha = 0.001
    return field
  }

  func updateUIView(_ uiView: UITextField, context: Context) {
    if uiView.text != text {
      uiView.text = text
    }

    context.coordinator.allowsEditing = allowsEditing
    context.coordinator.onActivate = onActivate

    if context.coordinator.lastActivationToken != activationToken {
      context.coordinator.lastActivationToken = activationToken
      if allowsEditing {
        uiView.becomeFirstResponder()
      } else {
        onActivate?()
      }
    }

    uiView.alpha = 0.001
    uiView.backgroundColor = .clear
    uiView.textColor = .clear
    uiView.tintColor = .clear
    uiView.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: UIColor.clear]
    )
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      allowsEditing: allowsEditing,
      onActivate: onActivate,
      lastActivationToken: activationToken
    )
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    private let text: Binding<String>
    var allowsEditing: Bool
    var onActivate: (() -> Void)?
    var lastActivationToken: Int

    init(
      text: Binding<String>,
      allowsEditing: Bool,
      onActivate: (() -> Void)?,
      lastActivationToken: Int
    ) {
      self.text = text
      self.allowsEditing = allowsEditing
      self.onActivate = onActivate
      self.lastActivationToken = lastActivationToken
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
      guard allowsEditing else {
        onActivate?()
        return false
      }
      return true
    }

    @objc func editingChanged(_ field: UITextField) {
      text.wrappedValue = field.text ?? ""
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
        Image(systemName: "clock.arrow.circlepath")
          .font(.caption2)
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
