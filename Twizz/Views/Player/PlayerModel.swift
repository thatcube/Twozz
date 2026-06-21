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

  // MARK: Stream Rewind (DVR) / scrub / VOD hand-off

  /// True while the viewer has explicitly paused the live stream. Pausing keeps
  /// the playhead in place while the DVR window keeps growing, so resuming/seeking
  /// stays inside the retained window. Also gates the stall watchdog.
  var isUserPaused = false
  /// True while the viewer is actively scrubbing the rewind bar (analog jog).
  var isScrubbing = false
  /// Live scrub position (seconds on the player timeline) while a jog is in
  /// progress; the actual `AVPlayerItem.seek` is throttled/coalesced against it.
  var scrubTargetSeconds: Double?
  /// Throttle clock for the coalesced scrub seeks issued during a jog.
  var lastScrubSeekAt = Date.distantPast
  /// Debounced "settle" that commits a final frame-accurate seek once jogging stops.
  var scrubCommitTask: Task<Void, Never>?
  /// True while the playhead is following the live edge (drives the LIVE pin).
  var pinnedToLive = true
  /// Selected VOD playback rate, reapplied across pause/resume/seek (live is 1.0).
  var vodPlaybackRate: Float = 1.0

  /// The channel's in-progress broadcast VOD, once resolved (for Stream Rewind
  /// hand-off past the DVR floor). `nil` until resolved / when unavailable.
  var liveVODHandoff: PlayerView.LiveVODHandoff?
  /// When the in-progress VOD was last resolved; throttles re-resolves.
  var lastBroadcastVODResolveAt = Date.distantPast
  /// Guards against overlapping hand-off / return transitions.
  var vodHandoffTransitionInFlight = false

  // MARK: Diagnostics (experimental troubleshooting overlay)
  // Counters and a rolling event log so freezes/jumps can be observed on-device
  // and reported back, rather than inferred. Only meaningful while the overlay
  // toggle is on; reset on each fresh load.
  var diagStallCount = 0
  var diagJumpCount = 0
  var diagReloadCount = 0
  var diagEvents: [DiagnosticsEvent] = []
  var diagLastPlayheadSeconds: Double?
  var diagLastSampleAt: Date?
  var diagWasStalled = false
  var diagIsFrozen = false
  var diagFrozenSince: Date?
  var diagSessionStartedAt: Date?

  // MARK: Raid banners (incoming/outgoing)
  var raidBannerDismissTask: Task<Void, Never>?
  var incomingRaidAvatarURL: URL?
  var outgoingRaid: OutgoingRaidEvent?
  var outgoingRaidSecondsRemaining = 0
  var outgoingRaidFollowTask: Task<Void, Never>?

  // MARK: Sleep timer
  // A single countdown task pauses playback after a chosen duration so the
  // Apple TV can sleep when the viewer dozes off.
  var sleepTimerTask: Task<Void, Never>?
  var sleepDeadline: Date?
  var sleepUntilStreamEnds = false
  var sleepRemainingSeconds: Int?
  var sleepSelectionIndex = 0
  var showStillWatching = false
  var isSleeping = false

  // MARK: Chat send / sync
  var isSendingChat = false
  var chatSendError: String?
  var chatSyncSendDeadline: Date?
  var chatSyncSendDelay: Double = 0
  var chatSyncSendClearTask: Task<Void, Never>?

  // MARK: Chat scroll / soft-pause / trackpad / hold
  var chatSoftPauseRemaining: Int?
  var softPauseTask: Task<Void, Never>?
  var isChatScrolling = false
  var chatScrollAnchorID: ChatMessage.ID?
  var chatScrollTarget: ChatScrollTarget?
  var chatScrollNonce = 0
  var chatFrozenMessages: [ChatMessage]?
  var trackpadScrollTask: Task<Void, Never>?
  var trackpadScrollIndex: Double = 0
  var lastSentScrollIndex: Int = -1
  var lastGestureScrollAt = Date.distantPast
  var chatHoldTask: Task<Void, Never>?
  var lastHoldRepeatAt = Date.distantPast

  // MARK: Channel identity & resolved metadata
  var activeChannel: String = ""
  var youtubeAutoResolvedTarget = ""
  var kickAutoResolvedTarget = ""
  var streamTitle: String = ""
  var channelDisplayName: String = ""
  var channelAvatarURL: URL?
  var pendingSwitchLogin: String?
  var chatReplayStartMessageID: ChatMessage.ID?

  // MARK: Engine lifecycle tasks & observers
  var vodTimeObserver: Any?
  var latencyTask: Task<Void, Never>?
  var playbackWatchdogTask: Task<Void, Never>?
  var rateControlTask: Task<Void, Never>?
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
  var isUserPaused: Bool {
    get { model.isUserPaused }
    nonmutating set { model.isUserPaused = newValue }
  }
  var isScrubbing: Bool {
    get { model.isScrubbing }
    nonmutating set { model.isScrubbing = newValue }
  }
  var scrubTargetSeconds: Double? {
    get { model.scrubTargetSeconds }
    nonmutating set { model.scrubTargetSeconds = newValue }
  }
  var lastScrubSeekAt: Date {
    get { model.lastScrubSeekAt }
    nonmutating set { model.lastScrubSeekAt = newValue }
  }
  var scrubCommitTask: Task<Void, Never>? {
    get { model.scrubCommitTask }
    nonmutating set { model.scrubCommitTask = newValue }
  }
  var pinnedToLive: Bool {
    get { model.pinnedToLive }
    nonmutating set { model.pinnedToLive = newValue }
  }
  var vodPlaybackRate: Float {
    get { model.vodPlaybackRate }
    nonmutating set { model.vodPlaybackRate = newValue }
  }
  var liveVODHandoff: PlayerView.LiveVODHandoff? {
    get { model.liveVODHandoff }
    nonmutating set { model.liveVODHandoff = newValue }
  }
  var lastBroadcastVODResolveAt: Date {
    get { model.lastBroadcastVODResolveAt }
    nonmutating set { model.lastBroadcastVODResolveAt = newValue }
  }
  var vodHandoffTransitionInFlight: Bool {
    get { model.vodHandoffTransitionInFlight }
    nonmutating set { model.vodHandoffTransitionInFlight = newValue }
  }
  var diagStallCount: Int {
    get { model.diagStallCount }
    nonmutating set { model.diagStallCount = newValue }
  }
  var diagJumpCount: Int {
    get { model.diagJumpCount }
    nonmutating set { model.diagJumpCount = newValue }
  }
  var diagReloadCount: Int {
    get { model.diagReloadCount }
    nonmutating set { model.diagReloadCount = newValue }
  }
  var diagEvents: [DiagnosticsEvent] {
    get { model.diagEvents }
    nonmutating set { model.diagEvents = newValue }
  }
  var diagLastPlayheadSeconds: Double? {
    get { model.diagLastPlayheadSeconds }
    nonmutating set { model.diagLastPlayheadSeconds = newValue }
  }
  var diagLastSampleAt: Date? {
    get { model.diagLastSampleAt }
    nonmutating set { model.diagLastSampleAt = newValue }
  }
  var diagWasStalled: Bool {
    get { model.diagWasStalled }
    nonmutating set { model.diagWasStalled = newValue }
  }
  var diagIsFrozen: Bool {
    get { model.diagIsFrozen }
    nonmutating set { model.diagIsFrozen = newValue }
  }
  var diagFrozenSince: Date? {
    get { model.diagFrozenSince }
    nonmutating set { model.diagFrozenSince = newValue }
  }
  var diagSessionStartedAt: Date? {
    get { model.diagSessionStartedAt }
    nonmutating set { model.diagSessionStartedAt = newValue }
  }
  var raidBannerDismissTask: Task<Void, Never>? {
    get { model.raidBannerDismissTask }
    nonmutating set { model.raidBannerDismissTask = newValue }
  }
  var incomingRaidAvatarURL: URL? {
    get { model.incomingRaidAvatarURL }
    nonmutating set { model.incomingRaidAvatarURL = newValue }
  }
  var outgoingRaid: OutgoingRaidEvent? {
    get { model.outgoingRaid }
    nonmutating set { model.outgoingRaid = newValue }
  }
  var outgoingRaidSecondsRemaining: Int {
    get { model.outgoingRaidSecondsRemaining }
    nonmutating set { model.outgoingRaidSecondsRemaining = newValue }
  }
  var outgoingRaidFollowTask: Task<Void, Never>? {
    get { model.outgoingRaidFollowTask }
    nonmutating set { model.outgoingRaidFollowTask = newValue }
  }
  var sleepTimerTask: Task<Void, Never>? {
    get { model.sleepTimerTask }
    nonmutating set { model.sleepTimerTask = newValue }
  }
  var sleepDeadline: Date? {
    get { model.sleepDeadline }
    nonmutating set { model.sleepDeadline = newValue }
  }
  var sleepUntilStreamEnds: Bool {
    get { model.sleepUntilStreamEnds }
    nonmutating set { model.sleepUntilStreamEnds = newValue }
  }
  var sleepRemainingSeconds: Int? {
    get { model.sleepRemainingSeconds }
    nonmutating set { model.sleepRemainingSeconds = newValue }
  }
  var sleepSelectionIndex: Int {
    get { model.sleepSelectionIndex }
    nonmutating set { model.sleepSelectionIndex = newValue }
  }
  var showStillWatching: Bool {
    get { model.showStillWatching }
    nonmutating set { model.showStillWatching = newValue }
  }
  var isSleeping: Bool {
    get { model.isSleeping }
    nonmutating set { model.isSleeping = newValue }
  }
  var isSendingChat: Bool {
    get { model.isSendingChat }
    nonmutating set { model.isSendingChat = newValue }
  }
  var chatSendError: String? {
    get { model.chatSendError }
    nonmutating set { model.chatSendError = newValue }
  }
  var chatSyncSendDeadline: Date? {
    get { model.chatSyncSendDeadline }
    nonmutating set { model.chatSyncSendDeadline = newValue }
  }
  var chatSyncSendDelay: Double {
    get { model.chatSyncSendDelay }
    nonmutating set { model.chatSyncSendDelay = newValue }
  }
  var chatSyncSendClearTask: Task<Void, Never>? {
    get { model.chatSyncSendClearTask }
    nonmutating set { model.chatSyncSendClearTask = newValue }
  }
  var chatSoftPauseRemaining: Int? {
    get { model.chatSoftPauseRemaining }
    nonmutating set { model.chatSoftPauseRemaining = newValue }
  }
  var softPauseTask: Task<Void, Never>? {
    get { model.softPauseTask }
    nonmutating set { model.softPauseTask = newValue }
  }
  var isChatScrolling: Bool {
    get { model.isChatScrolling }
    nonmutating set { model.isChatScrolling = newValue }
  }
  var chatScrollAnchorID: ChatMessage.ID? {
    get { model.chatScrollAnchorID }
    nonmutating set { model.chatScrollAnchorID = newValue }
  }
  var chatScrollTarget: ChatScrollTarget? {
    get { model.chatScrollTarget }
    nonmutating set { model.chatScrollTarget = newValue }
  }
  var chatScrollNonce: Int {
    get { model.chatScrollNonce }
    nonmutating set { model.chatScrollNonce = newValue }
  }
  var chatFrozenMessages: [ChatMessage]? {
    get { model.chatFrozenMessages }
    nonmutating set { model.chatFrozenMessages = newValue }
  }
  var trackpadScrollTask: Task<Void, Never>? {
    get { model.trackpadScrollTask }
    nonmutating set { model.trackpadScrollTask = newValue }
  }
  var trackpadScrollIndex: Double {
    get { model.trackpadScrollIndex }
    nonmutating set { model.trackpadScrollIndex = newValue }
  }
  var lastSentScrollIndex: Int {
    get { model.lastSentScrollIndex }
    nonmutating set { model.lastSentScrollIndex = newValue }
  }
  var lastGestureScrollAt: Date {
    get { model.lastGestureScrollAt }
    nonmutating set { model.lastGestureScrollAt = newValue }
  }
  var chatHoldTask: Task<Void, Never>? {
    get { model.chatHoldTask }
    nonmutating set { model.chatHoldTask = newValue }
  }
  var lastHoldRepeatAt: Date {
    get { model.lastHoldRepeatAt }
    nonmutating set { model.lastHoldRepeatAt = newValue }
  }
  var activeChannel: String {
    get { model.activeChannel }
    nonmutating set { model.activeChannel = newValue }
  }
  var youtubeAutoResolvedTarget: String {
    get { model.youtubeAutoResolvedTarget }
    nonmutating set { model.youtubeAutoResolvedTarget = newValue }
  }
  var kickAutoResolvedTarget: String {
    get { model.kickAutoResolvedTarget }
    nonmutating set { model.kickAutoResolvedTarget = newValue }
  }
  var streamTitle: String {
    get { model.streamTitle }
    nonmutating set { model.streamTitle = newValue }
  }
  var channelDisplayName: String {
    get { model.channelDisplayName }
    nonmutating set { model.channelDisplayName = newValue }
  }
  var channelAvatarURL: URL? {
    get { model.channelAvatarURL }
    nonmutating set { model.channelAvatarURL = newValue }
  }
  var pendingSwitchLogin: String? {
    get { model.pendingSwitchLogin }
    nonmutating set { model.pendingSwitchLogin = newValue }
  }
  var chatReplayStartMessageID: ChatMessage.ID? {
    get { model.chatReplayStartMessageID }
    nonmutating set { model.chatReplayStartMessageID = newValue }
  }
  var vodTimeObserver: Any? {
    get { model.vodTimeObserver }
    nonmutating set { model.vodTimeObserver = newValue }
  }
  var latencyTask: Task<Void, Never>? {
    get { model.latencyTask }
    nonmutating set { model.latencyTask = newValue }
  }
  var playbackWatchdogTask: Task<Void, Never>? {
    get { model.playbackWatchdogTask }
    nonmutating set { model.playbackWatchdogTask = newValue }
  }
  var rateControlTask: Task<Void, Never>? {
    get { model.rateControlTask }
    nonmutating set { model.rateControlTask = newValue }
  }
}
