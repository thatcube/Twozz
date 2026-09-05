import AVKit
import SwiftUI

// VOD playback: loads the recorded broadcast, drives chat replay, and keeps the
// seek readout in sync via an AVPlayer periodic time observer. All live-only
// machinery (latency, proxy, EventSub, quality, watchdog) stays disabled.
extension PlayerView {
  /// Loads the recorded broadcast, starts chat replay, and installs the playhead
  /// observer that keeps both the replay and the seek readout in sync. All the
  /// live machinery (latency, proxy, EventSub, quality, watchdog) stays off.
  func startVOD() async {
    guard let vod = activeVOD else { return }
    let loadStartedAt = ProcessInfo.processInfo.systemUptime
    let telemetrySessionID = model.playbackTelemetry.sessionID
    recordPlaybackEvent(
      "vod_load_started",
      attributes: ["vod_id": vod.id]
    )
    isLoading = true
    errorMessage = nil
    isOffline = false
    streamTitle = vod.title
    player.automaticallyWaitsToMinimizeStalling = true
    replay.start(vodID: vod.id, channelLogin: channel.isEmpty ? nil : channel)

    async let metadataTask: Void = refreshChannelMetadata()
    do {
      let url = try await PlaybackService.vodMasterURL(id: vod.id)
      guard telemetrySessionID == model.playbackTelemetry.sessionID else { return }
      // Dismissed mid-resolve: don't resurrect playback on an orphaned AVPlayer.
      if Task.isCancelled {
        player.pause()
        replacePlaybackItem(with: nil)
        return
      }
      let asset = AVURLAsset(
        url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
      currentSourceURL = url
      replacePlaybackItem(with: AVPlayerItem(asset: asset))
      recordPlaybackEvent(
        "vod_item_created",
        attributes: ["source_host": url.host ?? "unknown"]
      )
      installVODTimeObserver()
      startPlayback()
      isLoading = false
      recordPlaybackEvent(
        "vod_load_completed",
        metrics: ["duration_seconds": ProcessInfo.processInfo.systemUptime - loadStartedAt]
      )
    } catch {
      guard telemetrySessionID == model.playbackTelemetry.sessionID else { return }
      errorMessage = "Couldn't load this broadcast."
      isLoading = false
      recordPlaybackEvent(
        "vod_load_failed",
        level: .error,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error),
        metrics: ["duration_seconds": ProcessInfo.processInfo.systemUptime - loadStartedAt]
      )
    }
    _ = await metadataTask
  }

  func installVODTimeObserver() {
    removeVODTimeObserver()
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    vodTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      MainActor.assumeIsolated {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        replay.update(toOffset: seconds)
        updateRewindReadout()
      }
    }
  }

  func removeVODTimeObserver() {
    if let vodTimeObserver {
      player.removeTimeObserver(vodTimeObserver)
    }
    vodTimeObserver = nil
  }

  /// Advances to the next VOD playback speed and applies it immediately when the
  /// recording is actively playing (not paused or mid-scrub).
  func cycleVODSpeed() {
    guard isVOD else { return }
    let options = vodSpeedOptions
    let current = options.firstIndex(of: vodPlaybackRate) ?? options.firstIndex(of: 1.0) ?? 0
    let next = options[(current + 1) % options.count]
    vodPlaybackRate = next
    recordPlaybackEvent(
      "vod_rate_selected",
      metrics: [
        "previous_rate": Double(options[current]),
        "selected_rate": Double(next),
      ]
    )
    if !isUserPaused, !isScrubbing {
      player.rate = next
    }
    updateRewindReadout()
    scheduleHide()
  }
}
