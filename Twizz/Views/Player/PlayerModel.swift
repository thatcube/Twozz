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

  // MARK: Playback engine state
  // The engine's observable outputs and source-selection bookkeeping. The view
  // reads these to render and writes them through the forwarding accessors below;
  // observation is per-property, so only views that actually read a given value
  // are invalidated when it changes (matching the previous `@State` behavior).

  /// The resolved live playback (master playlist + qualities), or `nil` until the
  /// stream resolves. `nil` while loading / offline / errored.
  var playback: StreamPlayback?
  var errorMessage: String?
  var isOffline = false
  var isLoading = true

  /// Live resolution AVPlayer's adaptive (Auto) selection is currently showing,
  /// e.g. "1080p60". Drives the "Auto (1080p60)" label on the quality button.
  var resolvedQualityName: String?

  /// The real (pre-proxy) source URL of the currently loaded item, so we can tell
  /// whether a quality switch actually needs to replace the item. `AVURLAsset.url`
  /// is the rewritten `twizz-ll://` URL in low-latency mode, so it can't be used
  /// for this comparison directly.
  var currentSourceURL: URL?

  /// Taps decoded frames off the current item so the decode-freeze watchdog can
  /// tell "no new picture" apart from "playhead not advancing". Rebuilt with each
  /// item in `makeItem`; nil while no video item is loaded.
  var playerItemVideoOutput: AVPlayerItemVideoOutput?

  /// Non-nil once the playback clock is advancing but the video output has stopped
  /// producing fresh frames — the "frozen picture while captions/chat keep
  /// scrolling" decode wedge that every playhead/buffer-based watchdog misses.
  /// Cleared the moment a new frame arrives.
  var videoDecodeFrozenSince: Date?

  var lastStallNotificationAt = Date.distantPast
  var suppressLowLatencyToggleReload = false
  var consecutiveLoadFailures = 0

  // MARK: Alternate source (experimental YouTube simulcast)
  // Experimental alternate video source surfaced under the Diagnostics overlay to
  // A/B latency against the Twitch path. When active, the player drops the
  // Twitch-only proxy/headers and the edge-chasing rate controller.

  var isUsingAltSource = false
  var altYouTubeMasterURL: URL?
  var altSourceStatus: String?
  /// Throttles automatic alt-source manifest re-resolution after a 403/expiry so a
  /// failing googlevideo URL is refreshed without hammering YouTube.
  var lastAltResolveAt = Date.distantPast
  var altResolveInFlight = false
  /// Caps automatic alt-source retries after a 403 so a blocked manifest doesn't
  /// trigger an endless re-resolve loop that gets the IP flagged by YouTube.
  var altFailedRetries = 0
  /// Whether the active channel actually has a resolvable YouTube simulcast.
  /// Probed on channel load; gates the Stream Source picker in the quality menu.
  var youtubeSourceAvailable = false
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

  // Playback engine value-state (read/write forwards; observation is per-property).
  var playback: StreamPlayback? {
    get { model.playback }
    nonmutating set { model.playback = newValue }
  }
  var errorMessage: String? {
    get { model.errorMessage }
    nonmutating set { model.errorMessage = newValue }
  }
  var isOffline: Bool {
    get { model.isOffline }
    nonmutating set { model.isOffline = newValue }
  }
  var isLoading: Bool {
    get { model.isLoading }
    nonmutating set { model.isLoading = newValue }
  }
  var resolvedQualityName: String? {
    get { model.resolvedQualityName }
    nonmutating set { model.resolvedQualityName = newValue }
  }
  var currentSourceURL: URL? {
    get { model.currentSourceURL }
    nonmutating set { model.currentSourceURL = newValue }
  }
  var playerItemVideoOutput: AVPlayerItemVideoOutput? {
    get { model.playerItemVideoOutput }
    nonmutating set { model.playerItemVideoOutput = newValue }
  }
  var videoDecodeFrozenSince: Date? {
    get { model.videoDecodeFrozenSince }
    nonmutating set { model.videoDecodeFrozenSince = newValue }
  }
  var lastStallNotificationAt: Date {
    get { model.lastStallNotificationAt }
    nonmutating set { model.lastStallNotificationAt = newValue }
  }
  var suppressLowLatencyToggleReload: Bool {
    get { model.suppressLowLatencyToggleReload }
    nonmutating set { model.suppressLowLatencyToggleReload = newValue }
  }
  var consecutiveLoadFailures: Int {
    get { model.consecutiveLoadFailures }
    nonmutating set { model.consecutiveLoadFailures = newValue }
  }
  var isUsingAltSource: Bool {
    get { model.isUsingAltSource }
    nonmutating set { model.isUsingAltSource = newValue }
  }
  var altYouTubeMasterURL: URL? {
    get { model.altYouTubeMasterURL }
    nonmutating set { model.altYouTubeMasterURL = newValue }
  }
  var altSourceStatus: String? {
    get { model.altSourceStatus }
    nonmutating set { model.altSourceStatus = newValue }
  }
  var lastAltResolveAt: Date {
    get { model.lastAltResolveAt }
    nonmutating set { model.lastAltResolveAt = newValue }
  }
  var altResolveInFlight: Bool {
    get { model.altResolveInFlight }
    nonmutating set { model.altResolveInFlight = newValue }
  }
  var altFailedRetries: Int {
    get { model.altFailedRetries }
    nonmutating set { model.altFailedRetries = newValue }
  }
  var youtubeSourceAvailable: Bool {
    get { model.youtubeSourceAvailable }
    nonmutating set { model.youtubeSourceAvailable = newValue }
  }
}
