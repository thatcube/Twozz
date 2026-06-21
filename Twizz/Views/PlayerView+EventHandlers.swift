import AVKit
import SwiftUI

// Lifecycle and event handlers for the player, factored out of `PlayerView.body`
// so that property stays a short pipeline and each handler group remains a small
// expression the Swift type-checker can solve quickly (one combined modifier
// chain exceeds its budget). Every method applies one cohesive set of modifiers
// to the passed-in content, in the same order as the original single chain.
extension PlayerView {
  /// Incoming/outgoing raid banners and sleep-mode state transitions
  /// (channel-offline auto-sleep and the "still watching" focus pull).
  func raidAndSleepBannerHandlers(_ content: some View) -> some View {
    content
    .onChange(of: chat.pendingRaid) { _, newRaid in
      // Incoming raids (someone raiding the channel you're watching) are purely
      // informational: show a passive banner and auto-dismiss it. We never steal
      // focus or offer to "follow", because following would take you away from
      // the channel that is actually being raided.
      guard let newRaid else {
        incomingRaidAvatarURL = nil
        return
      }
      // Filter out raids too small to matter for the size of the channel you're
      // on (e.g. a 1-viewer raid into a 250k-viewer stream): drop them silently.
      guard shouldShowIncomingRaid(newRaid) else {
        chat.pendingRaid = nil
        return
      }
      // Resolve the raider's channel avatar so the banner can show who's raiding,
      // mirroring the go-live toast. Best-effort: the banner renders immediately
      // with a placeholder and fills in the icon once it arrives.
      incomingRaidAvatarURL = nil
      Task {
        guard let metadata = await PlaybackService.channelMetadata(for: newRaid.login) else { return }
        guard chat.pendingRaid?.login == newRaid.login else { return }
        incomingRaidAvatarURL = metadata.profileImageURL
      }
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
    .onChange(of: goLive?.pending) { _, pending in
      // The bottom "just went live" banner owns focus while it's up (`.goLiveWatch`).
      // When it dismisses (auto-timeout, or after Watch advances the queue to nil),
      // hand focus back to the video so it isn't left on a vanished button. The
      // Watch path also lands on `.video` via followRaid; this covers the timeout.
      if pending == nil, focus == .goLiveWatch {
        focus = .video
      }
    }
    .onChange(of: isOffline) { _, offline in
      // "End of current stream" sleep mode: when the channel goes offline, let
      // the device sleep (the offline empty-state is already shown, so no extra
      // overlay is needed).
      guard offline, sleepUntilStreamEnds else { return }
      sleepUntilStreamEnds = false
      sleepSelectionIndex = 0
      sleepRemainingSeconds = nil
      setIdleTimer(disabled: false)
    }
    .onChange(of: showStillWatching) { _, showing in
      // Pull focus to the "Keep watching" button so an awake viewer can dismiss
      // the pending sleep with a single press. Cancel the quality menu's focus
      // recovery first so it can't yank focus back to the quality button (this
      // matters when a short test timer surfaces the banner right as the menu
      // is still closing).
      if showing {
        focusRecoveryTask?.cancel()
        focus = .sleepKeepWatching
      }
    }
  }

  /// Player start/stop lifecycle: initial VOD/live load, appear/disappear
  /// setup and teardown, and stall / end-of-stream recovery.
  func playbackLifecycleHandlers(_ content: some View) -> some View {
    content
    .task {
      if activeChannel.isEmpty { activeChannel = channel }
      if isVOD {
        await startVOD()
      } else {
        // Don't toast the channel we're already watching.
        goLive?.suppressedLogin = activeChannel
        configurePlayerForLive()
        resetDiagnostics()
        applyExperimentalYouTubeSettings()
        applyExperimentalKickSettings()
        chat.connect(to: activeChannel)
        eventSub.start(forChannel: activeChannel, auth: auth)
        hermes.start(forChannel: activeChannel)
        async let metadataTask: Void = refreshChannelMetadata()
        await load()
        _ = await metadataTask
      }
      focus = .video
    }
    .onAppear {
      setIdleTimer(disabled: true)
      trackpad.start()
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) {
      notification in
      guard let stalledItem = notification.object as? AVPlayerItem else { return }
      guard stalledItem == player.currentItem else { return }
      // Ignore stalls while intentionally paused or scrubbing for DVR rewind.
      guard !isUserPaused, !isScrubbing else { return }
      let now = Date()
      guard now.timeIntervalSince(lastStallNotificationAt) >= stallNotificationDebounceSeconds
      else { return }
      lastStallNotificationAt = now
      markDiagnosticsStall(reason: "AVPlayerItemPlaybackStalled")
      // Re-kick immediately. With automaticallyWaitsToMinimizeStalling the player
      // usually self-resumes once buffered, but an explicit nudge shortens the
      // gap and helps the player that has stalled without auto-resuming.
      player.playImmediately(atRate: 1.0)
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
      notification in
      guard let endedItem = notification.object as? AVPlayerItem else { return }
      guard endedItem == player.currentItem else { return }
      // Ignore while intentionally paused or scrubbing for DVR rewind.
      guard !isUserPaused, !isScrubbing else { return }
      // A live HLS that ends with #EXT-X-ENDLIST plays to the very end and then
      // pauses here on a frozen final frame. Confirm with Twitch and surface the
      // offline empty state instead of leaving the viewer on a dead frame.
      probeOfflineIfStreamEnded()
    }
    .onDisappear {
      hideTask?.cancel()
      focusRecoveryTask?.cancel()
      chatSyncSendClearTask?.cancel()
      outgoingRaidFollowTask?.cancel()
      softPauseTask?.cancel()
      trackpadScrollTask?.cancel()
      chatHoldTask?.cancel()
      trackpad.stop()
      sleepTimerTask?.cancel()
      stopPlaybackWatchdog()
      stopLatencyMonitor()
      stopScrubInput()
      audioLevelMonitor.stop()
      removeVODTimeObserver()
      replay.stop()
      player.pause()
      player.replaceCurrentItem(with: nil)
      captionController.stop()
      chat.disconnect()
      eventSub.stop()
      hermes.stop()
      // Hand go-live suppression back to Home now that no channel is on screen.
      goLive?.suppressedLogin = nil
      setIdleTimer(disabled: false)
    }
  }

  /// Siri Remote input: the Back (menu) button and directional moves that
  /// reveal controls or drive chat scrolling.
  func remoteCommandHandlers(_ content: some View) -> some View {
    content
    .onExitCommand {
      if isSleeping {
        wakeFromSleep()
      } else if isChatScrolling || chatSoftPauseRemaining != nil {
        // Deliberate exit from a chat scroll: land focus on the composer (live)
        // / collapse button (VOD), reasserting past the control row rejoining the
        // focus engine so it can't bounce to the far-side channel button.
        resumeChatLive(restoreFocus: true)
      } else if showChatSettings {
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
      // While actively scrolling with the chrome hidden, route every directional
      // input through the scroll handler (and swallow horizontal) so a stray
      // swipe can't surface the chrome and bump you out of the scroll.
      if !showControls, showChat, isChatScrolling {
        switch direction {
        case .up: handleChatUpPress()
        case .down: handleChatDownPress()
        default: break
        }
        return
      }
      if !showControls {
        // From the bare video (chrome hidden) a directional press surfaces the
        // controls and lands focus deliberately rather than letting the focus
        // engine pick a magnet: up → the middle of the control row
        // (quality/speed), left → the channel button, right → the chat composer
        // (opening chat if it's hidden). Down rejoins an in-progress chat scroll,
        // otherwise it just surfaces the controls. Chat scrolling is only ever
        // *started* from inside chat (an up-press on the composer) — never by a
        // bare up-swipe here, which used to dive straight into the scroll area
        // without ever focusing the input.
        guard !isOffline else {
          scheduleHide()
          return
        }
        switch direction {
        case .up:
          pendingControlFocus = .quality
          revealControls(preferredFocus: .quality)
        case .left:
          pendingControlFocus = .streamInfo
          revealControls(preferredFocus: .streamInfo)
        case .right:
          if !showChat {
            showChat = true
            chatReplayStartMessageID = chat.messages.suffix(chatReplayMessageCount).first?.id
          }
          // Land on the chat composer (already mounted, so this sticks). Point
          // the row's default at the collapse button so a later move into the
          // row from chat is sensible.
          pendingControlFocus = .chatToggle
          revealControls(preferredFocus: chatFocusAnchor)
        case .down where showChat && (isChatScrolling || chatSoftPauseRemaining != nil):
          handleChatDownPress()
        default:
          pendingControlFocus = .quality
          revealControls(preferredFocus: .quality)
        }
      } else {
        scheduleHide()
      }
    }
  }

  /// The focus state machine that keeps tvOS focus on valid targets across
  /// controls, chat, the chat-settings panel, and the rewind scrubber.
  func focusManagementHandler(_ content: some View) -> some View {
    content
    .onChange(of: focus) { oldFocus, newFocus in
      // Disarm the chat-input hop the moment focus is back on a control button, so
      // the composer drops out of the engine again and a plain swipe can't reach it.
      if isControlRowButton(newFocus), chatInputArmed {
        chatInputArmed = false
      }
      // The seek bar is only focusable while requested/held; once focus leaves it
      // (e.g. a down-press back to a control) drop it out of the engine again so
      // it can't be a vertical magnet on the next swipe.
      if oldFocus == .rewindScrubber, newFocus != .rewindScrubber, seekBarRequested {
        seekBarRequested = false
      }
      // Start/stop precision trackpad scrubbing as the rewind bar gains/loses
      // focus. The analog jog (GameController + display link) only runs while the
      // bar is focused so it never competes with normal control navigation.
      if newFocus == .rewindScrubber, oldFocus != .rewindScrubber {
        startScrubInput()
      } else if oldFocus == .rewindScrubber, newFocus != .rewindScrubber {
        stopScrubInput()
      }
      // Track when the composer becomes focused so an up-swipe that rides in on
      // a diagonal move from the chat-toggle button can't accidentally pause.
      if newFocus == .chatInput, oldFocus != .chatInput {
        chatInputFocusedAt = Date()
      }
      // VOD: moving focus into the chat scroller (right off the collapse button)
      // immediately surfaces the paused indicator, and leaving it resumes the
      // replay's auto-scroll — so chat pause/scroll is driven purely by focus.
      if isVOD {
        if newFocus == .chatScroller, oldFocus != .chatScroller {
          chatInputFocusedAt = Date()
          if !isChatScrolling, chatSoftPauseRemaining == nil { startSoftPause() }
        } else if oldFocus == .chatScroller, newFocus != .chatScroller {
          if isChatScrolling || chatSoftPauseRemaining != nil { resumeChatLive() }
        }
      }
      // Keep the swipe target stable while chat is held.
      if isChatScrolling {
        // Active scroll traps focus on the composer so a stray diagonal swipe
        // can't jump to a control and silently end the scroll. The only
        // exception is `.video`, which is the page-level handler that drives
        // scrolling while the chrome is hidden. Exit is via Back or scrolling
        // back to the bottom.
        if let newFocus, newFocus != chatFocusAnchor, newFocus != .video {
          if isBannerFocus(newFocus) {
            // A bottom banner (go-live / outgoing raid) deliberately claimed
            // focus. Don't fight it back to the composer — that would leave the
            // banner unreachable and, worse, strand chat frozen. Resume the live
            // feed so auto-scroll re-enables, and let focus rest on the banner.
            resumeChatLive()
          } else {
            focus = chatFocusAnchor
          }
        }
      } else if chatSoftPauseRemaining != nil {
        // Lightweight read pause: navigating away to a real control (or a bottom
        // banner claiming focus) resumes live so the frozen state can't get stranded.
        if let newFocus, newFocus != chatFocusAnchor,
          isControlFocus(newFocus) || isBannerFocus(newFocus) {
          resumeChatLive()
        }
      }

      if showChatSettings {
        guard let newFocus else {
          focus = chatFocusPin ?? lastChatSettingsFocus
          return
        }

        // A bottom banner (go-live / outgoing raid) may surface over the open
        // settings panel and claim focus. Let it through rather than bouncing it
        // back to the panel's last control.
        if isBannerFocus(newFocus) { return }

        // A control was just activated: defend it against the transient focus
        // jump tvOS performs when toggling an option resizes the panel, which
        // dumps focus onto the section's first focusable (the back button). We
        // only revert that specific spurious target so deliberate navigation to
        // any other control is never fought, and consume the pin after one move.
        if let pin = chatFocusPin, newFocus != pin {
          chatFocusPin = nil
          chatFocusPinTask?.cancel()
          if newFocus == firstChatSettingsFocus {
            focus = pin
            return
          }
        }

        if isChatSettingsFocus(newFocus) {
          lastChatSettingsFocus = newFocus
        } else {
          // Focus landed on something the chat-settings registry doesn't know,
          // so bounce back to the last good control. If you just added a control
          // to the settings panel and it won't hold focus, the cause is almost
          // certainly a missing case in `isChatSettingsFocus(_:)` — this is the
          // recurring trap. Surface it loudly in debug builds.
          #if DEBUG
          if showChatSettings, newFocus != .video {
            print(
              "⚠️ [chat-settings focus] '\(newFocus)' is not registered in "
                + "isChatSettingsFocus(_:), so focus is bouncing off it. Add this "
                + "case to that switch in PlayerView+BottomOverlay.swift."
            )
          }
          #endif
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
  }

  /// React to the experimental YouTube/Kick simulcast merge toggles by
  /// re-resolving the alternate source.
  func simulcastToggleHandlers(_ content: some View) -> some View {
    content
    .onChange(of: experimentalYouTubeMergeEnabled) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: experimentalYouTubeMergeChannelOrURL) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: experimentalKickMergeEnabled) { _, _ in
      applyExperimentalKickSettings()
    }
    .onChange(of: experimentalKickMergeChannelOrURL) { _, _ in
      applyExperimentalKickSettings()
    }
  }

  /// Reset per-channel state when the active channel changes and refresh the
  /// YouTube/Kick auto-resolved simulcast targets for the new channel.
  func channelChangeHandlers(_ content: some View) -> some View {
    content
    .onChange(of: activeChannel) { _, _ in
      // A manual override is scoped to the channel it was entered for; clear it
      // when the channel changes (e.g. following a raid) so it can't leak.
      experimentalYouTubeMergeChannelOrURL = ""
      youtubeAutoResolvedTarget = ""
      // The alternate (YouTube) source is per-channel; drop it on a channel
      // change so a stale simulcast URL can't leak into the next stream.
      isUsingAltSource = false
      altYouTubeMasterURL = nil
      altSourceStatus = nil
      youtubeSourceAvailable = false
      youtubeViewerCount = nil
      // Auto-default vs. manual intent is per-channel: clear the manual flag so
      // the "prefer YouTube" auto-default can apply once on the new channel.
      didManuallySelectSource = false
      experimentalKickMergeChannelOrURL = ""
      kickAutoResolvedTarget = ""
      // The rewind window is per-stream: drop the previous channel's DVR history.
      lowLatencyProxy.resetDVR()
      // …and any resolved/active hand-off into the previous channel's VOD.
      resetVODHandoff()
      isUserPaused = false
      // Keep the go-live watcher from toasting whatever we just switched to.
      goLive?.suppressedLogin = activeChannel
    }
    .task(id: activeChannel) {
      await refreshYouTubeAutoTarget()
    }
    .task(id: activeChannel) {
      await refreshYouTubeSourceAvailability()
    }
    .task(id: activeChannel) {
      await refreshKickAutoTarget()
    }
  }

  /// Rebuild the live playback pipeline when the low-latency proxy or stream
  /// rewind toggles change.
  func playbackPipelineHandlers(_ content: some View) -> some View {
    content
    .onChange(of: lowLatencyProxyEnabled) { _, _ in
      guard !isVOD else { return }
      if suppressLowLatencyToggleReload {
        suppressLowLatencyToggleReload = false
        return
      }
      // Rebuild the asset pipeline so the proxy is attached/detached cleanly.
      configurePlayerForLive()
      Task { await load(reason: "lowLatencyToggle", resetMetadata: false) }
    }
    .onChange(of: streamRewindEnabled) { _, _ in
      guard !isVOD else { return }
      // Toggling Stream Rewind changes whether the proxy retains history (and,
      // when low-latency is off, whether the proxy is attached at all), so
      // rebuild the pipeline from a clean DVR state.
      lowLatencyProxy.resetDVR()
      configurePlayerForLive()
      Task { await load(reason: "rewindToggle", resetMetadata: false) }
    }
  }

  /// Keep the on-device caption engine in sync with playback state and the
  /// active (Twitch vs YouTube) audio source.
  func captionSyncHandlers(_ content: some View) -> some View {
    content
    .onChange(of: captionsEnabled) { _, _ in syncCaptions() }
    .onChange(of: captionsTimingOffset) { _, _ in syncCaptions() }
    .onChange(of: captionAudioSourceURL) { _, _ in syncCaptions() }
    // Switching between the Twitch and YouTube simulcast sources changes which
    // stream's audio the captions must transcribe; re-sync so captions follow
    // the active source (and recover when switching back to Twitch).
    .onChange(of: isUsingAltSource) { _, _ in syncCaptions() }
    .onChange(of: isLoading) { _, _ in syncCaptions() }
    .onChange(of: isOffline) { _, _ in syncCaptions() }
  }
}
