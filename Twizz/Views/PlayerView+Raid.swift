import SwiftUI

// Raid banners: the incoming-raid prompt + follow action, and the outgoing-raid
// auto-follow countdown (with simulate/cancel/clear helpers).
extension PlayerView {
  /// A passive, non-interactive banner announcing an *incoming* raid (someone
  /// raiding the channel you're watching). It deliberately has no buttons and
  /// cannot take focus — you're already on the channel being raided, so there's
  /// nothing to follow.
  @ViewBuilder
  func raidBanner(_ raid: RaidEvent) -> some View {
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

  func followRaid(_ login: String) {
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
    hermes.start(forChannel: login)
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
  func outgoingRaidBanner(_ raid: OutgoingRaidEvent) -> some View {
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
  func beginOutgoingRaidFollow(_ raid: OutgoingRaidEvent) {
    // Don't redirect onto the channel we're already watching.
    guard raid.toLogin.lowercased() != activeChannel.lowercased() else {
      eventSub.pendingOutgoingRaid = nil
      return
    }

    outgoingRaidFollowTask?.cancel()
    // A channel ends its stream the instant it raids, so the offline empty state
    // can flash in during the brief window before this event arrives (the source
    // HLS hits #EXT-X-ENDLIST). Clear it so the raid banner — not "OFFLINE" — is
    // what the viewer sees.
    isOffline = false
    withAnimation {
      outgoingRaid = raid
      outgoingRaidSecondsRemaining = 10
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

  func cancelOutgoingRaid() {
    clearOutgoingRaidState()
    focus = .video
    // Choosing to stay put after a raid usually means the source has already
    // ended its stream. Re-check immediately (bypassing the probe cooldown) so
    // the offline empty state surfaces instead of a frozen last frame.
    lastOfflineProbeAt = .distantPast
    probeOfflineIfStreamEnded()
  }

  /// Debug-only: inject a simulated outgoing raid so the auto-follow flow can be
  /// tested without waiting for a real raid. Targets AlveusSanctuary.
  func simulateOutgoingRaid() {
    showChatSettings = false
    eventSub.pendingOutgoingRaid = OutgoingRaidEvent(
      toLogin: "alveussanctuary",
      toDisplayName: "AlveusSanctuary",
      toBroadcasterID: "",
      viewerCount: 0
    )
  }

  func clearOutgoingRaidState() {
    outgoingRaidFollowTask?.cancel()
    outgoingRaidFollowTask = nil
    eventSub.pendingOutgoingRaid = nil
    withAnimation { outgoingRaid = nil }
    outgoingRaidSecondsRemaining = 0
  }
}
