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
    //
    // The stream-stability watchdog can veto promotion at runtime: on a
    // chronically-stalling stream the prefetch promotion is the destabilizer
    // (it shoves the playhead at a live edge the source can't sustain), so while
    // `isStreamUnstable` we drop promotion and — when Rewind isn't holding the
    // proxy on for DVR — detach the proxy entirely and play the plain Twitch
    // playlist, exactly as a manual "LL proxy off" would.
    let promotePrefetch = lowLatencyProxyEnabled && !isStreamUnstable
    let useProxy = promotePrefetch || streamRewindEnabled
    lowLatencyProxy.configure(
      promotePrefetch: promotePrefetch,
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
    // Buffer depth comes from the active profile: shallower for lower latency,
    // deeper to let ABR hold higher quality. (See LivePlaybackPolicy.)
    item.preferredForwardBufferDuration = activeLivePlaybackPolicy.preferredForwardBufferDuration
    // The adaptive-rate controller nudges the live rate a few percent either side
    // of 1.0 (anti-stall slow-down / gentle catch-up); time-domain pitch correction
    // keeps the audio natural through those small changes.
    item.audioTimePitchAlgorithm = .timeDomain
    // Keep refreshing the live playlist while paused so the seekable (rewind)
    // window keeps growing and pause-then-resume stays inside the DVR window.
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    return item
  }

  /// "Behind live" as the viewer actually experiences it: how far behind the real
  /// broadcast the on-screen picture is. That is the wall-clock delay
  /// (`now − EXT-X-PROGRAM-DATE-TIME` at the playhead) — the same value used to
  /// sync chat. It is the honest "glass-to-glass-ish" number; for a Twitch
  /// low-latency stream it lands around ~5-15s.
  ///
  /// We deliberately do NOT lead with the seekable-edge gap. That only measures
  /// the small in-buffer distance to the tail of the playlist we currently hold
  /// (~2-6s), so it collapses toward ~0 whenever the playhead is near the edge —
  /// reading "2s behind" while the picture is really 10-15s behind the broadcast.
  /// The edge gap is kept only as a fallback when no PROGRAM-DATE-TIME is present,
  /// and is still surfaced separately in the Diagnostics overlay.
  var rawLatencySeconds: Double? {
    wallClockLatencySeconds ?? liveEdgeLatencySeconds
  }

  /// Smoothed value actually shown in the UI, to stop the number jumping around.
  var measuredLatencySeconds: Double? {
    smoothedLatencySeconds ?? rawLatencySeconds
  }

  /// True while playback is active but the latency reading hasn't settled yet.
  /// The estimate can read low or jump around for the first samples after a
  /// (re)start, so we wait for it to stabilise (and clear a plausible floor)
  /// before trusting it, with a hard sample cap as a backstop.
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
    startRateController()
  }

  /// Runs the adaptive playback-rate controller on its own fast cadence so the
  /// anti-stall slow-down reacts to a draining buffer well before it empties.
  func startRateController() {
    stopRateController()
    rateControlTask = Task {
      while !Task.isCancelled {
        await MainActor.run {
          applyLiveLatencyCorrection()
        }
        try? await Task.sleep(for: .seconds(rateControlIntervalSeconds))
      }
    }
  }

  func stopRateController() {
    rateControlTask?.cancel()
    rateControlTask = nil
  }

  func stopLatencyMonitor() {
    latencyTask?.cancel()
    latencyTask = nil
    stopRateController()
    latencyReadout.update(color: .gray, label: "Waiting for playback")
    wallClockLatencySeconds = nil
    liveEdgeLatencySeconds = nil
    smoothedLatencySeconds = nil
    latencySampleCount = 0
    latencyStableCount = 0
    isPlaybackActive = false
    didRequestPlayback = false
    edgeLatencyLowConfidenceStreak = 0
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
    lastLiveEdgeSnapAt = Date.distantPast
    liveResyncAttempts = 0
    lastStallNotificationAt = Date.distantPast
    liveStallWaitingSince = nil
    lastLiveEdgeSeconds = nil
    liveEdgeFrozenSince = nil
    softStallSince = nil
    lastSoftStallNudgeAt = Date.distantPast
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

  /// How far the seekable window AVPlayer currently holds trails the *true*
  /// broadcast edge, in seconds: wall-clock behind-live (`now − PROGRAM-DATE-TIME`)
  /// minus the in-window gap to the seekable tail. When this is large the cached
  /// media playlist is stale — seeking to the seekable edge lands well behind real
  /// live, and only a fresh load can reach the true edge. Returns `nil` when either
  /// signal is unavailable.
  func liveWindowStalenessSeconds(_ item: AVPlayerItem) -> Double? {
    guard let date = item.currentDate() else { return nil }
    let wallClock = Date().timeIntervalSince(date)
    guard wallClock.isFinite, wallClock >= 0 else { return nil }
    guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
    let edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
    let current = CMTimeGetSeconds(item.currentTime())
    guard edge.isFinite, current.isFinite, edge > 0 else { return nil }
    let edgeGap = max(0, edge - current)
    return wallClock - edgeGap
  }

  /// When the viewer returns to the live edge but AVPlayer's seekable window is
  /// stale (trailing true live), a same-window seek can't reach the real edge.
  /// Recreate the item so it fetches a fresh playlist and lands at the true
  /// broadcast tail. Stream Rewind history survives because the proxy only clears
  /// its DVR buffers when `retainHistory` actually changes — so this preserves the
  /// ability to rewind while snapping playback back to real live.
  func snapToTrueLiveIfStale() {
    guard !isVOD, pinnedToLive, !isUserPaused, !isScrubbing, !isRecoveringPlayback else {
      return
    }
    guard let item = player.currentItem, let source = currentSourceURL else { return }
    guard let staleness = liveWindowStalenessSeconds(item),
      staleness > staleLiveWindowSnapThresholdSeconds
    else { return }
    let now = Date()
    guard now.timeIntervalSince(lastLiveEdgeSnapAt) >= liveEdgeSnapCooldownSeconds else { return }
    lastLiveEdgeSnapAt = now
    if showLatencyDiagnostics {
      logDiagnosticsEvent("snap to true live (stale \(Int(staleness))s)")
    }
    player.replaceCurrentItem(with: makeItem(url: source))
    startPlayback()
  }

  func samplePlaybackHealth() {
    guard !isLoading, errorMessage == nil, !isOffline
    else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      liveStallWaitingSince = nil
      softStallSince = nil
      return
    }
    // An intentional viewer pause (DVR rewind) holds the playhead in place; that
    // is not a stall, so reset the watchdog counters and bail before they trip.
    // An in-progress scrub holds/repositions the playhead the same way.
    guard !isUserPaused, !isScrubbing else {
      stalledPlaybackSamples = 0
      lastObservedPlaybackTimeSeconds = nil
      liveStallWaitingSince = nil
      softStallSince = nil
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
        // First forward progress of this stream session: anchor the startup-grace
        // window so an immediate stutter trips stability on the very first event.
        if streamPlaybackStartedAt == nil, advanced > 0.05 {
          streamPlaybackStartedAt = Date()
        }
      }

      // An involuntary backward jump (AVPlayer rewinding to refill its buffer) is
      // a strong instability signal. We never seek backward ourselves while
      // chasing live, so any meaningful negative advance here is the source
      // misbehaving — feed it to the stability watchdog alongside stalls.
      if !isVOD, pinnedToLive, advanced <= -diagJumpBackwardThresholdSeconds {
        recordBackwardJumpForStability()
      }
    }

    lastObservedPlaybackTimeSeconds = currentSeconds

    // Live-edge drift recovery. While following live, AVPlayer can involuntarily
    // rewind the playhead far back inside a large (DVR) seekable window to refill
    // its buffer and then resume *playing forward* from there — which the
    // frozen-playhead heuristic above never catches (the playhead is advancing).
    // The viewer is left tens of seconds behind live, slowly playing, forever.
    // Detect that directly from the edge gap and snap back with a light seek —
    // but NOT while in stability mode, where riding behind the edge is the point.
    if !isVOD, pinnedToLive, !isStreamUnstable, let edge = liveSeekableEdgeSeconds(item) {
      let gap = edge - currentSeconds
      if gap.isFinite, gap > liveEdgeResyncThresholdSeconds {
        triggerLiveEdgeResyncIfAllowed(item: item, edge: edge)
      } else if gap.isFinite, gap <= targetLiveEdgeSeconds + 6 {
        // Back near the edge — clear the escalation counter.
        liveResyncAttempts = 0
      }
    }

    // End-of-stream by a frozen live edge. A live broadcast keeps appending
    // segments, so its seekable edge advances; an ended one freezes it. This is
    // independent of the waiting/stall state (which the anti-stall slow-down keeps
    // flickering, so the starvation timer below could otherwise never mature) and
    // works in stability mode too. A merely-struggling stream still advances its
    // edge, so it won't trip this.
    if !isVOD, pinnedToLive {
      let now = Date()
      let edge = liveSeekableEdgeSeconds(item)
      let advanced = edge.map { $0 > (lastLiveEdgeSeconds ?? -.greatestFiniteMagnitude) + 0.5 } ?? false
      if let edge { lastLiveEdgeSeconds = max(lastLiveEdgeSeconds ?? edge, edge) }

      if advanced {
        liveEdgeFrozenSince = nil
      } else if lastLiveEdgeSeconds != nil {
        if liveEdgeFrozenSince == nil { liveEdgeFrozenSince = now }
        let frozenFor = now.timeIntervalSince(liveEdgeFrozenSince ?? now)
        let starved = (bufferAheadSeconds(item) ?? 0) < 1.0
        if frozenFor >= endOfStreamEdgeForceOfflineSeconds, starved {
          // Twitch's status lookup is being unhelpful (returning .unknown) for a
          // clearly-dead stream — don't sit on a frozen frame forever.
          presentOfflineState()
        } else if frozenFor >= endOfStreamEdgeFrozenSeconds {
          probeOfflineIfStreamEnded()
        }
      }
    } else {
      liveEdgeFrozenSince = nil
      lastLiveEdgeSeconds = nil
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

    // Soft-stall deadlock recovery. AVPlayer parks in
    // `.waitingToPlayAtSpecifiedRate` while it actually holds a healthy forward
    // buffer (it is "likely to keep up" and the buffer isn't empty) — the
    // `evaluatingBufferingRate` / `toMinimizeStalls` pathology. Nothing restarts
    // it on its own: the adaptive-rate controller only re-issues a play command
    // when the target rate changes, and here it stays 1.0×, so the playhead creeps
    // and behind-live grows without bound while no buffer-empty hard-stall path
    // applies. Kick it with playImmediately (which bypasses AVPlayer's buffering-
    // rate evaluation and plays the buffered media at once); escalate to a reload
    // if the kicks won't take. Mutually exclusive with isHardStallSignal by
    // construction (that requires an empty/not-likely-to-keep-up buffer).
    let isSoftStallSignal =
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      && !item.isPlaybackBufferEmpty
      && item.isPlaybackLikelyToKeepUp
      && (bufferAheadSeconds(item) ?? 0) >= softStallBufferFloorSeconds
    if isSoftStallSignal {
      let now = Date()
      if softStallSince == nil { softStallSince = now }
      let stuckFor = now.timeIntervalSince(softStallSince ?? now)
      if stuckFor >= softStallReloadSeconds {
        triggerRecoveryIfAllowed(reason: "soft stall deadlock")
        softStallSince = nil
        lastSoftStallNudgeAt = Date.distantPast
      } else if stuckFor >= softStallNudgeSeconds,
        now.timeIntervalSince(lastSoftStallNudgeAt) >= playbackWatchdogIntervalSeconds
      {
        lastSoftStallNudgeAt = now
        player.playImmediately(atRate: desiredLivePlaybackRate(policy: activeLivePlaybackPolicy))
        if showLatencyDiagnostics {
          let buf = bufferAheadSeconds(item).map { diagFormat($0, decimals: 1) } ?? "—"
          logDiagnosticsEvent("soft-stall nudge (buf \(buf)s)")
        }
      }
    } else {
      softStallSince = nil
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
      latencyOutlierStreak = 0
      return
    }
    guard let prev = smoothedLatencySeconds else {
      smoothedLatencySeconds = raw
      latencySampleCount = 1
      latencyStableCount = 0
      latencyOutlierStreak = 0
      return
    }

    // Reject a single wildly-deviating sample (e.g. a momentarily stale
    // PROGRAM-DATE-TIME right after a seek, which can read hundreds of seconds)
    // until it is corroborated by another sample, so a transient spike never
    // flashes on screen. A genuine large change (a real deep rewind) persists and
    // is accepted on the next tick.
    if abs(raw - prev) >= latencyOutlierSeconds {
      latencyOutlierStreak += 1
      if latencyOutlierStreak < latencyOutlierConfirmSamples {
        return
      }
    } else {
      latencyOutlierStreak = 0
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
        applyLiveLatencyCorrection()
      } else {
        liveEdgeLatencySeconds = nil
        edgeLatencyLowConfidenceStreak = 0
      }
    } else {
      liveEdgeLatencySeconds = nil
      edgeLatencyLowConfidenceStreak = 0
      applyLiveLatencyCorrection()
    }
  }

  /// Forward buffer headroom in seconds (how much playable media sits ahead of the
  /// playhead in the range currently being played), or `nil` when unknown.
  func bufferAheadSeconds(_ item: AVPlayerItem?) -> Double? {
    guard let item else { return nil }
    let current = CMTimeGetSeconds(item.currentTime())
    guard current.isFinite else { return nil }
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = CMTimeGetSeconds(range.start)
      let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
      if start.isFinite, end.isFinite, current >= start - 0.5, current <= end + 0.5 {
        return max(0, end - current)
      }
    }
    return nil
  }

  /// Bidirectional adaptive playback-rate control for live, driven by buffer
  /// occupancy (the standard low-latency technique — cf. dash.js `liveCatchup`).
  /// Two arms, anti-stall first:
  ///   • Anti-stall — as the forward buffer drains under the policy floor, ease the
  ///     rate down toward `minPlaybackRate` (~0.90×). Playing slightly slow buys the
  ///     buffer time to refill, so a transient dip is absorbed instead of becoming a
  ///     hard stall (and AVPlayer's jarring "waiting toMinimizeStalls" rebuffer).
  ///   • Catch-up — only when there is healthy buffer headroom *and* we have drifted
  ///     behind the live edge, nudge slightly above 1.0× to drift back. Never used
  ///     to reduce quality, and never while starved.
  /// Returns 1.0× otherwise. A few percent either side of 1.0 is inaudible with
  /// pitch correction (`audioTimePitchAlgorithm`).
  func desiredLivePlaybackRate(policy: LivePlaybackPolicy) -> Float {
    if policy.minPlaybackRate < 1.0,
      let buffer = bufferAheadSeconds(player.currentItem),
      buffer < policy.slowdownBufferFloorSeconds {
      let floor = max(policy.slowdownBufferFloorSeconds, 0.001)
      let fraction = Float(max(0, min(1, buffer / floor)))
      return policy.minPlaybackRate + (1.0 - policy.minPlaybackRate) * fraction
    }

    if policy.enablesGentleCatchUp,
      let gap = liveEdgeLatencySeconds, gap > policy.catchUpThresholdSeconds,
      let buffer = bufferAheadSeconds(player.currentItem),
      buffer > policy.catchUpHealthyBufferSeconds {
      // Proportional catch-up: the further past the target edge gap we are, the
      // faster we chase (capped). Eases back toward 1.0 as we approach the target.
      let excess = Float(gap - policy.catchUpThresholdSeconds)
      let rate = 1.0 + policy.catchUpRampPerSecond * excess
      return min(policy.maxCatchUpRate, rate)
    }

    return 1.0
  }

  /// Applies the adaptive live playback rate without fighting an intentional pause
  /// or an in-progress scrub.
  func applyLiveLatencyCorrection() {
    guard isPlaybackActive else { return }
    guard !isUserPaused, !isScrubbing, !isVOD else { return }

    let previousRate = player.rate
    let targetRate = desiredLivePlaybackRate(policy: activeLivePlaybackPolicy)
    guard abs(previousRate - targetRate) > 0.01 else { return }
    player.playImmediately(atRate: targetRate)

    // Log only when an arm engages/releases (crosses the 1.0 boundary), not on
    // every small ramp step, so the event log stays readable.
    if showLatencyDiagnostics {
      let buffer = bufferAheadSeconds(player.currentItem).map { diagFormat($0, decimals: 1) } ?? "—"
      if previousRate >= 0.99, targetRate < 0.99 {
        logDiagnosticsEvent("slow-down \(diagFormat(Double(targetRate), decimals: 2))× (buf \(buffer)s)")
      } else if previousRate <= 1.0, targetRate > 1.0 {
        logDiagnosticsEvent("catch-up \(diagFormat(Double(targetRate), decimals: 2))× (buf \(buffer)s)")
      } else if previousRate < 0.99, targetRate >= 0.99 {
        logDiagnosticsEvent("rate normal (buf \(buffer)s)")
      }
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
