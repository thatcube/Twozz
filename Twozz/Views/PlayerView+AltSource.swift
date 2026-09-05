import AVKit
import SwiftUI

// Experimental alternate-source playback: swap the live video to a streamer's
// simulcast on another platform (currently YouTube) to compare real on-device
// latency against the proxied Twitch path. Diagnostic-only; toggled from the
// Diagnostics section of the chat settings panel.
extension PlayerView {
  /// HTTP headers for fetching an alternate (YouTube) source. A browser
  /// User-Agent is required because googlevideo throttles/blocks AVPlayer's (and
  /// URLSession's) default tvOS UA — without it the variant playlist and
  /// segments never load. Shared by the player asset and the caption engine so
  /// both pull the YouTube simulcast with the same identity.
  static let altSourceHTTPHeaders = AltSourceService.mediaHTTPHeaders

  /// Builds a plain AVPlayerItem for an alternate-source master playlist:
  /// no low-latency proxy (the proxy rewrites Twitch playlists / promotes
  /// `#EXT-X-TWITCH-PREFETCH`, which alternate sources don't carry). A browser
  /// User-Agent is attached because googlevideo throttles/blocks AVPlayer's
  /// default tvOS UA — without it the variant playlist and segments never load
  /// and playback stalls on a black frame even though the manifest resolved.
  func makeAltSourceItem(url: URL) -> AVPlayerItem {
    currentSourceURL = url
    let asset = AVURLAsset(
      url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": Self.altSourceHTTPHeaders])
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    // Frame tap so the diagnostics readout can prove real decoded video is
    // arriving (not just a "ready" item over a black frame), and confirm it's
    // the alt asset that's rendering.
    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(videoOutput)
    playerItemVideoOutput = videoOutput
    return item
  }

  /// Resolves the active channel's YouTube simulcast HLS and plays it. Stops the
  /// Twitch-only control loops (edge-chasing rate controller + stall watchdog,
  /// whose recovery would reload the Twitch source) while active; the read-only
  /// latency monitor keeps running so the Diagnostics readout still measures.
  func switchToAltYouTubeSource() async {
    guard !isVOD else { return }
    resetAltSourceWork()
    recordPlaybackEvent("source_switch_started", attributes: ["to_source": "youtube"])
    isUsingAltSource = true
    model.didFallbackFromYouTube = false
    lastAltResolveAt = Date.distantPast
    stopRateController()
    stopPlaybackWatchdog()
    startLatencyMonitor()
    let generation = model.altRecovery.generation
    if !(await resolveAndPlayAltSource(reason: "enable")),
      generation == model.altRecovery.generation
    {
      recoverAltSourceIfNeeded(reason: "resolution_failed")
    }
  }

  /// (Re)resolves a *fresh* YouTube HLS master and starts playing it. Always
  /// re-fetches the manifest rather than reusing `altYouTubeMasterURL`, because
  /// googlevideo manifest/segment URLs are IP-bound and time-expiring. Heavily
  /// throttled so a 403 can't drive a tight re-resolve loop (which gets the IP
  /// soft-flagged by YouTube's anti-bot).
  @discardableResult
  func resolveAndPlayAltSource(reason: String) async -> Bool {
    guard isUsingAltSource, !isVOD, !Task.isCancelled else { return false }
    guard !altResolveInFlight else {
      recordPlaybackEvent(
        "alternate_resolve_suppressed",
        attributes: ["reason": reason, "cause": "already_in_flight"]
      )
      return false
    }
    guard Date().timeIntervalSince(lastAltResolveAt) >= 10 else {
      recordPlaybackEvent(
        "alternate_resolve_suppressed",
        attributes: ["reason": reason, "cause": "cooldown"]
      )
      return false
    }
    altResolveInFlight = true
    lastAltResolveAt = Date()
    let telemetrySessionID = model.playbackTelemetry.sessionID
    let generation = model.altRecovery.generation
    defer {
      if generation == model.altRecovery.generation { altResolveInFlight = false }
    }
    let resolveStartedAt = ProcessInfo.processInfo.systemUptime
    recordPlaybackEvent(
      "alternate_resolve_started",
      attributes: AltSourceService.resolverAttributes.merging(
        ["reason": reason, "source": "youtube"]
      ) { _, new in new }
    )

    let login = activeChannel
    altSourceStatus = "Resolving YouTube simulcast…"

    var target = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.isEmpty {
      target = await Self.resolveYouTubeTarget(forTwitchLogin: login)
    }
    guard login == activeChannel, isUsingAltSource,
      telemetrySessionID == model.playbackTelemetry.sessionID,
      generation == model.altRecovery.generation, !Task.isCancelled else { return false }
    guard !target.isEmpty else {
      altSourceStatus = "No YouTube link for this channel."
      recordPlaybackEvent(
        "alternate_resolve_failed",
        level: .warning,
        attributes: ["reason": reason, "cause": "no_channel_mapping"]
      )
      model.altRecovery.noteTerminalFailure()
      return false
    }
    youtubeAutoResolvedTarget = target

    let resolved: AltSourceService.YouTubeLive
    do {
      resolved = try await AltSourceService.youtubeLive(forTarget: target)
    } catch {
      guard login == activeChannel, isUsingAltSource,
        telemetrySessionID == model.playbackTelemetry.sessionID,
        generation == model.altRecovery.generation, !Task.isCancelled else { return false }
      altSourceStatus = error.localizedDescription
      recordPlaybackEvent(
        "alternate_resolve_failed",
        level: .warning,
        attributes: AltSourceService.errorAttributes(error).merging(["reason": reason]) { _, new in new },
        metrics: ["resolve_duration_seconds": ProcessInfo.processInfo.systemUptime - resolveStartedAt]
      )
      model.altRecovery.noteTerminalFailure()
      return false
    }
    guard login == activeChannel, isUsingAltSource,
      telemetrySessionID == model.playbackTelemetry.sessionID,
      generation == model.altRecovery.generation, !Task.isCancelled else { return false }
    youtubeViewerCount = resolved.concurrentViewers
    let master = resolved.hlsMaster

    model.altRecovery.beginItem()
    altYouTubeMasterURL = master
    replacePlaybackItem(with: makeAltSourceItem(url: master))
    // Resolution can finish after the user pauses, scrubs, or backgrounds.
    if shouldPlayAltSource { startPlayback() }
    isLoading = false
    isOffline = false
    errorMessage = nil
    altSourceStatus = "Playing YouTube simulcast"
    recordPlaybackEvent(
      "source_switch_completed",
      attributes: AltSourceService.resolverAttributes.merging([
        "to_source": "youtube",
        "source_host": master.host ?? "unknown",
      ]) { _, new in new },
      metrics: ["resolve_duration_seconds": ProcessInfo.processInfo.systemUptime - resolveStartedAt]
    )
    return true
  }

  /// Restores the proxied Twitch source and its control loops.
  func switchToTwitchSource(refresh: Bool = false) {
    resetAltSourceWork()
    recordPlaybackEvent("source_switch_started", attributes: ["to_source": "twitch"])
    isUsingAltSource = false
    altSourceStatus = nil
    guard let playback, !refresh else {
      let sessionID = model.playbackTelemetry.sessionID
      let generation = model.altRecovery.generation
      Task {
        guard sessionID == model.playbackTelemetry.sessionID,
          generation == model.altRecovery.generation, !isUsingAltSource else { return }
        await load(reason: "switch to Twitch")
      }
      return
    }
    replacePlaybackItem(with: makeItem(url: playback.master))
    applyQualityPreference(preferredQuality)
    if shouldPlayAltSource { startPlayback() }
    startRateController()
    startPlaybackWatchdog()
    recordPlaybackEvent("source_switch_completed", attributes: ["to_source": "twitch"])
  }

  var shouldPlayAltSource: Bool {
    !isUserPaused && !isScrubbing && !isSleeping && backgroundedAt == nil && channelPageTarget == nil
  }

  /// Invalidate asynchronous source work on a deliberate switch or teardown,
  /// including a switch away and back to the same channel/source.
  func resetAltSourceWork() {
    model.altRecoveryTask?.cancel()
    model.altRecoveryTask = nil
    model.altRecovery = AltSourceRecoveryState()
    altResolveInFlight = false
    model.showAltSourceFallbackNotice = false
  }

  func recoverAltSourceIfNeeded(reason: String) {
    guard isUsingAltSource, !isVOD, shouldPlayAltSource,
      !altResolveInFlight, model.altRecoveryTask == nil else { return }
    guard model.altRecovery.canRetry else {
      recordPlaybackEvent(
        "alternate_source_fallback", level: .warning,
        attributes: ["reason": reason, "to_source": "twitch"],
        counters: ["retry_count": model.altRecovery.retryCount]
      )
      model.didFallbackFromYouTube = true
      switchToTwitchSource(refresh: true)
      model.showAltSourceFallbackNotice = true
      return
    }

    let generation = model.altRecovery.generation
    let sessionID = model.playbackTelemetry.sessionID
    let item = player.currentItem
    let delay = AltSourceRecoveryState.retryDelay(sinceLastAttempt: Date().timeIntervalSince(lastAltResolveAt))
    recordPlaybackEvent(
      "alternate_recovery_scheduled", level: .warning,
      attributes: ["reason": reason], metrics: ["retry_delay_seconds": delay]
    )
    model.altRecoveryTask = Task {
      defer {
        if generation == model.altRecovery.generation { model.altRecoveryTask = nil }
      }
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, isUsingAltSource, shouldPlayAltSource,
        generation == model.altRecovery.generation,
        sessionID == model.playbackTelemetry.sessionID, item === player.currentItem else { return }
      guard model.altRecovery.beginRetry() else { return }
      recordPlaybackEvent(
        "alternate_recovery_started", attributes: ["reason": reason],
        counters: ["retry_count": model.altRecovery.retryCount]
      )
      await resolveAndPlayAltSource(reason: "recovery")
      // A failed resolve stays marked; the next monitor tick handles exhaustion.
      // A successful resolve must prove clock progress, not just return a URL.
    }
  }

  var altSourceFallbackNotice: some View {
    Text("YouTube unavailable. Switching to Twitch.")
      .font(.callout)
      .foregroundStyle(glassDisabled ? palette.chromeOnOpaque : .primary)
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
      .background {
        if glassDisabled {
          Capsule().fill(palette.chromeOpaqueSurface)
            .overlay(Capsule().strokeBorder(palette.chromeOpaqueBorder))
        } else {
          Capsule().fill(.regularMaterial)
        }
      }
      .padding(.top, 70)
      .frame(maxHeight: .infinity, alignment: .top)
      .allowsHitTesting(false)
      .task {
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { return }
        model.showAltSourceFallbackNotice = false
      }
  }

  // MARK: - Stream source selection (quality-menu picker)

  /// Ordered source options for the quality menu's Stream Source submenu. The
  /// YouTube row is only meaningful when `youtubeSourceAvailable` is true; the
  /// menu hides the whole submenu otherwise.
  var streamSourceOptions: [String] { ["Twitch", "YouTube"] }

  /// Picker selection index: 0 = Twitch, 1 = YouTube simulcast.
  var selectedStreamSourceIndex: Int { isUsingAltSource ? 1 : 0 }

  /// Applies a Stream Source picker choice, switching the active video source.
  func selectStreamSource(at index: Int) {
    // A picker choice is deliberate intent: record it so the "prefer YouTube"
    // auto-default won't later yank the viewer off the source they chose.
    didManuallySelectSource = true
    let wantYouTube = (index == 1)
    if wantYouTube != isUsingAltSource {
      if wantYouTube {
        Task { await switchToAltYouTubeSource() }
      } else {
        switchToTwitchSource()
      }
    }
    focus = .quality
    scheduleHide()
  }

  /// Probes whether the active channel has a resolvable YouTube simulcast and
  /// updates `youtubeSourceAvailable`. Runs on channel load so the quality
  /// menu only offers the YouTube source when one actually resolves. Best-effort
  /// and read-only; a failure just leaves the source unavailable.
  func refreshYouTubeSourceAvailability() async {
    youtubeSourceAvailable = false
    guard !isVOD else { return }
    let login = activeChannel
    guard !login.isEmpty else { return }

    var target = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.isEmpty {
      target = await Self.resolveYouTubeTarget(forTwitchLogin: login)
    }
    guard login == activeChannel, !target.isEmpty else { return }

    let sessionID = model.playbackTelemetry.sessionID
    let resolved: AltSourceService.YouTubeLive
    do {
      resolved = try await AltSourceService.youtubeLive(forTarget: target)
    } catch {
      guard login == activeChannel, sessionID == model.playbackTelemetry.sessionID,
        !Task.isCancelled else { return }
      recordPlaybackEvent(
        "alternate_availability_failed", level: .warning,
        attributes: AltSourceService.errorAttributes(error)
      )
      return
    }
    guard login == activeChannel, sessionID == model.playbackTelemetry.sessionID,
      !Task.isCancelled else { return }
    youtubeSourceAvailable = true
    youtubeViewerCount = resolved.concurrentViewers

    // With a confirmed simulcast in hand, honor the "prefer YouTube" default by
    // promoting it to the active source. Done here (rather than in `load()`) so
    // it fires the moment availability resolves, even if the Twitch pipeline
    // came up first — yielding a single clean switch instead of a flap.
    await autoSelectYouTubeSourceIfPreferred()
  }

  /// Switches to the YouTube simulcast as the default source when the viewer
  /// prefers it and the active channel has a confirmed live source — unless the
  /// viewer already made a deliberate Stream Source choice for this channel.
  /// Reuses the existing alt-source machinery; non-YouTube channels and VODs are
  /// untouched, and a manual switch (in either direction) is never overridden.
  func autoSelectYouTubeSourceIfPreferred() async {
    guard preferYouTubeSource else { return }
    guard !isVOD else { return }
    guard youtubeSourceAvailable else { return }
    guard !isUsingAltSource else { return }
    guard !didManuallySelectSource else { return }
    guard !model.didFallbackFromYouTube else { return }
    await switchToAltYouTubeSource()
  }

  /// Polls the alternate-source item each monitor tick and reports its *real*
  /// state into `altSourceStatus`, so a black screen tells us why: a failed load
  /// (HTTP error / expired googlevideo URL), a stall (segments not arriving), or
  /// genuine playback. Diagnostic-only; runs while the alt source is active.
  func updateAltSourceDiagnostics() {
    guard isUsingAltSource else { return }
    if player.currentItem?.status == .failed {
      model.altRecovery.noteTerminalFailure()
    }
    if model.altRecovery.needsRecovery(
      clock: CMTimeGetSeconds(player.currentTime()),
      shouldPlay: shouldPlayAltSource && !altResolveInFlight,
      now: ProcessInfo.processInfo.systemUptime
    ) {
      recoverAltSourceIfNeeded(reason: "terminal_error_or_no_progress")
    }
    guard isUsingAltSource else { return }
    guard let item = player.currentItem else {
      altSourceStatus = "ALT: no player item"
      return
    }

    // Ground truth: the host AVPlayer is actually fetching from. googlevideo /
    // youtube = genuinely the YouTube simulcast; anything else (a Twitch CDN or
    // the localhost proxy) means Twitch leaked back in and the label is lying.
    let host = (item.asset as? AVURLAsset)?.url.host ?? "?"
    let isYouTube = host.contains("googlevideo") || host.contains("youtube")
    let srcTag = isYouTube ? "src=YouTube(\(host))" : "src=NOT-YT(\(host))"

    switch item.status {
    case .failed:
      let msg = item.error?.localizedDescription ?? "unknown error"
      var detail = "\(srcTag) failed: \(msg)"
      if let last = item.errorLog()?.events.last {
        let code = last.errorStatusCode
        let comment = last.errorComment ?? ""
        detail += " [\(code)\(comment.isEmpty ? "" : " \(comment)")]"
      }
      altSourceStatus = detail + " · recovering…"
    case .unknown:
      altSourceStatus = "\(srcTag) · loading manifest…"
    case .readyToPlay:
      let ahead = bufferAheadSeconds(item).map { String(format: "%.1fs", $0) } ?? "—"
      let playing = player.timeControlStatus == .playing
      let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      let size = item.presentationSize
      let dims = size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "no-video"
      // Definitive proof a decoded frame is actually available right now — not
      // just an item that claims it's "ready" over a black screen.
      let hasFrame =
        playerItemVideoOutput?.hasNewPixelBuffer(forItemTime: item.currentTime()) ?? false
      let frameTag = hasFrame ? "frame✓" : "frame✗"
      if playing, size.width > 0 {
        altSourceStatus = "PLAYING · \(srcTag) · \(dims) · \(frameTag) · buffer \(ahead)"
      } else if playing {
        altSourceStatus = "AUDIO-ONLY? · \(srcTag) · \(dims) · buffer \(ahead)"
      } else if waiting {
        let why = item.isPlaybackBufferEmpty ? "buffer empty — segments not arriving" : "buffering"
        altSourceStatus = "WAITING (\(why)) · \(srcTag) · \(dims) · buffer \(ahead)"
      } else {
        altSourceStatus = "READY/paused · \(srcTag) · \(dims) · buffer \(ahead)"
      }
    @unknown default:
      altSourceStatus = "\(srcTag) · unknown status"
    }
  }
}
