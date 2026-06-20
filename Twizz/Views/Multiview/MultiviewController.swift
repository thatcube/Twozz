import AVKit
import Foundation
import Observation

/// Maximum simultaneous panes. Four matches the multiview convention on other
/// platforms (and is a sane decode/bandwidth ceiling for Apple TV 4K).
let multiviewPaneLimit = 4

/// How the live panes are arranged on screen.
enum MultiviewLayout {
  /// Symmetric tiles (1, side-by-side, 1-big-plus-2, or 2×2).
  case grid
  /// One large primary pane with the rest as a thumbnail filmstrip.
  case spotlight
}

/// Quality budget for a single pane. Each tier pins a *specific* rendition's
/// media playlist (not the master), because pinning is the only thing that makes
/// a quality stick on Twitch/AVPlayer — selecting Source on the master and
/// capping `preferredPeakBitRate` is just a ceiling, so ABR keeps serving a
/// lower rendition. The spotlight primary pins Source; everything else pins a
/// light, low-bitrate rendition.
enum MultiviewQualityTier {
  /// Spotlight primary: the highest "Source" rendition, full sharpness.
  case source
  /// A small tile (grid quadrant or spotlight filmstrip thumbnail): a light,
  /// low-bitrate rendition that stays cheap to decode.
  case light
}

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
  /// Which rendition this pane is currently pinned to. The spotlight primary
  /// pins Source; every other tile pins the light, low-bitrate rendition.
  @ObservationIgnored var qualityTier: MultiviewQualityTier = .light

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
/// channels are dropped. Panes can be added or removed live, and the session can
/// switch between a symmetric grid and a spotlight (one large + filmstrip)
/// arrangement.
@MainActor
@Observable
final class MultiviewController {
  private(set) var panes: [MultiviewPane]
  private(set) var audiblePaneID: String?

  /// Active on-screen arrangement.
  private(set) var layout: MultiviewLayout = .grid
  /// In spotlight mode, the pane shown large. `nil` falls back to the first
  /// pane. Always points at a pane that still exists.
  private(set) var primaryPaneID: String?

  init(channels: [FollowedChannel]) {
    self.panes = channels.prefix(multiviewPaneLimit).map(MultiviewPane.init)
    self.primaryPaneID = panes.first?.id
  }

  /// True when another channel can still be added.
  var canAddPane: Bool { panes.count < multiviewPaneLimit }

  /// The pane currently in the spotlight primary slot (or the first pane).
  var primaryPane: MultiviewPane? {
    panes.first { $0.id == primaryPaneID } ?? panes.first
  }

  /// Resolve and begin playback for every pane.
  func start() {
    syncQualityTiers()
    for pane in panes { load(pane) }
  }

  /// (Re)resolve a single pane's stream and start it muted. Each tier pins a
  /// specific rendition's media playlist: the spotlight primary pins Source for
  /// real sharpness, while small tiles pin a light, low-bitrate rendition so a
  /// 2×2 wall stays cheap. Changing tier swaps the item (a quick reload that the
  /// tile masks with the channel thumbnail), which is the only way to actually
  /// move quality — an ABR ceiling on the master never climbs to Source.
  func load(_ pane: MultiviewPane) {
    pane.isLoading = true
    pane.hasError = false
    pane.resolveTask?.cancel()
    let tier = pane.qualityTier
    pane.resolveTask = Task { [weak pane] in
      guard let pane else { return }
      do {
        let url = switch tier {
        case .source: try await PlaybackService.sourceHLSURL(for: pane.channel.login)
        case .light: try await PlaybackService.lightHLSURL(for: pane.channel.login)
        }
        guard !Task.isCancelled else { return }
        let asset = AVURLAsset(
          url: url,
          options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.0
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

  /// Add a channel as a new pane and start it, if under the pane limit and not
  /// already present. Returns the new pane's id, or `nil` if it was rejected.
  @discardableResult
  func addPane(_ channel: FollowedChannel) -> String? {
    guard canAddPane else { return nil }
    guard !panes.contains(where: { $0.id == channel.id }) else { return nil }
    let pane = MultiviewPane(channel: channel)
    panes.append(pane)
    load(pane)
    return pane.id
  }

  /// Remove a pane, tearing down its player. Keeps at least one pane alive.
  /// Re-points the primary/audible selections if they referenced it.
  func removePane(_ paneID: String) {
    guard panes.count > 1 else { return }
    guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
    let pane = panes[index]
    pane.resolveTask?.cancel()
    pane.resolveTask = nil
    pane.player.pause()
    pane.player.replaceCurrentItem(with: nil)
    panes.remove(at: index)

    if primaryPaneID == paneID {
      primaryPaneID = panes.first?.id
    }
    if audiblePaneID == paneID {
      setAudiblePane(panes.first?.id)
    }
    // The new primary (and the rest) may now warrant a different tier.
    refreshQuality()
  }

  /// Promote a pane to the spotlight primary slot (staying in the current
  /// layout). Use ``spotlight(_:)`` to also switch into spotlight.
  func makePrimary(_ paneID: String) {
    guard panes.contains(where: { $0.id == paneID }) else { return }
    primaryPaneID = paneID
    refreshQuality()
  }

  /// Switch into spotlight with `paneID` as the primary in one step, so the
  /// quality refresh sees the final layout *and* primary together (setting them
  /// separately would refresh while still in grid and miss the upgrade).
  func spotlight(_ paneID: String) {
    guard panes.contains(where: { $0.id == paneID }) else { return }
    primaryPaneID = paneID
    layout = .spotlight
    refreshQuality()
  }

  /// Flip between the grid and spotlight arrangements.
  func toggleLayout() {
    layout = (layout == .grid) ? .spotlight : .grid
    if layout == .spotlight, primaryPane == nil {
      primaryPaneID = panes.first?.id
    }
    refreshQuality()
  }

  /// The tier a pane should run at: only the spotlight primary gets Source;
  /// every other tile (grid quadrant or filmstrip thumbnail) stays light. In
  /// grid mode there is no primary, so all panes are light.
  private func desiredTier(for pane: MultiviewPane) -> MultiviewQualityTier {
    layout == .spotlight && pane.id == primaryPane?.id ? .source : .light
  }

  /// Recompute each pane's desired quality tier without reloading anything.
  private func syncQualityTiers() {
    for pane in panes { pane.qualityTier = desiredTier(for: pane) }
  }

  /// Re-evaluate quality tiers and reload only the panes whose tier changed.
  /// Quality is pinned per rendition, so a change means a different media
  /// playlist — that requires swapping the item. Only the promoted/demoted pane
  /// reloads (the rest keep playing), and the tile masks the swap with the
  /// channel thumbnail so there's no black flash.
  private func refreshQuality() {
    for pane in panes {
      let desired = desiredTier(for: pane)
      guard desired != pane.qualityTier else { continue }
      pane.qualityTier = desired
      load(pane)
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

  /// Pause every pane without releasing its item — used while a single stream
  /// is layered on top (escalated to full-screen), so the wall's audio/video
  /// don't compete and battery isn't wasted decoding hidden video.
  func suspend() {
    for pane in panes { pane.player.pause() }
  }

  /// Resume playback after a suspend, restoring each pane's audible/mute state.
  func resume() {
    for pane in panes {
      pane.player.isMuted = !pane.isAudible
      pane.player.play()
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
