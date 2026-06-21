import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

extension PlayerView {
  var bottomOverlay: some View {
    VStack(spacing: 18) {
      if rewindAvailable {
        Button {
          toggleRewindPlayPause()
        } label: {
          RewindScrubBar(readout: rewindReadout, isFocused: focus == .rewindScrubber)
        }
        .buttonStyle(ScrubBarButtonStyle())
        // Mutually exclusive focusability with the chat composer: while a chat
        // field is focused the bar removes itself from the focus engine, so a
        // left-press out of chat can't land here (it goes to the collapse
        // button instead). Combined with the composer doing the reverse, the
        // engine never treats the two as neighbors — no sideways escape, no
        // focus flash, no after-the-fact reverts.
        .focusable(scrubberFocusable)
        .focused($focus, equals: .rewindScrubber)
        .accessibilityLabel(rewindReadout.isVOD ? "Timeline" : "Live timeline")
        .accessibilityValue(rewindAccessibilityValue)
        .accessibilityHint("Swipe up or down to seek ten seconds")
        .accessibilityAdjustableAction { direction in
          guard !isScrubbing else { return }
          switch direction {
          case .increment: rewindStep(rewindStepSeconds)
          case .decrement: rewindStep(-rewindStepSeconds)
          @unknown default: break
          }
        }
        .onMoveCommand { direction in
          // Left/right step the timeline. Down drops to the control row (the bar
          // now sits *above* the buttons); up is left to the focus engine.
          switch direction {
          case .left:
            if !isScrubbing { rewindStep(-rewindStepSeconds) }
          case .right:
            if !isScrubbing { rewindStep(rewindStepSeconds) }
          case .down:
            activateControl(.quality)
          default:
            break
          }
        }
        .focusSection()
        .frame(maxWidth: .infinity)
      }

      HStack(alignment: .center, spacing: 24) {
        Button {
          presentChannelPage()
        } label: {
          HStack(spacing: 12) {
            Group {
              if let channelAvatarURL {
                CachedAsyncImage(url: channelAvatarURL) { image in
                  image
                    .resizable()
                    .scaledToFill()
                } placeholder: {
                  ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Icon(glyph: .userCircle, size: 44)
                      .foregroundStyle(.white.opacity(0.85))
                  }
                }
              } else {
                ZStack {
                  Circle().fill(.white.opacity(0.16))
                  Icon(glyph: .userCircle, size: 44)
                    .foregroundStyle(.white.opacity(0.85))
                }
              }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            // Tuck the avatar toward the pill's leading cap so the rounded-left
            // corner stays a crisp, near-equidistant inset around the circle.
            .padding(.leading, -6)

            Text(channelDisplayName.isEmpty ? activeChannel : channelDisplayName)
              .font(.headline)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .TwizzControlButtonStyle()
        .accessibilityLabel("Channel info")
        .accessibilityHint("Opens the channel page")
        // While the viewer is scrolling chat, lift every control-row button out
        // of the focus engine (the scrubber does the same via its
        // `scrubberFocusable` gate). Focus is held on the composer; without this
        // the engine treats these as neighbors and a left press jumps here —
        // flashing a focused button and an audible tick — before our trap reverts
        // it. We remove rather than `.focusable(false/true)`-toggle so the button
        // keeps its own native focus styling when it IS reachable. Exit via Back
        // or by scrolling to the live bottom, which re-enables the row.
        .focusRemoved(controlButtonRemoved(.streamInfo))
        .focused($focus, equals: .streamInfo)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
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
        // Quality / adaptive bitrate is live-only; VODs play a fixed recording.
        if !isVOD {
        QualityMenu(
          options: qualityOptions,
          selectedOption: selectedQualityOption,
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
            // If selecting a (short) sleep timer already surfaced the
            // still-watching banner or the sleeping overlay, don't yank focus
            // back to the quality button — let those own it.
            guard !showStillWatching, !isSleeping else { return }
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
                guard !showStillWatching, !isSleeping else { return }
                guard focus == nil || focus == .quality else { return }
                focus = .quality
              }
            }
          },
          sourceAvailable: youtubeSourceAvailable,
          sourceOptions: streamSourceOptions,
          sourceSelectedIndex: selectedStreamSourceIndex,
          onSelectSource: { selectStreamSource(at: $0) },
          sleepOptions: sleepTimerOptionLabels,
          sleepSelectedIndex: sleepSelectionIndex,
          sleepIsArmed: sleepTimerIsArmed,
          onSelectSleep: { selectSleepTimer(at: $0) },
          rewindEnabled: streamRewindEnabled,
          onToggleRewind: { streamRewindEnabled.toggle() },
          viewerCountEnabled: showViewerCount,
          onToggleViewerCount: { showViewerCount.toggle() },
          captionsSupported: CaptionController.isSupported,
          captionsEnabled: captionsEnabled,
          onToggleCaptions: { captionsEnabled.toggle() },
          onOpenCaptionOptions: { openCaptions() },
          latencyBadgeEnabled: showLatencyBadge,
          onToggleLatencyBadge: { showLatencyBadge.toggle() },
          diagnosticsEnabled: showLatencyDiagnostics,
          onToggleDiagnostics: { showLatencyDiagnostics.toggle() },
          prefetchProxyEnabled: lowLatencyProxyEnabled,
          onTogglePrefetchProxy: { lowLatencyProxyEnabled.toggle() },
          onSimulateOutgoingRaid: { simulateOutgoingRaid() },
          onSimulateIncomingRaid: {
            Task {
              try? await Task.sleep(for: .milliseconds(600))
              simulateIncomingRaid()
            }
          },
          onSimulateOffline: { presentOfflineState() },
          onSimulateMoment: { simulateInteractiveMoment() },
          onSimulateGoLive: {
            Task {
              try? await Task.sleep(for: .milliseconds(600))
              goLive?.simulateGoLive()
            }
          }
        )
        .equatable()
        .focusRemoved(controlButtonRemoved(.quality))
        .focused($focus, equals: .quality)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
        }
        }

        // VODs have no adaptive quality; the same control slot becomes a playback
        // speed cycler. Shares the `.quality` focus tag so existing left/right
        // navigation around it is unchanged.
        if isVOD {
          Button {
            cycleVODSpeed()
          } label: {
            Text(vodSpeedLabel)
              .font(.headline.weight(.semibold))
              .monospacedDigit()
              .frame(minWidth: 52)
              .accessibilityLabel("Playback Speed")
          }
          .focusRemoved(controlButtonRemoved(.quality))
          .focused($focus, equals: .quality)
          .onMoveCommand { direction in
            if direction == .up { requestSeekBarFocus() }
          }
        }

        Button {
          openChatSettingsFromControlBar()
        } label: {
          Icon(glyph: showChatSettings ? .x : .adjustmentsHorizontal)
            .accessibilityLabel("Chat Settings")
        }
        .focusRemoved(controlButtonRemoved(.chatSettingsButton))
        .focused($focus, equals: .chatSettingsButton)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
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
        .focusRemoved(controlButtonRemoved(.chatToggle))
        .focused($focus, equals: .chatToggle)
        .onMoveCommand { direction in
          switch direction {
          case .right:
            stepToChatInput(from: .chatToggle)
          case .up:
            requestSeekBarFocus()
          default:
            break
          }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .TwizzControlButtonStyle()
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: ControlButtonsHeightKey.self,
            value: proxy.size.height
          )
        }
      )
      .focusSection()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onPreferenceChange(ControlButtonsHeightKey.self) { height in
      controlButtonsHeight = height
    }
    // Treat the whole control row (avatar, quality, settings, chat toggle) as one
    // focus section so tvOS keeps focus within it during fast trackpad swipes.
    // Without this, when chat is open the adjacent chat pane (composer, message
    // list) offers competing focus targets and a quick swipe can fling focus out of
    // the row or drop it entirely — which never happens with chat closed.
    .focusSection()
    // Direct the row's initial focus when the chrome is revealed. Because the
    // row is rebuilt on each reveal, this is what actually makes a reveal land
    // on the intended button (set via `pendingControlFocus`) instead of tvOS
    // auto-picking the leftmost control. Dormant when focus is sent into chat.
    .defaultFocus($focus, pendingControlFocus)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 48)
    .padding(.trailing, controlsTrailingInset)
    .padding(.top, 12)
    .padding(.bottom, controlsBottomPadding)
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
  var diagnosticsLines: [String] {
    var lines: [String] = []

    let mode: String
    if lowLatencyProxyEnabled {
      mode = isStreamUnstable ? "LL proxy auto-off (unstable)" : "LL proxy ON"
    } else {
      mode = "LL proxy off"
    }
    let pin = preferredQuality == "Auto" ? "Auto/adaptive" : "\(preferredQuality) (pinned)"
    lines.append("Mode: \(mode) · \(pin)")

    // Stream source readout (moved here from the settings panel). When the
    // YouTube simulcast is active, surface the detailed alt-source proof
    // (real asset host + frame-decode status) so it's visible on the overlay.
    if isUsingAltSource {
      lines.append("Source: YouTube simulcast")
      if let altSourceStatus {
        lines.append("  \(altSourceStatus)")
      }
    } else {
      let avail = youtubeSourceAvailable ? " (YouTube available)" : ""
      lines.append("Source: Twitch\(avail)")
    }
    if isStreamUnstable {
      let trigger = streamUnstableWasPredicted ? "predictive" : "observed"
      lines.append(
        "⚠︎ STABILITY MODE [\(trigger)] (proxy off, deep buffer, riding behind edge)")
    }
    // Surface the predictive instability score whenever the proxy is engaged —
    // both before a trip (watch it climb) and after (the score it had reached when
    // it tripped, so a near-miss "observed" trip is still visible for tuning).
    if lowLatencyProxyEnabled, !isVOD {
      let snap = lowLatencyProxy.instabilityDiagnostics
      if snap.refreshes > 0 {
        var line =
          "Predict: score \(diagFormat(snap.score, decimals: 1))"
          + "/\(diagFormat(LowLatencyHLSProxy.predictedUnstableScoreThreshold, decimals: 1))"
          + " · \(snap.refreshes) refresh\(snap.refreshes == 1 ? "" : "es")"
        if !snap.detail.isEmpty { line += " · \(snap.detail)" }
        lines.append(line)
      }
    }

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
    if diagIsFrozen || videoDecodeFrozenSince != nil {
      let since = [diagFrozenSince, videoDecodeFrozenSince].compactMap { $0 }.min()
      let frozenFor =
        since.map { max(0, Int(Date().timeIntervalSince($0).rounded())) } ?? 0
      let kind = videoDecodeFrozenSince != nil ? "FROZEN video" : "FROZEN"
      lines.append("State: \(kind) (\(frozenFor)s) · Waiting: \(diagWaitingReasonDescription())")
    } else {
      lines.append("State: Playing/waiting · Waiting: \(diagWaitingReasonDescription())")
    }
    lines.append("Edge gap: \(edge) · Encoder: \(wall)")
    if let w = currentSeekWindow() {
      let span = max(w.end - w.start, 0)
      let behind = max(w.end - w.now, 0)
      lines.append(
        "Rewind window: \(diagFormat(span, decimals: 1))s · pos -\(diagFormat(behind, decimals: 1))s")
    } else {
      lines.append("Rewind window: —")
    }
    let dvr = lowLatencyProxy.dvrStats
    lines.append(
      "Proxy DVR: \(diagFormat(dvr.retainedSeconds, decimals: 1))s · keys: \(dvr.keyCount)")
    lines.append("Chat hold: \(chatHold)")
    lines.append(
      "Stalls: \(diagStallCount) · Jumps: \(diagJumpCount) · Reloads: \(diagReloadCount)")

    return lines
  }

  // MARK: - Controls visibility

  /// Left-press target when leaving the chat composer. While the channel is
  /// offline the bottom controls (and `.chatToggle`) aren't rendered — the
  /// offline empty state is shown instead — so revealing controls would focus a
  /// target that doesn't exist and trap focus on the composer. Return to the
  /// offline state's "Try Again" button, which is the control adjacent to the
  /// chat pane, so a subsequent right-press hops straight back into chat.
  func exitChatComposerLeft() {
    // While actively scrolling, the chat list traps focus on the composer
    // (see the `isChatScrolling` focus guard in the body's onChange(of: focus)).
    // A left press here would briefly fling focus to the collapse button —
    // playing a focus tick and flashing the chrome — before the trap snaps it
    // back. Swallow it: the only ways out of an active scroll are Back (Menu)
    // or scrolling down to the live bottom, which returns focus to the composer.
    if isChatScrolling { return }
    if isOffline {
      focus = .offlineTryAgain
    } else {
      revealControls(preferredFocus: .chatToggle)
    }
  }

  func revealControls(preferredFocus: Focusable) {
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

  func hideControls() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    showControls = false
    focus = .video
  }

  func scheduleHide() {
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
        // Keep the controls (and the chat composer beneath them) on screen while
        // chat is frozen for reading or scrolling, so focus stays on the composer
        // and up/down swipes keep driving the scroll instead of hiding the chrome.
        if isChatScrolling || chatSoftPauseRemaining != nil {
          scheduleHide()
          return
        }
        // The settings button now lives in the control bar, so keep the bar up
        // while its panel is open — closing the panel returns focus to it.
        if showChatSettings {
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
  func presentChannelPage() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    if !isVOD {
      stopPlaybackWatchdog()
      stopLatencyMonitor()
    }
    player.pause()
    channelPageTarget = ChannelPageTarget(
      login: activeChannel,
      displayName: channelDisplayName.isEmpty ? activeChannel : channelDisplayName,
      profileImageURL: channelAvatarURL
    )
  }

  /// Resumes live playback once the channel page is dismissed — or switches to a
  /// different channel if the user picked one from the page's "More like this".
  func resumeAfterChannelPage() {
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
    if isVOD {
      player.play()
    } else {
      startPlayback()
      startLatencyMonitor()
      startPlaybackWatchdog()
    }
    if showControls {
      focus = .streamInfo
      scheduleHide()
    } else {
      focus = .video
    }
  }


  func isControlFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .streamInfo, .quality, .chatToggle, .chatInput, .rewindScrubber:
      return true
    default:
      return false
    }
  }

  // FOCUS CONTRACT (tvOS focus here is managed explicitly, not automatically):
  // Every focusable control in the player/chat-settings panel must
  //   (1) have a unique `Focusable` case,
  //   (2) pass it as the control's `focusTag`, and
  //   (3) be registered in this allow-list.
  // A control missing from this switch is unreachable — the focus engine cannot
  // land on it and traps focus on the nearest registered neighbor. When you add
  // a new settings pill, update ALL THREE places (enum case, focusTag, here).
  func isChatSettingsFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .chatSettingsButton,
      .chatPresetOption,
      .chatAdvancedButton,
      .chatWidthOption,
      .chatLayoutOption,
      .chatCaptionsToggle,
      .chatCaptionsBackgroundOption,
      .chatCaptionsColorOption,
      .chatCaptionsOutlineToggle,
      .chatEventsButton,
      .chatRaidEventToggle,
      .chatHypeTrainEventToggle,
      .chatPollEventToggle,
      .chatPredictionEventToggle,
      .chatGoalEventToggle,
      .youtubeMergeToggle,
      .youtubeMergeURL,
      .kickMergeToggle,
      .kickMergeURL,
      .chatAdvancedBack,
      .chatStepperDec,
      .chatStepperInc,
      .chatEmoteAutoToggle,
      .chatAnimatedToggle,
      .chatFontOption,
      .chatBadgesToggle,
      .chatPlatformBadgesToggle,
      .chatHighlightToggle,
      .chatHighlightKeywords,
      .chatResetButton:
      return true
    default:
      return false
    }
  }

  /// Surface style for the docked interactive-moment card, mirroring the chat
  /// list it sits above so it only reads *light* when the chat itself is light
  /// (Side layout under the light theme). Glass/Overlay chat stay dark.
  func momentDockStyle(isGlass: Bool) -> MomentDockStyle {
    switch chatLayoutMode {
    case .glass:
      return MomentDockStyle(surface: .glass)
    case .overlay:
      return MomentDockStyle(surface: .darkOverlay)
    case .side:
      return MomentDockStyle(
        surface: .side(
          surface: palette.chatSideSurface,
          primaryText: palette.chatSidePrimaryText))
    }
  }

}
