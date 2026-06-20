import AVKit
import Foundation
import Observation

/// Maximum simultaneous panes. Four matches the multiview convention on other
/// platforms (and is a sane decode/bandwidth ceiling for Apple TV 4K).
let multiviewPaneLimit = 4

/// One tile in a multiview grid: a channel bound to its own `AVPlayer`.
///
/// Every pane decodes a *preview-bitrate* HLS variant (the same low-bitrate
/// rendition the Home grid already plays for hover previews), which keeps four
/// concurrent live decodes within the device's budget. Only the focused pane is
/// unmuted; the rest run silently.
@MainActor
@Observable
final class MultiviewPane: Identifiable {
  let id: String
  let channel: FollowedChannel
  @ObservationIgnored let player: AVPlayer

  /// True until the pane's first frame is ready, so the grid can show a
  /// loading state instead of a black tile.
  var isLoading = true
  /// Set when URL resolution or playback fails; surfaces a retry affordance.
  var hasError = false
  /// Whether this pane currently owns audio (mirrors the focused pane).
  var isAudible = false

  @ObservationIgnored fileprivate var resolveTask: Task<Void, Never>?

  init(channel: FollowedChannel) {
    self.id = channel.id
    self.channel = channel
    let player = AVPlayer()
    player.isMuted = true
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    self.player = player
  }
}

/// Owns the set of panes for one multiview session and the single "audible"
/// selection. Created with up to ``multiviewPaneLimit`` channels; extra
/// channels are dropped.
@MainActor
@Observable
final class MultiviewController {
  let panes: [MultiviewPane]
  private(set) var audiblePaneID: String?

  init(channels: [FollowedChannel]) {
    self.panes = channels.prefix(multiviewPaneLimit).map(MultiviewPane.init)
  }

  /// Resolve and begin playback for every pane.
  func start() {
    for pane in panes { load(pane) }
  }

  /// (Re)resolve a single pane's stream URL and start it muted.
  func load(_ pane: MultiviewPane) {
    pane.isLoading = true
    pane.hasError = false
    pane.resolveTask?.cancel()
    pane.resolveTask = Task { [weak pane] in
      guard let pane else { return }
      do {
        let url = try await PlaybackService.previewHLSURL(for: pane.channel.login)
        guard !Task.isCancelled else { return }
        let asset = AVURLAsset(
          url: url,
          options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.0
        item.preferredPeakBitRate = 2_200_000
        pane.player.replaceCurrentItem(with: item)
        pane.player.isMuted = !pane.isAudible
        pane.player.play()

        // Hold the loading state until the first frame is actually decodable so
        // the tile fades in cleanly rather than flashing black.
        for _ in 0..<40 {
          if Task.isCancelled { return }
          if pane.player.currentItem?.status == .readyToPlay { break }
          try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        pane.isLoading = false
      } catch is CancellationError {
        return
      } catch {
        pane.hasError = true
        pane.isLoading = false
      }
    }
  }

  /// Make exactly one pane audible (or none when `paneID` is nil). Audio always
  /// follows the focused pane.
  func setAudiblePane(_ paneID: String?) {
    audiblePaneID = paneID
    for pane in panes {
      let audible = pane.id == paneID
      pane.isAudible = audible
      pane.player.isMuted = !audible
    }
  }

  /// Stop everything and release the player items. Call on disappear.
  func teardown() {
    for pane in panes {
      pane.resolveTask?.cancel()
      pane.resolveTask = nil
      pane.player.pause()
      pane.player.replaceCurrentItem(with: nil)
    }
  }
}
