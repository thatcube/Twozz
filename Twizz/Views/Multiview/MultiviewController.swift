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
/// bitrate cap as advisory and routinely serves a softer rendition). A pane's
/// tier is its structural role; changing it re-pins the pane's single player in
/// place (we never run a second concurrent decoder per tile — Apple TV's video
/// decoders are a hard, shared budget).
enum MultiviewQualityTier {
  /// Full "Source" quality. Used only by the spotlight primary (the one large
  /// pane), so the heaviest rendition is decoded at most once at a time.
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
/// spotlight primary, ~720p for grid quadrants, ~480p for filmstrip thumbnails).
/// Each pane keeps a *single* player for its whole lifetime — Apple TV's hardware
/// can only decode so many live streams at once, so we never run a second
/// concurrent player per tile; a quality change re-pins the existing player's
/// item in place. Only the focused pane is unmuted; the rest run silently.
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
  /// The quality tier this pane is currently running at. Recomputed from the
  /// layout and the spotlight primary (a purely structural role).
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

  /// (Re)load a pane's pinned rendition into its single player. Used for the
  /// first start, a retry, a newly added pane, and any quality-tier change. The
  /// tile shows its channel poster while `isLoading` is true, so the brief
  /// re-pin (a `replaceCurrentItem` on the same player) reads as a quick poster
  /// flash rather than a black tile — and never spins up a second concurrent
  /// decoder, which is what the hardware can't afford.
  func load(_ pane: MultiviewPane) {
    pane.isLoading = true
    pane.hasError = false
    pane.resolveTask?.cancel()
    let tier = pane.qualityTier
    pane.resolveTask = Task { [weak pane] in
      guard let pane else { return }
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
        pane.player.replaceCurrentItem(with: item)
        pane.player.isMuted = !pane.isAudible
        pane.player.play()

        // Hold the loading state (poster shown) until the first frame is actually
        // decodable so the tile reveals cleanly rather than flashing black.
        for _ in 0..<40 {
          if Task.isCancelled || pane.qualityTier != tier { return }
          if pane.player.currentItem?.status == .readyToPlay { break }
          try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled, pane.qualityTier == tier else { return }
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

  /// The tier a pane should run at — a purely structural role, so quality only
  /// changes on deliberate layout/primary changes (never on every focus move,
  /// which would flash a poster constantly). The one large spotlight primary gets
  /// Source; grid quadrants get ~720p; the small spotlight filmstrip thumbnails
  /// stay light (~480p).
  private func desiredTier(for pane: MultiviewPane) -> MultiviewQualityTier {
    if layout == .spotlight && pane.id == primaryPane?.id { return .source }
    return layout == .grid ? .grid : .thumbnail
  }

  /// Recompute each pane's desired quality tier (no playback change here).
  private func syncQualityTiers() {
    for pane in panes { pane.qualityTier = desiredTier(for: pane) }
  }

  /// Re-evaluate each pane's tier and re-pin any that changed. The re-pin is a
  /// `replaceCurrentItem` on the pane's single player, masked by the channel
  /// poster while it loads — no second concurrent decoder (the hardware can't
  /// afford one), so playback stays reliable instead of going black.
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
    for pane in panes {
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
      pane.player.pause()
      pane.player.replaceCurrentItem(with: nil)
    }
  }
}
