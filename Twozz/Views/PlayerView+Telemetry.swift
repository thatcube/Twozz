import AVFoundation
import Foundation

extension PlayerView {
  private var playbackTelemetrySource: String {
    if isUsingAltSource { return "youtube" }
    if liveVODHandoff?.isActive == true { return "twitch_vod_handoff" }
    if isVOD { return "vod" }
    return "twitch"
  }

  private var playbackTelemetryContext: [String: String] {
    var attributes: [String: String] = [
      "source": model.playbackTelemetry.source,
      "quality": preferredQuality,
      "playback_profile": livePlaybackProfile.rawValue,
    ]
    if (player.currentItem?.presentationSize.width ?? 0) > 0, let resolvedQualityName {
      attributes["resolved_quality"] = resolvedQualityName
    }
    attributes["asset_host"] = PlaybackTelemetryRecorder.host(
      (player.currentItem?.asset as? AVURLAsset)?.url.absoluteString)
    return attributes
  }

  func beginPlaybackTelemetry() {
    lowLatencyProxy.resetTelemetry()
    model.playbackTelemetry.beginSession(
      channel: activeChannel,
      playbackMode: vod == nil ? "live" : "vod",
      attributes: playbackTelemetryContext,
      flags: [
        "low_latency_proxy_enabled": lowLatencyProxyEnabled,
        "stream_rewind_enabled": streamRewindEnabled,
        "prefer_youtube_source": preferYouTubeSource,
      ]
    )
    startPlaybackTelemetrySampling()
  }

  func startPlaybackTelemetrySampling() {
    model.playbackTelemetryTask?.cancel()
    recordPlaybackTelemetrySnapshot()
    model.playbackTelemetryTask = Task { @MainActor [self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        recordPlaybackTelemetrySnapshot()
      }
    }
  }

  func stopPlaybackTelemetry(reason: String) {
    recordPlaybackTelemetrySnapshot()
    model.playbackTelemetryTask?.cancel()
    model.playbackTelemetryTask = nil
    model.playbackTelemetry.endSession(reason: reason)
  }

  func recordPlaybackEvent(
    _ name: String,
    level: PlaybackTelemetryLevel = .info,
    attributes: [String: String] = [:],
    metrics: [String: Double] = [:],
    counters: [String: Int] = [:],
    flags: [String: Bool] = [:]
  ) {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordEvent(
      name,
      level: level,
      attributes: playbackTelemetryContext.merging(attributes) { _, new in new },
      metrics: metrics,
      counters: counters,
      flags: flags
    )
  }

  func recordPlaybackTelemetrySnapshot() {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordItemLogs()
    var snapshot = PlaybackTelemetrySnapshot()
    snapshot.attributes = playbackTelemetryContext
    snapshot.attributes["item_status"] = telemetryItemStatus(player.currentItem?.status)
    snapshot.attributes["time_control_status"] = telemetryTimeControlStatus()
    snapshot.attributes["waiting_reason"] = diagWaitingReasonDescription()
    snapshot.attributes["thermal_state"] = telemetryThermalState()

    snapshot.metrics["player_rate"] = Double(player.rate)
    snapshot.metrics["preferred_forward_buffer_seconds"] =
      player.currentItem?.preferredForwardBufferDuration ?? 0
    if isVOD {
      snapshot.metrics["desired_vod_rate"] = Double(vodPlaybackRate)
    } else if !isUsingAltSource {
      snapshot.metrics["desired_live_rate"] = Double(desiredLivePlaybackRate(policy: activeLivePlaybackPolicy))
    }

    snapshot.flags["loading"] = isLoading
    snapshot.flags["offline"] = isOffline
    snapshot.flags["playback_active"] = player.currentItem != nil && isPlaybackActive
    snapshot.flags["playback_requested"] = player.currentItem != nil && didRequestPlayback
    snapshot.flags["user_paused"] = isUserPaused
    snapshot.flags["scrubbing"] = isScrubbing || scrubTargetSeconds != nil
    snapshot.flags["background"] = backgroundedAt != nil
    snapshot.flags["pinned_to_live"] = pinnedToLive
    snapshot.flags["recovering"] = isRecoveringPlayback
    snapshot.flags["stream_unstable"] = isStreamUnstable
    snapshot.flags["decode_frozen"] = videoDecodeFrozenSince.map {
      Date().timeIntervalSince($0) >= 4
    } ?? false
    snapshot.flags["video_output_observed"] = model.playbackTelemetry.videoFrameAge != nil
    snapshot.metrics["video_frame_age_seconds"] = model.playbackTelemetry.videoFrameAge
    snapshot.flags["using_alt_source"] = isUsingAltSource
    snapshot.flags["low_latency_proxy_enabled"] = lowLatencyProxyEnabled
    snapshot.flags["stream_rewind_enabled"] = streamRewindEnabled

    snapshot.counters["diagnostic_stalls"] = diagStallCount
    snapshot.counters["diagnostic_jumps"] = diagJumpCount
    snapshot.counters["diagnostic_reloads"] = diagReloadCount

    if let item = player.currentItem {
      let current = CMTimeGetSeconds(item.currentTime())
      if current.isFinite {
        snapshot.metrics["playhead_seconds"] = current
      }
      if let ahead = bufferAheadSeconds(item), ahead.isFinite {
        snapshot.metrics["buffer_ahead_seconds"] = ahead
      }
      let size = item.presentationSize
      if size.width > 0, size.height > 0 {
        snapshot.metrics["presentation_width"] = Double(size.width)
        snapshot.metrics["presentation_height"] = Double(size.height)
      }
      snapshot.flags["buffer_empty"] = item.isPlaybackBufferEmpty
      snapshot.flags["buffer_full"] = item.isPlaybackBufferFull
      snapshot.flags["likely_to_keep_up"] = item.isPlaybackLikelyToKeepUp
      snapshot.counters["loaded_range_count"] = item.loadedTimeRanges.count
      snapshot.counters["seekable_range_count"] = item.seekableTimeRanges.count

      if let loaded = item.loadedTimeRanges.last?.timeRangeValue {
        let start = CMTimeGetSeconds(loaded.start)
        let duration = CMTimeGetSeconds(loaded.duration)
        if start.isFinite { snapshot.metrics["loaded_range_start_seconds"] = start }
        if duration.isFinite { snapshot.metrics["loaded_range_duration_seconds"] = duration }
      }
      if let window = currentSeekWindow() {
        snapshot.metrics["seekable_start_seconds"] = window.start
        snapshot.metrics["seekable_end_seconds"] = window.end
        snapshot.metrics["seekable_duration_seconds"] = window.end - window.start
        if !isVOD, !isUsingAltSource {
          snapshot.metrics["live_edge_gap_seconds"] = max(window.end - window.now, 0)
        }
      }
      if !isVOD, !isUsingAltSource {
        snapshot.metrics["wall_clock_latency_seconds"] = wallClockLatencySeconds
        snapshot.metrics["live_edge_latency_seconds"] = liveEdgeLatencySeconds
        snapshot.metrics["smoothed_latency_seconds"] = smoothedLatencySeconds
      }

      let accesses = item.accessLog()?.events ?? []
      if let access = accesses.last {
        let accessSnapshot = PlaybackTelemetryRecorder.accessSnapshot(access)
        snapshot.metrics.merge(accessSnapshot.metrics) { _, new in new }
        snapshot.counters.merge(accessSnapshot.counters) { _, new in new }
        snapshot.attributes["access_entry"] = String(accesses.count - 1)
      }
      if let error = item.error {
        snapshot.attributes.merge(PlaybackTelemetryRecorder.errorAttributes(error)) { _, new in new }
      }
    }

    if (player.currentItem?.asset as? AVURLAsset)?.url.scheme == LowLatencyHLSProxy.scheme {
      addProxyTelemetry(to: &snapshot)
    }
    model.playbackTelemetry.recordSnapshot(snapshot)
  }

  private func addProxyTelemetry(to snapshot: inout PlaybackTelemetrySnapshot) {
    let proxy = lowLatencyProxy.telemetrySnapshot
    snapshot.attributes["proxy_host"] = proxy.lastHost
    snapshot.metrics["proxy_last_request_ms"] = proxy.lastRequestDurationMilliseconds
    snapshot.metrics["proxy_target_duration_seconds"] = proxy.lastTargetDurationSeconds
    snapshot.metrics["proxy_retained_seconds"] = proxy.retainedSeconds
    snapshot.counters["proxy_requests"] = proxy.requestCount
    snapshot.counters["proxy_failed_requests"] = proxy.failedRequestCount
    snapshot.counters["proxy_cancelled_requests"] = proxy.cancelledRequestCount
    snapshot.counters["proxy_active_requests"] = proxy.activeRequestCount
    snapshot.counters["proxy_last_status"] = proxy.lastStatusCode
    snapshot.counters["proxy_last_failure_status"] = proxy.lastFailureStatusCode
    snapshot.counters["proxy_last_failure_error_code"] = proxy.lastFailureErrorCode
    snapshot.metrics["proxy_last_failure_uptime_seconds"] = proxy.lastFailureUptime
    snapshot.counters["proxy_last_response_bytes"] = proxy.lastResponseBytes
    snapshot.counters["proxy_media_refreshes"] = proxy.mediaPlaylistRefreshes
    snapshot.counters["proxy_media_sequence"] = proxy.lastMediaSequence
    snapshot.counters["proxy_tail_sequence"] = proxy.lastTailSequence
    snapshot.counters["proxy_segments"] = proxy.lastSegmentCount
    snapshot.counters["proxy_prefetch_segments"] = proxy.lastPrefetchCount
    snapshot.counters["proxy_promoted_prefetch_segments"] = proxy.lastPromotedPrefetchCount
    snapshot.counters["proxy_discontinuities"] = proxy.lastDiscontinuityCount
    snapshot.counters["proxy_retained_segments"] = proxy.retainedSegmentCount
    snapshot.flags["proxy_promotes_prefetch"] = proxy.promotesPrefetch
    snapshot.flags["proxy_retains_history"] = proxy.retainsHistory

    let instability = lowLatencyProxy.instabilityDiagnostics
    snapshot.metrics["proxy_instability_score"] = instability.score
    snapshot.counters["proxy_instability_refreshes"] = instability.refreshes
    snapshot.flags["proxy_predicted_unstable"] = instability.predictedUnstable
    if !instability.detail.isEmpty {
      snapshot.attributes["proxy_instability_reason"] = instability.detail
    }
  }

  func recordCurrentAccessLog() {
    model.playbackTelemetry.trackItem(player.currentItem, source: playbackTelemetrySource)
    model.playbackTelemetry.recordItemLogs()
  }

  func recordCurrentErrorLog() {
    recordCurrentAccessLog()
  }

  func replacePlaybackItem(with item: AVPlayerItem?) {
    model.playbackTelemetry.trackItem(item, source: playbackTelemetrySource)
    player.replaceCurrentItem(with: item)
    if let item {
      let url = (item.asset as? AVURLAsset)?.url
      let usesProxy = url?.scheme == LowLatencyHLSProxy.scheme
      recordPlaybackEvent(
        "player_item_created",
        attributes: ["asset_scheme": url?.scheme ?? "unknown"],
        metrics: ["preferred_forward_buffer_seconds": item.preferredForwardBufferDuration],
        flags: [
          "uses_proxy": usesProxy,
          "promotes_prefetch": usesProxy && lowLatencyProxyEnabled && !isStreamUnstable,
          "retains_history": usesProxy && streamRewindEnabled,
          "stream_unstable": isStreamUnstable,
        ]
      )
    }
  }

  private func telemetryItemStatus(_ status: AVPlayerItem.Status?) -> String {
    switch status {
    case .unknown: "unknown"
    case .readyToPlay: "ready"
    case .failed: "failed"
    case nil: "none"
    @unknown default: "future"
    }
  }

  private func telemetryTimeControlStatus() -> String {
    switch player.timeControlStatus {
    case .paused: "paused"
    case .waitingToPlayAtSpecifiedRate: "waiting"
    case .playing: "playing"
    @unknown default: "future"
    }
  }

  private func telemetryThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "future"
    }
  }
}
