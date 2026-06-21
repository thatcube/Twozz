import AVFoundation
import Observation

/// Owns the playback *engine* for a `PlayerView`: the `AVPlayer`, the chat /
/// events / captions services, the low-latency proxy, and the per-frame
/// monitoring boxes. Pulling these out of the `PlayerView` struct is the first
/// step in shrinking that 5,000-line view: the engine is platform-agnostic
/// (Foundation / AVFoundation only — no SwiftUI, no tvOS focus engine), so it is
/// the part most worth isolating and, eventually, reusing on other platforms.
///
/// The view continues to reach these members by their original names through the
/// forwarding accessors in the `PlayerView` extension below, so the hundreds of
/// existing call sites read unchanged while ownership now lives here.
///
/// Held by the view in a single `@State var model`, so the engine persists across
/// the view's frequent struct re-creations exactly as the individual `@State`
/// members did before.
@MainActor
@Observable
final class PlayerModel {
  // MARK: Chat & events

  let chat = ChatService()

  /// Twitch login -> Kick slug overrides for streamers whose Kick name differs
  /// from their Twitch login and isn't derivable from their profile.
  let kickAliases = KickAliasService()

  /// Drives chat replay when in VOD mode (reveals comments up to the playhead).
  let replay = VODChatReplayService()

  /// Detects *outgoing* raids (the watched channel raiding away) via EventSub.
  let eventSub = EventSubService()

  /// Surfaces live polls / predictions / hype trains / goals for the watched
  /// channel via Twitch's private Hermes WebSocket (read-only).
  let hermes = HermesEventService()

  // MARK: Playback

  let player = AVPlayer()

  /// Drives the audio-only visualizer orb. Reacts to real audio when the player
  /// item exposes a tappable audio track (best effort on live HLS), otherwise
  /// runs an ambient animation.
  let audioLevelMonitor = AudioLevelMonitor()

  /// On-device live caption generation ("Captions (beta)"). Off by default; only
  /// runs on live streams on tvOS 26+. Fully isolated from the playback path —
  /// it consumes the audio-only playlist via its own side-channel.
  let captionController = CaptionController()

  /// Retained for the player's lifetime: `AVURLAsset` only holds its resource
  /// loader delegate weakly, so the proxy must be owned here to stay alive.
  let lowLatencyProxy = LowLatencyHLSProxy(headers: PlaybackService.streamHeaders)

  // MARK: Monitoring boxes
  // Plain (non-`@Observable`) reference boxes for the once-per-second / per-frame
  // bookkeeping written by the latency, watchdog and scrub loops. Mutating their
  // properties never invalidates the view, so the high-frequency monitoring no
  // longer churns the UI. `latencyReadout` / `rewindReadout` are `@Observable`
  // so only their dedicated badge / transport leaf views update.

  let mon = PlaybackMonitorBox()
  let latencyReadout = LatencyReadout()
  let rewindReadout = RewindReadout()

  /// Drives the analog (precision) trackpad scrubbing while the rewind bar is
  /// focused.
  let scrubInput = ScrubInputCoordinator()

  /// Reads the Siri Remote trackpad as a relative swipe surface for chat scroll.
  let trackpad = RemoteTrackpadMonitor()
}

extension PlayerView {
  // Forwarding accessors that keep the engine members reachable under their
  // original names. They are read-only because none of these reference-typed
  // members is ever reassigned (the objects are mutated in place / via methods).

  var chat: ChatService { model.chat }
  var kickAliases: KickAliasService { model.kickAliases }
  var replay: VODChatReplayService { model.replay }
  var eventSub: EventSubService { model.eventSub }
  var hermes: HermesEventService { model.hermes }
  var player: AVPlayer { model.player }
  var audioLevelMonitor: AudioLevelMonitor { model.audioLevelMonitor }
  var captionController: CaptionController { model.captionController }
  var lowLatencyProxy: LowLatencyHLSProxy { model.lowLatencyProxy }
  var mon: PlaybackMonitorBox { model.mon }
  var latencyReadout: LatencyReadout { model.latencyReadout }
  var rewindReadout: RewindReadout { model.rewindReadout }
  var scrubInput: ScrubInputCoordinator { model.scrubInput }
  var trackpad: RemoteTrackpadMonitor { model.trackpad }
}
