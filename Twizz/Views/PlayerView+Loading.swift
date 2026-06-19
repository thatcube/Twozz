import AVKit
import SwiftUI
import UIKit

// Stream loading, quality application, playback start/latency monitoring, watchdog, stall recovery, offline handling, and channel metadata.
extension PlayerView {
  // MARK: - Loading

  enum LoadTimeoutError: LocalizedError {
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

  func load(maxAttempts: Int = 3, reason: String = "initial", resetMetadata: Bool = true)
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

  func resolvePlaybackWithTimeout() async throws -> StreamPlayback {
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

  func waitForPlaybackStart() async -> Bool {
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
  func applyQualityPreference(_ option: String) {
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
  func switchToSourceIfNeeded(_ url: URL) {
    guard currentSourceURL != url else { return }
    player.replaceCurrentItem(with: makeItem(url: url))
    startPlayback()
  }

  func makeItem(url: URL) -> AVPlayerItem {
    currentSourceURL = url
    // The proxy is attached when EITHER low-latency promotion OR Stream Rewind
    // (DVR retention) is on. Each behavior is independent: promotion pulls the
    // live edge in, retention grows the seekable window for rewind.
    let useProxy = lowLatencyProxyEnabled || streamRewindEnabled
    lowLatencyProxy.configure(
      promotePrefetch: lowLatencyProxyEnabled,
      retainHistory: streamRewindEnabled,
      windowSeconds: rewindWindowSeconds
    )
    let assetURL = useProxy ? lowLatencyProxy.proxyURL(for: url) : url
    let asset = AVURLAsset(
      url: assetURL,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    if useProxy {
      // Promotes Twitch's #EXT-X-TWITCH-PREFETCH segments (which AVPlayer would
      // otherwise ignore) and/or retains seen segments to grow the rewind window.
      asset.resourceLoader.setDelegate(lowLatencyProxy, queue: lowLatencyProxy.callbackQueue)
    }
    let item = AVPlayerItem(asset: asset)
    // Favor smoothness over latency: extra buffer reduces native AVPlayer
    // skip-ahead behavior and rebuffer risk on throughput dips.
    item.preferredForwardBufferDuration = lowLatencyProxyEnabled ? 8 : 3
    // Keep refreshing the live playlist while paused so the seekable (rewind)
    // window keeps growing and pause-then-resume stays inside the DVR window.
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
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
  var rawLatencySeconds: Double? {
    liveEdgeLatencySeconds ?? wallClockLatencySeconds
  }

  /// Smoothed value actually shown in the UI, to stop the number jumping around.
  var measuredLatencySeconds: Double? {
    smoothedLatencySeconds ?? rawLatencySeconds
  }

  /// True while playback is active but the latency reading hasn't settled yet.
  /// The live-edge gap reads ~0 right after playback starts and then climbs to
  /// the real value, so we wait for the number to stabilise (and clear a
  /// plausible floor) before trusting it, with a hard sample cap as a backstop.
  var isLatencyWarmingUp: Bool {
    guard isPlaybackActive else { return false }
    guard let seconds = measuredLatencySeconds else { return true }
    if latencySampleCount >= latencyWarmUpMaxSamples { return false }
    if latencySampleCount < latencyWarmUpMinSamples { return true }
    if seconds < latencyPlausibleFloorSeconds { return true }
    return latencyStableCount < latencyStableSamplesRequired
  }

  var latencyColor: Color {
    guard let seconds = measuredLatencySeconds, !isLatencyWarmingUp else { return .gray }
    if seconds <= 8 { return .green }
    if seconds <= 15 { return .yellow }
    return .orange
  }

  var latencyLabel: String {
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

  func formatLatencySeconds(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    if clamped < 10 {
      let tenths = (clamped * 10).rounded() / 10
      return "\(tenths)s"
    }
    return "\(Int(clamped.rounded()))s"
  }

  func configurePlayerForLive() {
    // Always minimize stalling. Disabling this starves the buffer and caused
    // hard freezes on-device; the latency win comes from the proxy instead.
    player.automaticallyWaitsToMinimizeStalling = true
  }

  func startPlayback() {
    didRequestPlayback = true
    player.playImmediately(atRate: 1.0)
  }

  func startLatencyMonitor() {
    stopLatencyMonitor()
    latencyTask = Task {
      while !Task.isCancelled {
        await MainActor.run {
          updateLatencyMetrics()
          updateResolvedQuality()
          updateSmoothedLatency()
          sampleDiagnostics()
          applyChatSyncSettings()
          // Push the rendered badge values into the observed readout (deduped),
          // so only the badge leaf updates — not the whole player every tick.
          latencyReadout.update(color: latencyColor, label: latencyLabel)
          updateRewindReadout()
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stopLatencyMonitor() {
    latencyTask?.cancel()
    latencyTask = nil
    latencyReadout.update(color: .gray, label: "Waiting for playback")
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

  func startPlaybackWatchdog() {
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

  func stopPlaybackWatchdog() {
    playbackWatchdogTask?.cancel()
    playbackWatchdogTask = nil
    lastObservedPlaybackTimeSeconds = nil
    stalledPlaybackSamples = 0
    isRecoveringPlayback = false
    lastRecoveryAttemptAt = Date.distantPast
    lastLiveResyncAt = Date.distantPast
    liveResyncAttempts = 0
    lastStallNotificationAt = Date.distantPast
    liveStallWaitingSince = nil
    offlineProbeInFlight = false
    lastOfflineProbeAt = Date.distantPast
  }

  func triggerRecoveryIfAllowed(reason: String) {
    guard !isRecoveringPlayback else { return }
    let now = Date()
    guard now.timeIntervalSince(lastRecoveryAttemptAt) >= recoveryCooldownSeconds else {
      return
    }
    lastRecoveryAttemptAt = now
    Task { await recoverFromPlaybackStall(reason: reason) }
  }

  /// Seconds value of the live seekable edge (end of the last seekable range),
  /// or `nil` when no live window exists yet.
  func liveSeekableEdgeSeconds(_ item: AVPlayerItem) -> Double? {
    guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
    let edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
    return edge.isFinite && edge > 0 ? edge : nil
  }

  /// Lightweight recovery for involuntary live-edge drift: seek back toward the
  /// edge and re-kick playback, without the full-reload "jump" that
  /// `recoverFromPlaybackStall` causes. Throttled, and escalates to a full reload
  /// only after repeated resyncs fail to hold the edge.
  func triggerLiveEdgeResyncIfAllowed(item: AVPlayerItem, edge: Double) {
    guard !isRecoveringPlayback, !isUserPaused, !isScrubbing else { return }
    let now = Date()
    guard now.timeIntervalSince(lastLiveResyncAt) >= liveResyncCooldownSeconds else { return }
    lastLiveResyncAt = now

    liveResyncAttempts += 1
    if liveResyncAttempts > maxLiveResyncAttempts {
      // Light seeks aren't sticking — fall back to a full reload.
      liveResyncAttempts = 0
      if showLatencyDiagnostics { logDiagnosticsEvent("edge drift -> reload") }
      triggerRecoveryIfAllowed(reason: "edge drift")
      return
    }

    let target = max(edge - targetLiveEdgeSeconds, 0)
    let tolerance = CMTime(seconds: 0.6, preferredTimescale: 600)
    if showLatencyDiagnostics { logDiagnosticsEvent("live resync (edge drift)") }
    item.seek(
      to: CMTime(seconds: target, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { [self] _ in
      player.playImmediately(atRate: 1.0)
    }
  }

  func samplePlaybackHealth() {
    guard !isLoading, errorMessage == nil, !isOffline
    else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      liveStallWaitingSince = nil
      return
    }
    // An intentional viewer pause (DVR rewind) holds the playhead in place; that
    // is not a stall, so reset the watchdog counters and bail before they trip.
    // An in-progress scrub holds/repositions the playhead the same way.
    guard !isUserPaused, !isScrubbing else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      liveStallWaitingSince = nil
      diagWasStalled = false
      diagIsFrozen = false
      diagFrozenSince = nil
      return
    }
    guard let item = player.currentItem else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      return
    }

    if item.status == .failed {
      triggerRecoveryIfAllowed(reason: "item failed")
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

    // Live-edge drift recovery. While following live, AVPlayer can involuntarily
    // rewind the playhead far back inside a large (DVR) seekable window to refill
    // its buffer and then resume *playing forward* from there — which the
    // frozen-playhead heuristic above never catches (the playhead is advancing).
    // The viewer is left tens of seconds behind live, slowly playing, forever.
    // Detect that directly from the edge gap and snap back with a light seek.
    if !isVOD, pinnedToLive, let edge = liveSeekableEdgeSeconds(item) {
      let gap = edge - currentSeconds
      if gap.isFinite, gap > liveEdgeResyncThresholdSeconds {
        triggerLiveEdgeResyncIfAllowed(item: item, edge: edge)
      } else if gap.isFinite, gap <= targetLiveEdgeSeconds + 6 {
        // Back near the edge — clear the escalation counter.
        liveResyncAttempts = 0
      }
    }

    let isHardStallSignal =
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      && (item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp)
    if stalledPlaybackSamples >= stalledPlaybackThresholdSamples,
      isHardStallSignal,
      let frozenSince = diagFrozenSince,
      Date().timeIntervalSince(frozenSince) >= hardStallRecoverySeconds
    {
      triggerRecoveryIfAllowed(reason: "hard stall")
    }

    // Authoritative end-of-stream detection. The reload-recovery path above is
    // slow and tied to a frozen-playhead heuristic that the once-per-second
    // diagnostics sampler can reset, so an ended broadcast could sit on a frozen
    // last frame indefinitely. Independently, once the player has been unable to
    // play (waiting on a starved buffer) for a few seconds, ask Twitch whether
    // the channel is still live and switch to the offline empty state if not.
    // `.live`/`.unknown` are no-ops, so a transient buffer dip never trips it.
    if isHardStallSignal {
      let now = Date()
      if liveStallWaitingSince == nil { liveStallWaitingSince = now }
      if let since = liveStallWaitingSince,
        now.timeIntervalSince(since) >= offlineProbeStallSeconds
      {
        probeOfflineIfStreamEnded()
      }
    } else {
      liveStallWaitingSince = nil
    }
  }

  /// Authoritatively checks whether the channel is still live and, if it has
  /// gone offline, switches into the offline empty state. Rate-limited and
  /// single-flight so the 2s watchdog (or a play-to-end notification) can call
  /// it freely. Only a definitive `.offline` acts; `.live`/`.unknown` are
  /// ignored so transient network hiccups never surface a false offline screen.
  func probeOfflineIfStreamEnded() {
    let now = Date()
    guard !offlineProbeInFlight,
      now.timeIntervalSince(lastOfflineProbeAt) >= offlineProbeCooldownSeconds
    else { return }
    offlineProbeInFlight = true
    lastOfflineProbeAt = now
    let channel = activeChannel
    Task {
      let status = await PlaybackService.streamLiveStatus(for: channel)
      await MainActor.run {
        offlineProbeInFlight = false
        guard !isOffline, !isUserPaused, !isScrubbing,
          channel == activeChannel
        else { return }
        if status == .offline {
          if showLatencyDiagnostics { logDiagnosticsEvent("offline confirmed (stream ended)") }
          presentOfflineState()
        }
      }
    }
  }

  func recoverFromPlaybackStall(reason: String) async {
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

    if lowLatencyProxyEnabled {
      // Hard-stall failsafe: if low-latency mode reaches a confirmed hard stall,
      // automatically drop back to the stable non-proxy path before reloading.
      suppressLowLatencyToggleReload = true
      lowLatencyProxyEnabled = false
      preferredQuality = "Auto"
      if showLatencyDiagnostics {
        logDiagnosticsEvent("failsafe: low-latency OFF")
      }
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
  /// True while an outgoing raid is pending or its auto-follow countdown is
  /// running. A channel ends its stream the moment it raids, so the offline
  /// empty state must never pre-empt the raid banner during this window.
  var isFollowingOutgoingRaid: Bool {
    outgoingRaid != nil || eventSub.pendingOutgoingRaid != nil
  }

  func presentOfflineState() {
    // Never flash "OFFLINE" while a raid is in flight — the raid banner and its
    // auto-follow take precedence over the offline empty state.
    guard !isFollowingOutgoingRaid else { return }
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
  func retryFromOffline() {
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
  func updateSmoothedLatency() {
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

  func updateLatencyMetrics() {
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
  func applyLiveLatencyCorrection(
    item: AVPlayerItem,
    range: CMTimeRange?,
    wallClockLatency: Double?,
    liveEdgeLatency: Double?
  ) {
    guard isPlaybackActive else { return }
    // Never fight an intentional pause or an in-progress scrub: this monitor runs
    // every tick and force-resetting the rate here would silently resume playback
    // the instant the viewer pauses or starts scrubbing the rewind bar.
    guard !isUserPaused, !isScrubbing else { return }
    // Stability-first policy: do not perform any automatic seeks or rate changes
    // during playback. Those interventions can look like user-visible jumps.
    _ = item
    _ = range
    _ = wallClockLatency
    _ = liveEdgeLatency
    wallClockHighLatencyStreak = 0
    if abs(player.rate - 1.0) > 0.01 {
      player.playImmediately(atRate: 1.0)
    }
  }

  func refreshChannelMetadata() async {
    guard let metadata = await PlaybackService.channelMetadata(for: activeChannel) else {
      channelDisplayName = activeChannel
      channelAvatarURL = nil
      return
    }
    channelDisplayName = metadata.displayName
    channelAvatarURL = metadata.profileImageURL
    // VOD mode keeps the broadcast's own title; only the live player adopts the
    // channel's current stream title here.
    if !isVOD {
      streamTitle = metadata.title
      // Seed the live viewer badge so a number shows immediately; Hermes pubsub
      // takes over with live updates and ignores this seed once it arrives.
      hermes.seedViewerCount(metadata.viewersCount)
    }
  }

  func setIdleTimer(disabled: Bool) {
    UIApplication.shared.isIdleTimerDisabled = disabled
  }
}
