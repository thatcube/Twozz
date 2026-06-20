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

/// Quality budget for a single pane. Each tier *pins* a specific rendition (via
/// `PlaybackService.pinnedHLSURL(targetBitrate:)`) so the quality is guaranteed
/// rather than left to the master playlist's adaptive logic (which only treats a
/// bitrate cap as advisory and routinely serves a softer rendition). Changing a
/// pane's tier is done seamlessly with a make-before-break player swap — the new
/// rendition is fully preloaded on a second player, then hot-swapped in once it's
/// actually rendering — so quality moves with no reload, black flash, or stall.
enum MultiviewQualityTier {
  /// Full "Source" quality. Used by the spotlight primary AND any focused pane —
  /// focusing pre-warms a tile to Source so promoting or opening it is instant
  /// and already sharp.
  case source
  /// A large grid quadrant (2×2 / side-by-side): a ~720p rendition, sharp enough
  /// not to look soft on a 4K panel while keeping four concurrent decodes sane.
  case grid
  /// A spotlight filmstrip thumbnail: a light ~480p rendition, plenty for a tiny
  /// tile and cheap to decode.
  case thumbnail

  /// Target bitrate handed to ``PlaybackService/pinnedHLSURL(for:targetBitrate:)``.
  /// `0` pins the highest "Source" rendition; otherwise the highest rendition at
  /// or below the target is pinned.
  var targetBitrate: Int {
    switch self {
    case .source: return 0
    case .grid: return 3_000_000
    case .thumbnail: return 800_000
    }
  }

  /// How deep to buffer. A pinned rendition never adapts, so this only trades
  /// startup latency for stall resilience; the Source tier buffers a bit deeper.
  var forwardBufferDuration: Double {
    switch self {
    case .source: return 4
    case .grid: return 2.5
    case .thumbnail: return 2
    }
  }
}

/// One tile in a multiview grid: a channel bound to its own `AVPlayer`.
///
/// Every pane plays a *pinned* HLS rendition sized to its role (Source for the
/// spotlight/focused pane, ~720p for grid quadrants, ~480p for filmstrip
/// thumbnails). Quality changes swap `player` for a fully-preloaded one
/// (make-before-break) so the on-screen surface re-binds with no stall. Only the
/// focused pane is unmuted; the rest run silently.
@MainActor
@Observable
final class MultiviewPane: Identifiable {
  let id: String
  let channel: FollowedChannel
  /// The player currently bound to this tile's video surface. Reassigned during a
  /// seamless quality swap, so it's *observed* (not `@ObservationIgnored`) — the
  /// surface re-binds to the new, already-rendering player when it changes.
  private(set) var player: AVPlayer

  /// True until the pane's first frame is ready, so the grid can show a
  /// loading state instead of a black tile.
  var isLoading = true
  /// Set when URL resolution or playback fails; surfaces a retry affordance.
  var hasError = false
  /// Whether this pane currently owns audio (mirrors the focused pane).
  var isAudible = false
  /// The quality tier this pane is currently running at. Recomputed from layout,
  /// the spotlight primary, and which pane is focused (focusing pre-warms a tile
  /// to Source).
  @ObservationIgnored var qualityTier: MultiviewQualityTier = .grid

  @ObservationIgnored fileprivate var resolveTask: Task<Void, Never>?
  /// In-flight make-before-break quality swap, cancelled if superseded.
  @ObservationIgnored fileprivate var upgradeTask: Task<Void, Never>?

  init(channel: FollowedChannel) {
    self.id = channel.id
    self.channel = channel
    self.player = MultiviewPane.makePlayer()
  }

  /// A fresh muted player configured the way every pane player should be.
  static func makePlayer() -> AVPlayer {
    let player = AVPlayer()
    player.isMuted = true
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    return player
  }

  /// Hot-swap in a fully-prepared player (already rendering the new rendition)
  /// and tear down the old one. The surface re-binds because `player` is observed.
  func adopt(_ next: AVPlayer) {
    let old = player
    guard old !== next else { return }
    next.isMuted = !isAudible
    player = next
    old.pause()
    old.replaceCurrentItem(with: nil)
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

  /// The pane that currently holds focus (audio + quality pre-warm follow it).
  /// Retained across transient focus moves to the controls HUD so the last tile
  /// the user was on stays warmed and ready to spotlight.
  @ObservationIgnored private var focusedPaneID: String?

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

  /// Cold-load a pane's pinned rendition into its current player. Used on first
  /// start, retry, or a newly added pane — the tile is already showing its poster
  /// here, so a plain `replaceCurrentItem` is fine. A tier *change* on a pane
  /// that's already playing instead goes through ``swapQuality`` for a seamless,
  /// flash-free transition.
  func load(_ pane: MultiviewPane) {
    pane.isLoading = true
    pane.hasError = false
    pane.resolveTask?.cancel()
    pane.upgradeTask?.cancel()
    let tier = pane.qualityTier
    pane.resolveTask = Task { [weak pane] in
      guard let pane else { return }
      do {
        let url = try await PlaybackService.pinnedHLSURL(
          for: pane.channel.login, targetBitrate: tier.targetBitrate)
        guard !Task.isCancelled else { return }
        let asset = AVURLAsset(
          url: url,
          options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = tier.forwardBufferDuration
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

  /// Seamlessly move a playing pane to its new tier's pinned rendition. A second
  /// player is built on the new rendition and fully preloaded (buffered and
  /// rendering) *before* it's hot-swapped onto the tile, so the picture never
  /// drops to black or stalls — it just sharpens or softens in place. Falls back
  /// to a cold ``load`` if the pane isn't currently playing.
  private func swapQuality(_ pane: MultiviewPane) {
    guard pane.player.currentItem != nil, !pane.hasError, !pane.isLoading else {
      load(pane)
      return
    }
    pane.upgradeTask?.cancel()
    let tier = pane.qualityTier
    pane.upgradeTask = Task { [weak pane] in
      guard let pane else { return }
      // Debounce: while the focus engine is flying across tiles the desired tier
      // churns; only commit a swap once focus settles for a beat.
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, pane.qualityTier == tier else { return }
      do {
        let url = try await PlaybackService.pinnedHLSURL(
          for: pane.channel.login, targetBitrate: tier.targetBitrate)
        guard !Task.isCancelled, pane.qualityTier == tier else { return }
        let asset = AVURLAsset(
          url: url,
          options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = tier.forwardBufferDuration
        let next = MultiviewPane.makePlayer()
        next.replaceCurrentItem(with: item)
        next.isMuted = !pane.isAudible
        next.play()

        // Make-before-break: wait until the new rendition is genuinely rendering
        // so the hot-swap is invisible rather than a momentary blank.
        for _ in 0..<40 {
          if Task.isCancelled || pane.qualityTier != tier {
            next.replaceCurrentItem(with: nil)
            return
          }
          if item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, pane.qualityTier == tier else {
          next.replaceCurrentItem(with: nil)
          return
        }
        pane.adopt(next)
      } catch {
        // Keep the current rendition playing; a failed upgrade is non-fatal.
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
    pane.upgradeTask?.cancel()
    pane.upgradeTask = nil
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

  /// The tier a pane should run at. Focusing a pane (or it being the spotlight
  /// primary) pre-warms it to Source so a later spotlight or full-screen open is
  /// instant and already sharp. Otherwise large grid quadrants get a ~720p
  /// rendition while the small spotlight filmstrip thumbnails stay light (~480p).
  private func desiredTier(for pane: MultiviewPane) -> MultiviewQualityTier {
    if pane.id == focusedPaneID { return .source }
    if layout == .spotlight && pane.id == primaryPane?.id { return .source }
    return layout == .grid ? .grid : .thumbnail
  }

  /// Recompute each pane's desired quality tier (no playback change here).
  private func syncQualityTiers() {
    for pane in panes { pane.qualityTier = desiredTier(for: pane) }
  }

  /// Re-evaluate each pane's tier and seamlessly re-pin any that changed. The
  /// swap preloads the new rendition on a second player and hot-swaps it in once
  /// it's rendering (``swapQuality``), so quality moves with no reload or stall.
  private func refreshQuality() {
    for pane in panes {
      let desired = desiredTier(for: pane)
      guard desired != pane.qualityTier else { continue }
      pane.qualityTier = desired
      swapQuality(pane)
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

  /// Note which pane the focus engine is on so its quality can be pre-warmed to
  /// full Source. `nil` (focus moved to the controls HUD) is ignored so the last
  /// focused tile stays warm and ready to spotlight instantly.
  func setFocusedPane(_ paneID: String?) {
    guard let paneID, focusedPaneID != paneID else { return }
    focusedPaneID = paneID
    refreshQuality()
  }

  /// Pause every pane without releasing its item — used while a single stream
  /// is layered on top (escalated to full-screen), so the wall's audio/video
  /// don't compete and battery isn't wasted decoding hidden video.
  func suspend() {
    for pane in panes {
      pane.upgradeTask?.cancel()
      pane.upgradeTask = nil
      pane.player.pause()
    }
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
      pane.upgradeTask?.cancel()
      pane.upgradeTask = nil
      pane.player.pause()
      pane.player.replaceCurrentItem(with: nil)
    }
  }
}
