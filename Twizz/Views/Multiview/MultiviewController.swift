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

/// Quality budget for a single pane. Every pane plays the *master* playlist (all
/// renditions available in one item), and the tier only sets the live ABR knobs
/// — a bitrate cap plus how deep to buffer. Because nothing is pinned, changing a
/// pane's tier is just a knob change on the already-playing item (no reload), so
/// quality climbs/drops within a few seconds with no interruption. (The dedicated
/// full-screen player is the only place a reload is acceptable.)
enum MultiviewQualityTier {
  /// Full quality: uncapped + deep buffer so ABR climbs to Source. Used by the
  /// spotlight primary AND any focused pane — focusing pre-warms a tile to full
  /// quality so promoting it to the spotlight is instant and sharp.
  case source
  /// A large grid quadrant (2×2 / side-by-side). These tiles are big enough to
  /// look soft on a 4K panel, so they get a generous cap that still guarantees
  /// at least ~720p when bandwidth allows, with a medium buffer.
  case grid
  /// A spotlight filmstrip thumbnail: tiny, so a low-bitrate rendition is plenty.
  case thumbnail

  /// `0` = unlimited (`AVPlayerItem.preferredPeakBitRate` treats 0 as no cap).
  /// The grid cap sits above Twitch's 720p renditions (~3.5 Mbps) so a grid tile
  /// is guaranteed at least 720p, while still trimming the heaviest 1080p60
  /// Source rendition so four concurrent decodes stay within budget.
  var peakBitRate: Double {
    switch self {
    case .source: return 0
    case .grid: return 5_000_000
    case .thumbnail: return 500_000
    }
  }

  /// A deeper forward buffer gives ABR the headroom/confidence to step *up* to a
  /// higher rendition; a shallow one keeps the small tiles light and low-latency.
  var forwardBufferDuration: Double {
    switch self {
    case .source: return 6
    case .grid: return 3
    case .thumbnail: return 1
    }
  }
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
  /// The ABR budget this pane is currently running at. Recomputed from layout,
  /// the spotlight primary, and which pane is focused (focusing pre-warms a tile
  /// to full quality).
  @ObservationIgnored var qualityTier: MultiviewQualityTier = .grid

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

  /// (Re)resolve a single pane's stream and start it muted. Every pane plays the
  /// master playlist so all renditions live in one item; the tier sets the ABR
  /// knobs (cap + buffer). This is only called on first start, retry, or a newly
  /// added pane — a tier *change* afterwards is applied live in
  /// ``refreshQuality`` without a reload.
  func load(_ pane: MultiviewPane) {
    pane.isLoading = true
    pane.hasError = false
    pane.resolveTask?.cancel()
    let tier = pane.qualityTier
    pane.resolveTask = Task { [weak pane] in
      guard let pane else { return }
      do {
        let url = try await PlaybackService.hlsURL(for: pane.channel.login)
        guard !Task.isCancelled else { return }
        let asset = AVURLAsset(
          url: url,
          options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = tier.forwardBufferDuration
        item.preferredPeakBitRate = tier.peakBitRate
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

  /// The tier a pane should run at. Focusing a pane (or it being the spotlight
  /// primary) pre-warms it to full quality so a later spotlight is instant and
  /// sharp. Otherwise large grid quadrants get a generous cap (≥720p) while the
  /// small spotlight filmstrip thumbnails stay light.
  private func desiredTier(for pane: MultiviewPane) -> MultiviewQualityTier {
    if pane.id == focusedPaneID { return .source }
    if layout == .spotlight && pane.id == primaryPane?.id { return .source }
    return layout == .grid ? .grid : .thumbnail
  }

  /// Recompute each pane's desired quality tier without reloading anything.
  private func syncQualityTiers() {
    for pane in panes { pane.qualityTier = desiredTier(for: pane) }
  }

  /// Re-evaluate quality tiers and apply them live. Every pane already holds the
  /// master playlist, so a tier change is just new ABR knobs on the playing
  /// item: lifting the cap and deepening the buffer lets the promoted pane climb
  /// to Source within a few seconds; capping the demoted ones frees the
  /// bandwidth for it to do so. No reload, no interruption. Only a pane that
  /// never started (or errored) falls back to a full load.
  private func refreshQuality() {
    for pane in panes {
      let desired = desiredTier(for: pane)
      guard desired != pane.qualityTier else { continue }
      pane.qualityTier = desired
      if let item = pane.player.currentItem, !pane.hasError {
        item.preferredPeakBitRate = desired.peakBitRate
        item.preferredForwardBufferDuration = desired.forwardBufferDuration
      } else {
        load(pane)
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
