import AVKit
import SwiftUI

// Stream Rewind (DVR) + precision scrubbing: reads the seekable window, drives
// the rewind readout, and handles stepped/analog seeking and seek commit.
extension PlayerView {
  /// The live `seekableTimeRanges` window the proxy keeps growing as history is
  /// retained. Returns the start/end (seconds, player timeline) of the last
  /// seekable range plus the current playhead, or `nil` when no window exists.
  func currentSeekWindow() -> (start: Double, end: Double, now: Double)? {
    guard let item = player.currentItem,
      let range = item.seekableTimeRanges.last?.timeRangeValue
    else { return nil }
    let start = CMTimeGetSeconds(range.start)
    let duration = CMTimeGetSeconds(range.duration)
    guard start.isFinite, duration.isFinite, duration > 0 else { return nil }
    let end = start + duration
    let now = CMTimeGetSeconds(item.currentTime())
    guard now.isFinite else { return nil }
    return (start, end, min(max(now, start), end))
  }

  /// Mirrors the player's real seekable window into the observed `rewindReadout`
  /// so only the transport bar leaf re-renders (not the whole player) per tick.
  func updateRewindReadout() {
    if isVOD {
      guard let window = currentSeekWindow() else {
        rewindReadout.isVOD = true
        rewindReadout.elapsedSeconds = 0
        rewindReadout.totalSeconds = 0
        rewindReadout.update(
          positionFraction: 0, behindLiveSeconds: 0, windowSeconds: 0,
          isPaused: isUserPaused, isAtLiveEdge: false)
        return
      }
      let span = max(window.end - window.start, 0.001)
      let position = scrubTargetSeconds.map { min(max($0, window.start), window.end) } ?? window.now
      let elapsed = position - window.start
      rewindReadout.isVOD = true
      rewindReadout.elapsedSeconds = elapsed
      rewindReadout.totalSeconds = span
      rewindReadout.update(
        positionFraction: elapsed / span,
        behindLiveSeconds: max(span - elapsed, 0),
        windowSeconds: span,
        isPaused: isUserPaused,
        isAtLiveEdge: false)
      return
    }
    guard streamRewindEnabled, let window = currentSeekWindow() else {
      rewindReadout.update(
        positionFraction: 1, behindLiveSeconds: 0, windowSeconds: 0,
        isPaused: isUserPaused, isAtLiveEdge: true)
      return
    }
    let span = max(window.end - window.start, 0.001)
    // While following live, pin the orb to the right edge and show LIVE rather than
    // tracking the real (segment-quantized) playhead. The furthest-forward point
    // the viewer can reach is `liveCap` (a few seconds behind the true edge), so
    // even mid-swipe, once they're back at that cap we show LIVE — it is as live as
    // playback can get — instead of a residual "-0:04".
    if pinnedToLive, !isUserPaused {
      rewindReadout.update(
        positionFraction: 1, behindLiveSeconds: 0, windowSeconds: span,
        isPaused: false, isAtLiveEdge: true)
      return
    }
    // While scrubbing/stepping the orb tracks the intended position instantly so
    // it feels buttery even though the real seek lags slightly behind.
    let position = scrubTargetSeconds.map { min(max($0, window.start), window.end) } ?? window.now
    let fraction = (position - window.start) / span
    let behind = max(window.end - position, 0)
    rewindReadout.update(
      positionFraction: fraction,
      behindLiveSeconds: behind,
      windowSeconds: span,
      isPaused: isUserPaused,
      isAtLiveEdge: false)
  }

  /// True when the playhead/target sits close enough to the live edge to be
  /// treated as "following live".
  func isNearLiveEdge(_ position: Double, in window: (start: Double, end: Double, now: Double)) -> Bool {
    (window.end - position) <= targetLiveEdgeSeconds + 4
  }

  /// Steps the playhead by `delta` seconds with instant orb feedback and a
  /// coalesced, tolerant seek so the viewer can spam left/right fluidly without
  /// each press triggering a full rebuffer hiccup.
  func rewindStep(_ delta: Double) {
    guard let window = currentSeekWindow() else { return }
    let liveCap = isVOD ? window.end : max(window.end - targetLiveEdgeSeconds, window.start)
    let base = scrubTargetSeconds ?? window.now
    let target = min(max(base + delta, window.start), liveCap)
    if !isVOD { pinnedToLive = target >= liveCap - 0.5 }
    scrubTargetSeconds = target
    updateRewindReadout()
    throttledScrubSeek(to: target)
    scheduleScrubCommit()
    scheduleHide()
  }

  /// Toggles between pausing in place (DVR window keeps growing) and resuming.
  func toggleRewindPlayPause() {
    if isUserPaused {
      isUserPaused = false
      if !isVOD, let window = currentSeekWindow() {
        pinnedToLive = isNearLiveEdge(window.now, in: window)
      }
      player.play()
    } else {
      if !isVOD { pinnedToLive = false }
      isUserPaused = true
      player.pause()
    }
    updateRewindReadout()
    scheduleHide()
  }

  // MARK: - Precision (analog) scrubbing

  /// Begins reading the Siri Remote trackpad as a relative swipe surface while the
  /// rewind bar is focused. The coordinator integrates how far/fast the finger
  /// actually moves (not where it rests) and reports per-frame displacement plus a
  /// momentum tail on release, which we translate into a smooth scrub.
  func startScrubInput() {
    guard rewindAvailable else { return }
    scrubInput.onScrubBegan = { [self] in
      beginScrub()
    }
    scrubInput.onScrubMoved = { [self] deltaUnits in
      handleScrubTick(deltaUnits)
    }
    scrubInput.onScrubEnded = { [self] in
      endScrub()
    }
    scrubInput.start()
  }

  func stopScrubInput() {
    scrubInput.stop()
    scrubInput.onScrubBegan = nil
    scrubInput.onScrubMoved = nil
    scrubInput.onScrubEnded = nil
    if isScrubbing { endScrub() }
  }

  /// A real swipe has started (finger moved past the tap threshold). Pause the
  /// live video entirely so scrubbing never fights playback, and anchor the orb.
  func beginScrub() {
    guard let window = currentSeekWindow() else { return }
    isScrubbing = true
    scrubCommitTask?.cancel()
    hideTask?.cancel()
    if scrubTargetSeconds == nil { scrubTargetSeconds = window.now }
    if !isUserPaused { player.pause() }
  }

  /// The swipe (and any momentum tail) has finished: commit a frame-accurate seek
  /// and resume playback unless the viewer is intentionally paused.
  func endScrub() {
    isScrubbing = false
    if let target = scrubTargetSeconds {
      commitScrubSeek(to: target)
    } else if !isUserPaused {
      player.play()
    }
    scheduleHide()
  }

  /// Applies one frame of swipe/momentum displacement: convert the raw finger
  /// travel (in trackpad units) into timeline seconds *proportional to the current
  /// window*, advance the intended position, move the orb instantly, and issue a
  /// throttled tolerant seek.
  func handleScrubTick(_ deltaUnits: Double) {
    guard let window = currentSeekWindow() else { return }
    let span = max(window.end - window.start, 0.001)
    let deltaSeconds = deltaUnits * (span / scrubFullWindowTravelUnits)
    let liveCap = isVOD ? window.end : max(window.end - targetLiveEdgeSeconds, window.start)
    let base = scrubTargetSeconds ?? window.now
    let target = min(max(base + deltaSeconds, window.start), liveCap)
    if !isVOD { pinnedToLive = target >= liveCap - 0.5 }
    scrubTargetSeconds = target
    updateRewindReadout()
    throttledScrubSeek(to: target)
  }

  /// Coalesced, tolerant seek used during continuous scrubbing/stepping. Cheap and
  /// responsive (loose tolerance) so it can fire many times a second without the
  /// rebuffer hiccup a frame-accurate seek would cause.
  func throttledScrubSeek(to seconds: Double) {
    guard let item = player.currentItem else { return }
    let now = Date()
    guard now.timeIntervalSince(lastScrubSeekAt) >= 0.07 else { return }
    lastScrubSeekAt = now
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
    item.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
  }

  /// Debounced final settle for rapid left/right stepping: once the presses stop,
  /// land a frame-accurate seek and release the intended-position override.
  func scheduleScrubCommit() {
    scrubCommitTask?.cancel()
    scrubCommitTask = Task { [self] in
      try? await Task.sleep(for: .milliseconds(280))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard !isScrubbing, let target = scrubTargetSeconds else { return }
        commitScrubSeek(to: target)
      }
    }
  }

  /// Lands a frame-accurate seek at `seconds`, clears the intended-position
  /// override, and resumes playback (unless the viewer is intentionally paused).
  func commitScrubSeek(to seconds: Double) {
    scrubCommitTask?.cancel()
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.currentItem?.seek(to: time, completionHandler: { [self] _ in
      scrubTargetSeconds = nil
      if !isUserPaused { player.play() }
      updateRewindReadout()
    })
  }
}
