import AVKit
import SwiftUI
import UIKit

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twizz UI while preserving Apple media rendering paths
/// (including subtitle/caption rendering) better than raw AVPlayerLayer.
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

  @Environment(\.dismiss) private var dismiss
  @AppStorage("preferredQuality") private var preferredQuality = "Auto"
  @AppStorage("chatReadabilityMode") private var chatReadabilityModeRaw = ChatReadabilityMode
    .balanced.rawValue
  @AppStorage("chatWidthMode") private var chatWidthModeRaw = ChatWidthMode.medium.rawValue
  @AppStorage("chatLayoutMode") private var chatLayoutModeRaw = ChatLayoutMode.side.rawValue

  @State private var chat = ChatService()
  @State private var player = AVPlayer()
  @State private var playback: StreamPlayback?
  @State private var errorMessage: String?
  @State private var isLoading = true
  @State private var loadingRotation: Double = 0
  @State private var showChat = true
  @State private var showQualityPicker = false
  @State private var showCaptionsPicker = false
  @State private var showSignInSheet = false
  @State private var showChatSettings = false
  @State private var showControls = false
  @State private var captionsOn = UIAccessibility.isClosedCaptioningEnabled
  @State private var captionGroup: AVMediaSelectionGroup?
  @State private var captionOptions: [AVMediaSelectionOption] = []
  @State private var captionSelectionKey: String?
  @State private var streamTitle: String = ""
  @State private var channelDisplayName: String = ""
  @State private var channelAvatarURL: URL?
  @State private var chatDraft: String = ""
  @State private var isSendingChat = false
  @State private var chatSendError: String?
  @State private var hideTask: Task<Void, Never>?
  @State private var focusRecoveryTask: Task<Void, Never>?
  @State private var latencyTask: Task<Void, Never>?
  @State private var playbackWatchdogTask: Task<Void, Never>?
  @State private var wallClockLatencySeconds: Double?
  @State private var liveEdgeLatencySeconds: Double?
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

  private let controlsAutoHideSeconds: Double = 10
  private let targetLiveEdgeSeconds: Double = 3.5
  private let softCatchUpThresholdSeconds: Double = 8
  private let hardCatchUpThresholdSeconds: Double = 14
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
  private let chatComposerRowHeight: CGFloat = 62
  private let chatInputFocusedHeight: CGFloat = 62
  private let chatInputUnfocusedHeight: CGFloat = 54

  @FocusState private var focus: Focusable?
  private enum Focusable: Hashable {
    case video, streamInfo, quality, captions, chatToggle, chatInput, errorBack
    case chatSend
    case chatSettingsButton
    case qualityOption(Int)
    case captionsOption(Int)
    case chatDensityOption(Int)
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
  }

  private var chatReadabilityMode: ChatReadabilityMode {
    ChatReadabilityMode(rawValue: chatReadabilityModeRaw) ?? .balanced
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
      Color.black.ignoresSafeArea()

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

      if showCaptionsPicker {
        captionsPicker
      }
    }
    .task {
      configurePlayerForLive()
      applyChatReadabilitySettings()
      chat.connect(to: channel)
      async let metadataTask: Void = refreshChannelMetadata()
      
      // Start loading animation
      let animationTask = Task {
        var rotation: Double = 0
        while !Task.isCancelled {
          rotation += 6  // 60 rotations per second at 100ms intervals
          if rotation >= 360 {
            rotation -= 360
          }
          withAnimation(.linear(duration: 0.016)) {
            loadingRotation = rotation
          }
          try? await Task.sleep(nanoseconds: 16_000_000)  // ~60fps
        }
      }
      
      await load()
      _ = await metadataTask
      animationTask.cancel()
      loadingRotation = 0
      focus = .video
    }
    .onAppear {
      setIdleTimer(disabled: true)
    }
    .onDisappear {
      hideTask?.cancel()
      focusRecoveryTask?.cancel()
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
      } else if showCaptionsPicker {
        showCaptionsPicker = false
        focus = .captions
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
      guard !showQualityPicker, !showCaptionsPicker else { return }

      if !showControls {
        // Directional movement should immediately surface controls and
        // land on chat toggle so moving off chat feels instant.
        revealControls(preferredFocus: .chatToggle)
      } else {
        scheduleHide()
      }
    }
    .onChange(of: focus) { _, newFocus in
      // Keep control navigation deterministic: if tvOS drops focus to nil
      // while controls are visible, immediately restore last valid control.
      guard showControls, !showQualityPicker, !showCaptionsPicker else {
        return
      }

      if let newFocus, isControlFocus(newFocus) {
        focusRecoveryTask?.cancel()
        lastControlFocus = newFocus
        scheduleHide()
      }
    }
    .onChange(of: chatReadabilityModeRaw) { _, _ in
      applyChatReadabilitySettings()
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

      if showControls, !showQualityPicker, !showCaptionsPicker, !isLoading,
        errorMessage == nil
      {
        VStack {
          HStack {
            latencyBadge
            Spacer()
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
        VStack(spacing: 40) {
          ZStack {
            // Multi-ring spinner (Apple Maps style)
            // Outer ring
            Circle()
              .stroke(.white.opacity(0.3), lineWidth: 3)
              .frame(width: 100, height: 100)
            
            // Middle ring
            Circle()
              .stroke(.white.opacity(0.5), lineWidth: 3)
              .frame(width: 70, height: 70)
              .rotationEffect(.degrees(loadingRotation))
            
            // Inner ring
            Circle()
              .stroke(.white.opacity(0.8), lineWidth: 3)
              .frame(width: 40, height: 40)
              .rotationEffect(.degrees(-loadingRotation * 1.5))
            
            // Center dot
            Circle()
              .fill(.white)
              .frame(width: 8, height: 8)
          }

          VStack(spacing: 8) {
            Text("Loading \(channel)")
              .font(.title2.weight(.semibold))
              .foregroundStyle(.white)
            Text("Getting ready…")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.6))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if let errorMessage {
        VStack(spacing: 24) {
          Text("Couldn't play \(channel)")
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
          showCaptionsPicker = false
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
            focus = .captions
          default:
            break
          }
        }

        Button {
          showQualityPicker = false
          prepareCaptionsPicker()
        } label: {
          Label(
            captionsOn ? "Captions On" : "Captions Off",
            systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble"
          )
          .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .captions)
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
          showChat.toggle()
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
            focus = .captions
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
        guard !showCaptionsPicker else { return }
        hideControls()
      }
    }
  }

  private func isControlFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .streamInfo, .quality, .captions, .chatToggle, .chatInput:
      return true
    default:
      return false
    }
  }

  private var chatPane: some View {
    let isGlass = chatLayoutMode == .glass
    return VStack(spacing: 0) {
      ChatView(
        channel: channel,
        messages: chat.messages,
        readabilityMode: chatReadabilityMode,
        isConnected: chat.isConnected,
        emoteURLs: chat.emoteURLs,
        badgeURLs: chat.badgeURLs,
        condensedMessagesCount: chat.condensedMessagesCount,
        useGlassBackground: isGlass
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      chatComposerBar
    }
    .frame(width: chatWidth)
    .modifier(GlassChatPaneStyle(enabled: isGlass))
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
    VStack(alignment: .trailing, spacing: 14) {
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
        if direction == .down, !showChatSettings {
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
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Message Density")
          .font(.headline)
          .foregroundStyle(.white)

        HStack(spacing: 14) {
          ForEach(Array(ChatReadabilityMode.allCases.enumerated()), id: \.offset) { index, mode in
            settingsPill(
              title: mode.title,
              isSelected: mode == chatReadabilityMode,
              focusTag: .chatDensityOption(index)
            ) {
              chatReadabilityModeRaw = mode.rawValue
            }
          }
        }
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Chat Width")
          .font(.headline)
          .foregroundStyle(.white)

        HStack(spacing: 14) {
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
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Chat Position")
          .font(.headline)
          .foregroundStyle(.white)

        HStack(spacing: 14) {
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
        .focusSection()
      }
    }
    .padding(28)
    .fixedSize(horizontal: true, vertical: true)
    .background(Color(white: 0.12).opacity(0.98), in: RoundedRectangle(cornerRadius: 24))
    .focusSection()
  }

  private func settingsPill(
    title: String,
    isSelected: Bool,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isSelected {
          Image(systemName: "checkmark")
            .font(.callout.weight(.bold))
        }
        Text(title)
          .font(.callout.weight(isSelected ? .semibold : .regular))
          .fixedSize()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 12)
    }
    .buttonStyle(.bordered)
    .focused($focus, equals: focusTag)
  }

  private func toggleChatSettings() {
    showChatSettings.toggle()
    if showChatSettings {
      let selected = ChatReadabilityMode.allCases.firstIndex(of: chatReadabilityMode) ?? 0
      focus = .chatDensityOption(selected)
    } else {
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

      if auth.isAuthenticated {
        ZStack(alignment: .trailing) {
          ChatInputField(
            text: $chatDraft,
            placeholder: "Send a message",
            isFocused: focus == .chatInput
          )
          // Match the send button feel: the input grows when focused.
          .frame(height: focus == .chatInput ? chatInputFocusedHeight : chatInputUnfocusedHeight)
          .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
          // Reserve trailing text space only when the send button is visible.
          .padding(.trailing, hasChatDraft ? 66 : 0)
          .frame(maxWidth: .infinity)
          .focused($focus, equals: .chatInput)
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
                Image(systemName: "paperplane.fill")
                  .font(.system(size: 20, weight: .semibold))
                  .frame(width: 24, height: 24)
              }
            }
            .TwizzControlButtonStyle()
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
        ChatInputField(
          text: .constant(""),
          placeholder: "Sign in to send messages",
          isFocused: focus == .chatInput,
          allowsEditing: false,
          onActivate: {
            showSignInSheet = true
            scheduleHide()
          }
        )
        // Keep the signed-out prompt visually aligned with the active input.
        .frame(height: focus == .chatInput ? chatInputFocusedHeight : chatInputUnfocusedHeight)
        .animation(.easeOut(duration: 0.18), value: focus == .chatInput)
        .frame(maxWidth: .infinity)
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
        ? AnyShapeStyle(.clear)
        : AnyShapeStyle(Color(white: 0.07).opacity(0.98))
    )
  }

  private func submitChatMessage() {
    let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isSendingChat else { return }
    isSendingChat = true
    chatSendError = nil
    Task {
      do {
        try await auth.sendChatMessage(text, toChannel: channel)
        chatDraft = ""
      } catch {
        chatSendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      isSendingChat = false
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
              Text(option)
              Spacer()
              if option == preferredQuality {
                Image(systemName: "checkmark")
              }
            }
            .frame(width: 360)
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

  private var captionsPicker: some View {
    ZStack {
      Color.black.opacity(0.5).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 8) {
        Text("Captions")
          .font(.title2).bold()
          .padding(.bottom, 8)

        Button {
          selectCaptionOption(at: 0)
        } label: {
          HStack {
            Text("Off")
            Spacer()
            if !captionsOn {
              Image(systemName: "checkmark")
            }
          }
          .frame(width: 460)
        }
        .buttonStyle(.bordered)
        .focused($focus, equals: .captionsOption(0))

        if captionOptions.isEmpty {
          Text("No caption tracks available right now.")
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        } else {
          ForEach(Array(captionOptions.enumerated()), id: \.offset) { index, option in
            Button {
              selectCaptionOption(at: index + 1)
            } label: {
              HStack {
                Text(option.displayName)
                Spacer()
                if captionsOn, captionSelectionKey == captionKey(option) {
                  Image(systemName: "checkmark")
                }
              }
              .frame(width: 460)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .captionsOption(index + 1))
          }
        }
      }
      .padding(40)
      .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 28))
      .focusSection()
    }
    .onAppear {
      let selectedIndex: Int
      if captionsOn,
        let selected = captionSelectionKey,
        let optionIndex = captionOptions.firstIndex(where: { captionKey($0) == selected })
      {
        selectedIndex = optionIndex + 1
      } else {
        selectedIndex = 0
      }
      focus = .captionsOption(selectedIndex)
    }
  }

  private var qualityOptions: [String] {
    ["Auto"] + (playback?.qualities.map(\.name) ?? [])
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

  private func prepareCaptionsPicker() {
    hideTask?.cancel()

    Task {
      let item = player.currentItem
      let group = try? await item?.asset.loadMediaSelectionGroup(for: .legible)
      await MainActor.run {
        captionGroup = group
        captionOptions = group?.options ?? []
        showCaptionsPicker = true
      }
    }
  }

  private func selectCaptionOption(at index: Int) {
    guard index == 0 || captionOptions.indices.contains(index - 1) else { return }

    if index == 0 {
      captionsOn = false
      captionSelectionKey = nil
    } else {
      let option = captionOptions[index - 1]
      captionsOn = true
      captionSelectionKey = captionKey(option)
    }

    applyCaptions()
    showCaptionsPicker = false
    focus = .captions
    scheduleHide()
  }

  private func applyChatReadabilitySettings() {
    chat.applyReadabilitySettings(
      mode: chatReadabilityMode,
      smartFilteringEnabled: false,
      collapseRepeatsEnabled: false
    )
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
        try await PlaybackService.resolve(for: channel)
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

  /// Keeps the player on the master playlist for video qualities so caption
  /// tracks remain discoverable. We bias ABR with preferredPeakBitRate.
  private func applyQualityPreference(_ option: String) {
    guard let playback else { return }

    if option == "Auto" {
      switchToMasterItemIfNeeded(playback.master)
      player.currentItem?.preferredPeakBitRate = 0
      return
    }

    guard let match = playback.qualities.first(where: { $0.name == option }) else {
      switchToMasterItemIfNeeded(playback.master)
      player.currentItem?.preferredPeakBitRate = 0
      return
    }

    if match.isAudioOnly {
      player.replaceCurrentItem(with: makeItem(url: match.url))
      player.currentItem?.preferredPeakBitRate = 0
      startPlayback()
      return
    }

    switchToMasterItemIfNeeded(playback.master)
    let targetBitrate = match.bitrate > 0 ? Double(match.bitrate) * 1.08 : 0
    player.currentItem?.preferredPeakBitRate = targetBitrate
  }

  private func switchToMasterItemIfNeeded(_ masterURL: URL) {
    guard let asset = player.currentItem?.asset as? AVURLAsset else {
      player.replaceCurrentItem(with: makeItem(url: masterURL))
      startPlayback()
      return
    }

    guard asset.url != masterURL else { return }
    player.replaceCurrentItem(with: makeItem(url: masterURL))
    startPlayback()
  }

  private func makeItem(url: URL) -> AVPlayerItem {
    let asset = AVURLAsset(
      url: url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 1
    applyCaptions(to: item, retries: 12)
    return item
  }

  private var measuredLatencySeconds: Double? {
    liveEdgeLatencySeconds ?? wallClockLatencySeconds
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
      return "Estimated latency \(formatLatencySeconds(seconds))"
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
    // Prefer reliable startup; latency is corrected by explicit catch-up logic.
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
    isPlaybackActive = false
    didRequestPlayback = false
    edgeLatencyLowConfidenceStreak = 0
    wallClockHighLatencyStreak = 0
    wallClockLowConfidenceStreak = 0
    lastPlaybackDateSample = nil
    lastPlaybackTimeSampleSeconds = nil
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
    guard !isLoading, errorMessage == nil, !showQualityPicker, !showCaptionsPicker
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
      } else {
        stalledPlaybackSamples = 0
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
    await load(maxAttempts: 2, reason: reason, resetMetadata: false)
    isRecoveringPlayback = false
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
    guard let metadata = await PlaybackService.channelMetadata(for: channel) else {
      channelDisplayName = channel
      channelAvatarURL = nil
      return
    }
    channelDisplayName = metadata.displayName
    channelAvatarURL = metadata.profileImageURL
    streamTitle = metadata.title
  }

  /// Applies the current captions preference to the active item.
  private func applyCaptions() {
    if let item = player.currentItem { applyCaptions(to: item, retries: 12) }
  }

  private func captionKey(_ option: AVMediaSelectionOption) -> String {
    let language = option.extendedLanguageTag ?? option.locale?.identifier ?? ""
    return "\(language)|\(option.displayName)"
  }

  /// Turns in-band closed captions on or off for a given item. Twitch streams
  /// carry CEA-608 captions in the legible selection group.
  ///
  /// The legible group can appear slightly after playback starts, so we retry
  /// for a short window instead of failing one-shot.
  private func applyCaptions(to item: AVPlayerItem, retries: Int) {
    let wantCaptions = captionsOn
    let preferredCaption = captionSelectionKey
    Task {
      for attempt in 0...retries {
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
          await MainActor.run {
            captionGroup = group
            captionOptions = group.options
            guard !group.options.isEmpty else { return }

            if wantCaptions {
              let preferred =
                group.options.first {
                  captionKey($0) == preferredCaption
                } ?? group.options.first {
                  !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                } ?? group.options.first
              if let option = preferred {
                captionSelectionKey = captionKey(option)
                item.select(option, in: group)
              }
            } else {
              captionSelectionKey = nil
              item.select(nil, in: group)
            }
          }
          return
        }

        if attempt < retries {
          try? await Task.sleep(for: .milliseconds(350))
        }
      }
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

/// A fully custom chat input backed by a `UITextField` so we control the
/// background (clear — no native focus platter) and vertically center the text.
/// SwiftUI's `TextField` on tvOS draws its own opaque focus platter that can't
/// be removed and pins text near the top, which is why we drop down to UIKit.
private struct ChatInputField: UIViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let isFocused: Bool
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
    field.addTarget(
      context.coordinator,
      action: #selector(Coordinator.editingChanged(_:)),
      for: .editingChanged
    )
    return field
  }

  func updateUIView(_ uiView: UITextField, context: Context) {
    if uiView.text != text {
      uiView.text = text
    }

    context.coordinator.allowsEditing = allowsEditing
    context.coordinator.onActivate = onActivate

    // In the focused tvOS state, the system draws a bright field background.
    // Match text and placeholder colors so content remains readable.
    let foreground: UIColor = isFocused ? .black : .white
    let placeholderColor = isFocused
      ? UIColor.black
      : UIColor.white.withAlphaComponent(0.45)

    uiView.textColor = foreground
    uiView.tintColor = foreground
    uiView.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: placeholderColor]
    )
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, allowsEditing: allowsEditing, onActivate: onActivate)
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    private let text: Binding<String>
    var allowsEditing: Bool
    var onActivate: (() -> Void)?

    init(text: Binding<String>, allowsEditing: Bool, onActivate: (() -> Void)?) {
      self.text = text
      self.allowsEditing = allowsEditing
      self.onActivate = onActivate
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
