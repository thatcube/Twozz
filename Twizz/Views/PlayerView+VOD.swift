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
    guard let vod else { return }
    isLoading = true
    errorMessage = nil
    isOffline = false
    streamTitle = vod.title
    player.automaticallyWaitsToMinimizeStalling = true
    replay.start(vodID: vod.id, channelLogin: channel.isEmpty ? nil : channel)

    async let metadataTask: Void = refreshChannelMetadata()
    do {
      let url = try await PlaybackService.vodMasterURL(id: vod.id)
      let asset = AVURLAsset(
        url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
      currentSourceURL = url
      player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
      installVODTimeObserver()
      startPlayback()
      isLoading = false
    } catch {
      errorMessage = "Couldn't load this broadcast."
      isLoading = false
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
}
