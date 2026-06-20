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
    let login = activeChannel
    altSourceStatus = "Resolving YouTube simulcast…"

    if altYouTubeMasterURL == nil {
      var target = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
      if target.isEmpty {
        target = await Self.resolveYouTubeTarget(forTwitchLogin: login)
      }
      guard login == activeChannel, !target.isEmpty else {
        altSourceStatus = "No YouTube link for this channel."
        return
      }
      altYouTubeMasterURL = await AltSourceService.youtubeHLSMaster(forTarget: target)
    }

    guard login == activeChannel else { return }
    guard let master = altYouTubeMasterURL else {
      altSourceStatus = "YouTube simulcast not live / not found."
      return
    }

    isUsingAltSource = true
    stopRateController()
    stopPlaybackWatchdog()
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
}
