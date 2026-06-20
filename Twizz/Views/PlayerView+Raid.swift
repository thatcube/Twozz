import SwiftUI

// Raid banners: the incoming-raid prompt + follow action, and the outgoing-raid
// auto-follow countdown (with simulate/cancel/clear helpers).
extension PlayerView {
  /// A passive, non-interactive banner announcing an *incoming* raid (someone
  /// raiding the channel you're watching). It deliberately has no buttons and
  /// cannot take focus — you're already on the channel being raided, so there's
  /// nothing to follow. The raider's channel avatar is shown alongside, the same
  /// way the go-live toast surfaces who just went live.
  @ViewBuilder
  func raidBanner(_ raid: RaidEvent) -> some View {
    VStack {
      Spacer()
      HStack(spacing: 16) {
        raidAvatar
        VStack(alignment: .leading, spacing: 2) {
          Text("\(raid.displayName) is raiding this channel")
            .font(.headline).bold()
            .foregroundStyle(.primary)
          Text("\(raid.viewerCount) viewers incoming")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      .padding(.leading, 20)
      .padding(.vertical, 20)
      .padding(.trailing, 28)
      .background {
        // Neutral, theme-aware surface (matches the go-live toast) instead of the
        // old fixed purple: an opaque palette surface when transparency is reduced,
        // otherwise native glass. Stays legible in every theme.
        if glassDisabled {
          Capsule().fill(palette.chromeOpaqueSurface)
            .overlay(Capsule().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
        } else if #available(tvOS 26.0, *) {
          Capsule().glassEffect(.regular, in: Capsule())
        } else {
          Capsule().fill(.ultraThinMaterial)
        }
      }
      .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
      .padding(.bottom, 60)
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
  }

  /// The raiding channel's avatar, with a neutral placeholder while it loads.
  private var raidAvatar: some View {
    let size: CGFloat = 72
    return CachedAsyncImage(url: incomingRaidAvatarURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Circle().fill(glassDisabled ? AnyShapeStyle(palette.chromeOpaqueSurface) : AnyShapeStyle(.ultraThinMaterial))
        Icon(glyph: .userPlus, size: size * 0.42)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  /// Whether an incoming raid is worth surfacing, scaled to the size of the
  /// channel you're currently watching. A handful of viewers is exciting on a
  /// tiny stream but pure noise on a huge one, so larger channels require the
  /// raid to bring a meaningful slice of their current audience.
  func shouldShowIncomingRaid(_ raid: RaidEvent) -> Bool {
    // Channels at or below this many concurrent viewers are "small" enough that
    // every raid is meaningful and always shown.
    let smallChannelCeiling = 100
    // On larger channels, a raid must bring at least this fraction of the
    // current audience to clear the bar (e.g. 5% — so a 500-viewer stream needs
    // ~25 incoming, a 250k stream needs ~12.5k).
    let meaningfulFraction = 0.05

    // Unknown audience size (count not resolved yet): show it rather than risk
    // silently dropping a real raid.
    guard let watching = hermes.viewerCount, watching > smallChannelCeiling else {
      return true
    }
    return Double(raid.viewerCount) >= Double(watching) * meaningfulFraction
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
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Raiding to \(raid.toDisplayName)")
            .font(.headline).bold()
            .foregroundStyle(.white)
          Text("Auto-following in \(outgoingRaidSecondsRemaining)s · Cancel to stay here")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
        Button("Cancel") {
          cancelOutgoingRaid()
        }
        .accessibilityHint("Stay on this channel")
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

  /// Debug-only: inject a simulated incoming raid so the banner, its resolved
  /// channel avatar, and the auto-dismiss can be tested without waiting for a
  /// real raid. Uses a large viewer count so it always clears the small-raid
  /// filter regardless of the watched channel's size.
  func simulateIncomingRaid() {
    withAnimation {
      chat.pendingRaid = RaidEvent(
        login: "monstercat",
        displayName: "Monstercat",
        viewerCount: 4200
      )
    }
  }

  func clearOutgoingRaidState() {
    outgoingRaidFollowTask?.cancel()
    outgoingRaidFollowTask = nil
    eventSub.pendingOutgoingRaid = nil
    withAnimation { outgoingRaid = nil }
    outgoingRaidSecondsRemaining = 0
  }
}
