import AVKit
import SwiftUI

// Stream Rewind → in-progress VOD hand-off.
//
// When the viewer rewinds a live stream to the start of the in-memory DVR window
// (`LowLatencyHLSProxy`'s retained history), this continues the rewind seamlessly
// into the channel's in-progress broadcast VOD (Twitch's `RECORDING` archive),
// and hands back to live when they scrub forward to the VOD's recorded edge.
//
// Timeline alignment uses the live playlist's `#EXT-X-PROGRAM-DATE-TIME` (exposed
// via `AVPlayerItem.currentDate()`): a live rewind position's wall-clock instant,
// minus the broadcast's start, is its offset into the VOD — and vice versa.
extension PlayerView {
  /// Wall-clock instant corresponding to an arbitrary player-timeline position,
  /// anchored on the item's PROGRAM-DATE-TIME (`currentDate()` at `currentTime()`).
  /// `nil` when the item carries no date metadata (e.g. a plain VOD without PDT).
  func wallClock(atPlayerTime seconds: Double) -> Date? {
    guard let item = player.currentItem, let anchorDate = item.currentDate() else { return nil }
    let anchor = CMTimeGetSeconds(item.currentTime())
    guard anchor.isFinite, seconds.isFinite else { return nil }
    return RewindVODMapping.wallClock(
      playerTime: seconds, anchorTime: anchor, anchorDate: anchorDate)
  }

  /// Resolves (and caches) the channel's in-progress broadcast VOD the first time
  /// a deep rewind needs it. Returns the cached hand-off once resolved; `nil` when
  /// no VOD is available yet (offline, no past-broadcast storage, sub-only, still
  /// processing), throttled so it can retry later without hammering Twitch.
  func resolveBroadcastVODIfNeeded() async -> LiveVODHandoff? {
    if let liveVODHandoff { return liveVODHandoff }
    guard isLiveSession else { return nil }
    let now = Date()
    guard now.timeIntervalSince(lastBroadcastVODResolveAt) >= broadcastVODResolveCooldownSeconds
    else { return nil }
    lastBroadcastVODResolveAt = now
    guard let broadcast = await PlaybackService.currentBroadcastVOD(for: activeChannel) else {
      return nil
    }
    let title = streamTitle.isEmpty ? channelDisplayName : streamTitle
    let handoff = LiveVODHandoff(broadcast: broadcast, title: title, isActive: false)
    liveVODHandoff = handoff
    return handoff
  }

  /// Forgets any resolved/active hand-off so a new channel session starts fresh.
  /// Called alongside `lowLatencyProxy.resetDVR()` on channel switch / raid.
  func resetVODHandoff() {
    liveVODHandoff = nil
    lastBroadcastVODResolveAt = .distantPast
    vodHandoffTransitionInFlight = false
  }

  // MARK: - Seam detection

  /// Drives both directions of the live↔VOD seam from the scrub path. Called after
  /// the scrub target is computed in `rewindStep` / `handleScrubTick`.
  func checkVODSeamTransitions(
    target: Double, window: (start: Double, end: Double, now: Double)
  ) {
    guard isLiveSession, streamRewindEnabled, !vodHandoffTransitionInFlight else { return }
    if liveVODHandoff?.isActive == true {
      maybeReturnToLive(approaching: target, window: window)
    } else {
      maybeHandOffToVOD(approaching: target, window: window)
    }
  }

  /// While playing live: when the scrub target reaches the DVR floor, capture its
  /// wall-clock instant (from the still-live item) and hand off to the VOD.
  private func maybeHandOffToVOD(
    approaching target: Double, window: (start: Double, end: Double, now: Double)
  ) {
    guard !isVOD else { return }
    guard target <= window.start + vodHandoffFloorThresholdSeconds else { return }
    // Anchor on the floor's wall clock so the VOD picks up exactly where the live
    // history ends, regardless of how far past the floor the swipe overran.
    guard let floorWallClock =
      wallClock(atPlayerTime: max(target, window.start)) ?? wallClock(atPlayerTime: window.start)
    else { return }
    vodHandoffTransitionInFlight = true
    Task { await enterLiveVODHandoff(atWallClock: floorWallClock) }
  }

  /// While in the hand-off VOD: when the scrub target reaches the VOD's recorded
  /// edge, hand back to the live stream.
  private func maybeReturnToLive(
    approaching target: Double, window: (start: Double, end: Double, now: Double)
  ) {
    guard isVOD else { return }
    guard target >= window.end - vodReturnEdgeThresholdSeconds else { return }
    vodHandoffTransitionInFlight = true
    Task { await returnToLiveFromHandoff() }
  }

  // MARK: - Transitions

  /// Live → VOD. Tears down the live-only machinery, swaps the player item to the
  /// in-progress VOD, seeks to the mapped offset, and starts chat replay — without
  /// rebuilding the view, so the transport/chat/layout all carry over.
  func enterLiveVODHandoff(atWallClock wallClock: Date) async {
    defer { vodHandoffTransitionInFlight = false }
    guard let handoff = await resolveBroadcastVODIfNeeded() else { return }
    let broadcast = handoff.broadcast
    let offset = RewindVODMapping.vodOffset(
      forWallClock: wallClock, broadcastStart: broadcast.broadcastStart)

    // Resolve the VOD playlist *before* touching live playback, so that a
    // sub-only / still-processing / unavailable VOD simply leaves the hard DVR
    // floor in place — no teardown, no reload, no lost rewind history.
    guard let url = try? await PlaybackService.vodMasterURL(id: broadcast.id) else { return }

    // Commit: tear down live-only machinery and swap to the VOD.
    teardownLiveForHandoff()
    // Flip into VOD mode (isVOD becomes true → live-only UI/machinery gates off).
    liveVODHandoff?.isActive = true
    streamTitle = handoff.title
    isLoading = true

    let asset = AVURLAsset(
      url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
    currentSourceURL = url
    let item = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: item)
    await seekReadyItem(item, to: offset)
    installVODTimeObserver()
    replay.start(vodID: broadcast.id, channelLogin: channel.isEmpty ? nil : channel)
    replay.update(toOffset: offset)
    scrubTargetSeconds = nil
    isUserPaused = false
    // If the viewer is still mid-swipe, leave playback for `endScrub` to resume so
    // the swap doesn't fight the in-progress scrub.
    if !isScrubbing { resumePlayback() }
    syncCaptions()
    isLoading = false
  }

  /// VOD → live. Tears down the VOD machinery and restarts the live stream near
  /// the true edge (the seam point), restoring live chat / EventSub / monitors.
  func returnToLiveFromHandoff() async {
    guard isLiveSession, liveVODHandoff?.isActive == true else {
      vodHandoffTransitionInFlight = false
      return
    }
    removeVODTimeObserver()
    replay.stop()
    scrubTargetSeconds = nil
    vodPlaybackRate = 1.0
    isUserPaused = false
    pinnedToLive = true
    // Back to live mode (isVOD becomes false).
    liveVODHandoff?.isActive = false
    await restoreLiveAfterHandoff(reason: "vodReturnToLive")
    vodHandoffTransitionInFlight = false
  }

  /// Stops every live-only background task before swapping in the VOD item so they
  /// don't fight VOD playback (latency rate-forcing, stall watchdog, EventSub,
  /// Hermes, IRC chat). Chat replay + the VOD time observer take over.
  private func teardownLiveForHandoff() {
    stopLatencyMonitor()
    stopPlaybackWatchdog()
    eventSub.stop()
    hermes.stop()
    chat.disconnect()
    captionController.stop()
    pinnedToLive = false
  }

  /// Rebuilds the live pipeline and reconnects live chat / EventSub / Hermes, then
  /// reloads the stream near the true edge for a VOD→live return.
  private func restoreLiveAfterHandoff(reason: String) async {
    // The retained DVR history is stale after the time spent in the VOD; start the
    // rewind window fresh from the live edge.
    lowLatencyProxy.resetDVR()
    configurePlayerForLive()
    chat.connect(to: activeChannel)
    eventSub.start(forChannel: activeChannel, auth: auth)
    hermes.start(forChannel: activeChannel)
    await load(reason: reason, resetMetadata: false)
    syncCaptions()
  }

  /// Seeks a freshly-created item once it's ready to play so the seek actually
  /// lands. A loose tolerance keeps it cheap; the seam doesn't need frame accuracy.
  private func seekReadyItem(_ item: AVPlayerItem, to offset: Double) async {
    let deadline = Date().addingTimeInterval(5)
    while item.status != .readyToPlay, Date() < deadline {
      if Task.isCancelled { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
    let time = CMTime(seconds: max(0, offset), preferredTimescale: 600)
    let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
    await item.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
  }
}
