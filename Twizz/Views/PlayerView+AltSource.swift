import AVKit
import SwiftUI

// Experimental alternate-source playback: swap the live video to a streamer's
// simulcast on another platform (currently YouTube) to compare real on-device
// latency against the proxied Twitch path. Diagnostic-only; toggled from the
// Diagnostics section of the chat settings panel.
extension PlayerView {
  /// Builds a plain AVPlayerItem for an alternate-source master playlist:
  /// no low-latency proxy (the proxy rewrites Twitch playlists / promotes
  /// `#EXT-X-TWITCH-PREFETCH`, which alternate sources don't carry). A browser
  /// User-Agent is attached because googlevideo throttles/blocks AVPlayer's
  /// default tvOS UA — without it the variant playlist and segments never load
  /// and playback stalls on a black frame even though the manifest resolved.
  func makeAltSourceItem(url: URL) -> AVPlayerItem {
    currentSourceURL = url
    let headers = [
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ]
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    return item
  }

  /// Toggles between the Twitch source and the channel's YouTube simulcast.
  func toggleAltYouTubeSource() {
    if isUsingAltSource {
      switchToTwitchSource()
    } else {
      Task { await switchToAltYouTubeSource() }
    }
  }

  /// Resolves the active channel's YouTube simulcast HLS and plays it. Stops the
  /// Twitch-only control loops (edge-chasing rate controller + stall watchdog,
  /// whose recovery would reload the Twitch source) while active; the read-only
  /// latency monitor keeps running so the Diagnostics readout still measures.
  func switchToAltYouTubeSource() async {
    guard !isVOD else { return }
    isUsingAltSource = true
    altFailedRetries = 0
    lastAltResolveAt = Date.distantPast
    stopRateController()
    stopPlaybackWatchdog()
    await resolveAndPlayAltSource(reason: "enable")
  }

  /// (Re)resolves a *fresh* YouTube HLS master and starts playing it. Always
  /// re-fetches the manifest rather than reusing `altYouTubeMasterURL`, because
  /// googlevideo manifest/segment URLs are IP-bound and time-expiring. Heavily
  /// throttled so a 403 can't drive a tight re-resolve loop (which gets the IP
  /// soft-flagged by YouTube's anti-bot).
  func resolveAndPlayAltSource(reason: String) async {
    guard isUsingAltSource, !isVOD else { return }
    guard !altResolveInFlight else { return }
    guard Date().timeIntervalSince(lastAltResolveAt) >= 10 else { return }
    altResolveInFlight = true
    lastAltResolveAt = Date()
    defer { altResolveInFlight = false }

    let login = activeChannel
    altSourceStatus = "Resolving YouTube simulcast…"

    var target = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.isEmpty {
      target = await Self.resolveYouTubeTarget(forTwitchLogin: login)
    }
    guard login == activeChannel, isUsingAltSource else { return }
    guard !target.isEmpty else {
      altSourceStatus = "No YouTube link for this channel."
      return
    }
    youtubeAutoResolvedTarget = target

    let master = await AltSourceService.youtubeHLSMaster(forTarget: target)
    guard login == activeChannel, isUsingAltSource else { return }
    guard let master else {
      altSourceStatus = "YouTube simulcast not live / not found."
      return
    }

    altYouTubeMasterURL = master
    player.replaceCurrentItem(with: makeAltSourceItem(url: master))
    startPlayback()
    altSourceStatus = "Playing YouTube simulcast"
  }

  /// Restores the proxied Twitch source and its control loops.
  func switchToTwitchSource() {
    isUsingAltSource = false
    altSourceStatus = nil
    guard let playback else { return }
    player.replaceCurrentItem(with: makeItem(url: playback.master))
    applyQualityPreference(preferredQuality)
    startPlayback()
    startRateController()
    startPlaybackWatchdog()
  }

  /// Polls the alternate-source item each monitor tick and reports its *real*
  /// state into `altSourceStatus`, so a black screen tells us why: a failed load
  /// (HTTP error / expired googlevideo URL), a stall (segments not arriving), or
  /// genuine playback. Diagnostic-only; runs while the alt source is active.
  func updateAltSourceDiagnostics() {
    guard isUsingAltSource else { return }
    guard let item = player.currentItem else {
      altSourceStatus = "YouTube: no player item"
      return
    }

    switch item.status {
    case .failed:
      let msg = item.error?.localizedDescription ?? "unknown error"
      var detail = "YouTube failed: \(msg)"
      if let last = item.errorLog()?.events.last {
        let code = last.errorStatusCode
        let comment = last.errorComment ?? ""
        detail += " [\(code)\(comment.isEmpty ? "" : " \(comment)")]"
      }
      // googlevideo segment URLs are now PO-token gated and 403 without one. Try
      // a single fresh re-resolve (the first manifest can be a transient dud),
      // then stop — looping re-resolves only gets the IP soft-flagged.
      if altFailedRetries < 1 {
        altFailedRetries += 1
        altSourceStatus = detail + " · retrying once…"
        Task { await resolveAndPlayAltSource(reason: "failed-retry") }
      } else {
        altSourceStatus =
          "YouTube blocked the live segments (HTTP 403). YouTube now requires a "
          + "proof-of-origin token for these streams, so the simulcast path is "
          + "currently unavailable. Switch back to Twitch; re-select YouTube to retry later."
      }
    case .unknown:
      altSourceStatus = "YouTube: loading manifest…"
    case .readyToPlay:
      let ahead = bufferAheadSeconds(item).map { String(format: "%.1fs", $0) } ?? "—"
      let playing = player.timeControlStatus == .playing
      let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      let size = item.presentationSize
      let hasVideo = size.width > 0 && size.height > 0
      if playing, hasVideo {
        altFailedRetries = 0
        altSourceStatus = "Playing YouTube simulcast · buffer \(ahead)"
      } else if playing, !hasVideo {
        altSourceStatus = "YouTube: audio-only? no video track (buffer \(ahead))"
      } else if waiting {
        let why = item.isPlaybackBufferEmpty ? "buffer empty — segments not arriving" : "buffering"
        altSourceStatus = "YouTube waiting: \(why) (buffer \(ahead))"
      } else {
        altSourceStatus = "YouTube ready, paused (buffer \(ahead))"
      }
    @unknown default:
      altSourceStatus = "YouTube: unknown status"
    }
  }
}
