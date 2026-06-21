import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// Full-screen player for a live channel. Video sits on the left and the chat
/// panel docks to the right at full height (the video shrinks to make room,
/// never overlapping). We use a custom `AVPlayerLayer` surface with our own
/// overlay UI rather than the native player transport — the native controls are
/// VOD/scrubbing-oriented and unsuited to a live, side-by-side chat layout.
/// Controls auto-hide and are revealed by pressing the remote.
struct PlayerView: View {
  /// Identifies an on-demand broadcast (VOD) so the same player can replay a past
  /// stream — full-duration seek + synchronized chat replay — instead of a live
  /// stream. `nil` (the default) means this is the live channel player.
  struct VODContext: Equatable {
    let id: String
    let title: String
  }

  let channel: String
  var auth: TwitchAuthSession
  /// Shared go-live watcher. Optional because VOD playback (`OnDemandPlayerView`)
  /// has no live-follow context. When present, the player surfaces "just went
  /// live" toasts and suppresses the channel currently on screen.
  var goLive: GoLiveWatcher? = nil
  /// When set, the player runs in VOD mode: it plays the recorded broadcast,
  /// drives `replay` for chat, exposes a full-duration seek bar + playback speed,
  /// and gates off all live-only machinery (latency, low-latency proxy, EventSub,
  /// adaptive quality, IRC chat, watchdog).
  var vod: VODContext? = nil

  /// Runtime hand-off into the channel's in-progress broadcast VOD, used by
  /// Stream Rewind to continue rewinding past the in-memory DVR window. Distinct
  /// from `vod` (which is set at init for a recorded-broadcast session opened from
  /// the channel page): this is resolved and toggled *during* a live session when
  /// the viewer rewinds to the DVR floor. See `PlayerView+VOD` for the transition.
  struct LiveVODHandoff: Equatable {
    let broadcast: PlaybackService.LiveBroadcastVOD
    /// Title to show while in the handoff VOD (the live broadcast's title).
    let title: String
    /// True once playback has actually switched to the VOD; false while merely
    /// resolved/cached and still playing live.
    var isActive: Bool
  }

  /// Optional poster shown full-bleed while the stream loads, cross-fading to
  /// video once playback starts. Used when escalating from a multiview pane so
  /// the hand-off looks seamless (the channel's frame fills immediately) instead
  /// of flashing a black "Loading…" screen.
  var posterURL: URL? = nil



  /// The currently-active channel, which can change if the user follows a raid.
  /// (State now on PlayerModel.)

  @Environment(\.dismiss) var dismiss
  @Environment(\.themePalette) var palette
  @Environment(\.glassDisabled) var glassDisabled
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  /// App-global services. Used here to source the in-player YouTube viewer count
  /// from the same public live snapshot the Home cards use (followed channels
  /// carry the streamer's YouTube channel ID; the snapshot holds its live count).
  @Environment(AppEnvironment.self) var environment
  @AppStorage(PersistenceKey.preferredQuality) var preferredQuality = "Auto"
  /// Latency-vs-quality profile for the adaptive ("Auto") stream, surfaced as the
  /// two Auto rows in the quality picker. Stored as the enum raw value; read it
  /// through `livePlaybackProfile`.
  @AppStorage(PersistenceKey.livePlaybackProfile) var livePlaybackProfileRaw = LivePlaybackProfile.default
    .rawValue
  @AppStorage(PersistenceKey.chatTextSizeValue) var chatTextSizeValue = Double(
    ChatAppearance.defaultTextSize)
  @AppStorage(PersistenceKey.chatEmoteAuto) var chatEmoteAuto = ChatAppearance.defaultEmoteAuto
  @AppStorage(PersistenceKey.chatEmoteSizeValue) var chatEmoteSizeValue = Double(
    ChatAppearance.defaultEmoteSize)
  @AppStorage(PersistenceKey.chatLineHeightValue) var chatLineHeightValue = Double(
    ChatAppearance.defaultLineHeight)
  @AppStorage(PersistenceKey.chatLetterSpacingValue) var chatLetterSpacingValue = Double(
    ChatAppearance.defaultLetterSpacing)
  @AppStorage(PersistenceKey.chatMessageSpacingValue) var chatMessageSpacingValue = Double(
    ChatAppearance.defaultMessageSpacing)
  @AppStorage(PersistenceKey.chatWidthValue) var chatWidthValue = Double(ChatAppearance.defaultWidth)
  @AppStorage(PersistenceKey.chatAnimatedEmotes) var chatAnimatedEmotes = ChatAppearance
    .defaultAnimatedEmotes
  @AppStorage(PersistenceKey.chatFontStyle) var chatFontStyleRaw = ChatAppearance.defaultFontStyle
    .rawValue
  @AppStorage(PersistenceKey.chatShowBadges) var chatShowBadges = ChatAppearance.defaultShowBadges
  @AppStorage(PersistenceKey.chatShowPlatformBadges) var chatShowPlatformBadges = ChatAppearance
    .defaultShowPlatformBadges
  /// Global on/off for highlighting chat lines that mention the signed-in user
  /// (and any user keywords below). On by default.
  @AppStorage(PersistenceKey.chatHighlightMentionsEnabled) var chatHighlightMentionsEnabled = true
  /// User-defined extra highlight keywords (other handles, "giveaway", a game
  /// name…), stored as a single comma/newline-separated string and parsed into a
  /// normalized list by `chatHighlightKeywordList`.
  @AppStorage(PersistenceKey.chatHighlightKeywords) var chatHighlightKeywords = ""
  @AppStorage(PersistenceKey.chatLayoutMode) var chatLayoutModeRaw = ChatLayoutMode.side.rawValue
  @AppStorage(PersistenceKey.chatSyncToStream) var chatSyncToStream = false
  @AppStorage(PersistenceKey.experimentalYouTubeMergeEnabled) var experimentalYouTubeMergeEnabled = true
  /// Optional manual override for the YouTube merge target. Kept per-channel and
  /// non-persistent so a value entered for one streamer never leaks into another
  /// (previously this was global `@AppStorage`, which made every channel merge
  /// with whatever handle was last entered).
  @State var experimentalYouTubeMergeChannelOrURL = ""
  /// Best-effort YouTube target derived from the active Twitch channel (its
  /// social links, then description, then a name-based guess). (State on PlayerModel.)
  @AppStorage(PersistenceKey.experimentalKickMergeEnabled) var experimentalKickMergeEnabled = true
  /// Optional manual override for the Kick merge target. Per-channel and
  /// non-persistent for the same reason as the YouTube override, so a handle
  /// entered for one streamer never leaks into another.
  @State var experimentalKickMergeChannelOrURL = ""
  /// Best-effort Kick target derived from the active Twitch channel (its social
  /// links, then description, then a name-based guess). (State on PlayerModel.)
  @AppStorage(LowLatencyHLSProxy.settingsKey) var lowLatencyProxyEnabled = true
  @AppStorage(LowLatencyHLSProxy.rewindSettingsKey) var streamRewindEnabled = true
  @AppStorage(PersistenceKey.preferYouTubeSource) var preferYouTubeSource = true
  @AppStorage(PersistenceKey.showLatencyDiagnostics) var showLatencyDiagnostics = false
  /// On-device live captions toggle (beta). See `captionController`.
  @AppStorage(PersistenceKey.captionsEnabled) var captionsEnabled = false
  /// Caption appearance + timing controls (the Captions settings sub-page).
  /// Font multiplier on the base caption size (0.7…1.6).
  @AppStorage(PersistenceKey.captionsFontScale) var captionsFontScale = 1.0
  /// Vertical placement, 0 = bottom of safe area, 1 = top.
  @AppStorage(PersistenceKey.captionsVerticalPosition) var captionsVerticalPosition = 0.0
  /// User timing fine-tune in seconds (+ = captions appear earlier/faster).
  @AppStorage(PersistenceKey.captionsTimingOffset) var captionsTimingOffset = 0.0
  /// Slab background style (`CaptionBackgroundStyle` raw value).
  @AppStorage(PersistenceKey.captionsBackgroundStyle) var captionsBackgroundStyleRaw = CaptionBackgroundStyle.blur.rawValue
  /// Draw a dark outline around caption glyphs for legibility.
  @AppStorage(PersistenceKey.captionsOutline) var captionsOutline = false
  /// Draw a soft drop shadow behind caption glyphs (separate from the hard
  /// outline) for legibility over busy/bright video.
  @AppStorage(PersistenceKey.captionsShadow) var captionsShadow = false
  /// Caption font weight (`CaptionFontWeight` raw value).
  @AppStorage(PersistenceKey.captionsFontWeight) var captionsFontWeightRaw = CaptionFontWeight.semibold.rawValue
  /// Caption text color (`CaptionTextColor` raw value).
  @AppStorage(PersistenceKey.captionsTextColor) var captionsTextColorRaw = CaptionTextColor.white.rawValue
  /// Caption text opacity, 0.3…1.0.
  @AppStorage(PersistenceKey.captionsTextOpacity) var captionsTextOpacity = 1.0
  /// Live viewer count badge in the top-left HUD. On by default — a glanceable,
  /// non-diagnostic stat most viewers want while watching.
  @AppStorage(PersistenceKey.showViewerCount) var showViewerCount = true
  /// Latency readout in the top-left HUD chip. Off by default and independent of
  /// the full Diagnostics Overlay, so viewers who just want the latency number
  /// can enable it without the developer event log.
  @AppStorage(PersistenceKey.showLatencyBadge) var showLatencyBadge = false

  // Per-event visibility for the passive, read-only event banners (Events
  // sub-page of chat settings). All on by default — they mirror what Twitch
  // shows every viewer — but each can be hidden independently.
  @AppStorage(PersistenceKey.showRaidEvents) var showRaidEvents = true
  @AppStorage(PersistenceKey.showHypeTrainEvents) var showHypeTrainEvents = true
  @AppStorage(PersistenceKey.showPollEvents) var showPollEvents = true
  @AppStorage(PersistenceKey.showPredictionEvents) var showPredictionEvents = true
  @AppStorage(PersistenceKey.showGoalEvents) var showGoalEvents = true

  /// Owns the playback engine + chat/events/captions services and the per-frame
  /// monitoring boxes. The engine members are reached by their original names via
  /// the forwarding accessors in `PlayerModel.swift`.
  @State var model = PlayerModel()
  /// Periodic player time observer used in VOD mode to sync chat replay + the
  /// seek readout to the playhead. (vodTimeObserver now on PlayerModel.)
  /// Debug-only cursor for the "Simulate Interactive Moment" cycle button.
  @State var debugMomentIndex = 0
  @State var showChat: Bool =
    UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool ?? true
  // chatReplayStartMessageID now lives in PlayerModel.
  @State var showSignInSheet = false
  @State var showChatSettings = false
  @State var chatSettingsPage: ChatSettingsPage = .main
  /// Natural (content) height of the current settings page, used to size the
  /// floating panel to its content and animate when the page/content changes.
  @State var chatSettingsContentHeight: CGFloat = 0
  @State var showControls = false
  // streamTitle / channelDisplayName / channelAvatarURL now live in PlayerModel.
  @State var channelPageTarget: ChannelPageTarget?
  /// When the user picks a "More like this" channel from the channel page, we
  /// stash its login and switch to it once the page cover finishes dismissing.
  /// (pendingSwitchLogin now on PlayerModel.)
  @State var chatDraft: String = ""
  @State var chatInputActivationToken: Int = 0
  @State var youtubeInputActivationToken: Int = 0
  @State var kickInputActivationToken: Int = 0
  @State var highlightKeywordsActivationToken: Int = 0
  // Chat send/sync state now lives in PlayerModel.
  @State var hideTask: Task<Void, Never>?
  @State var focusRecoveryTask: Task<Void, Never>?
  @State var isQualityMenuPresented = false
  // latencyTask / playbackWatchdogTask / rateControlTask now live in PlayerModel.
  // The adaptive playback-rate controller runs at a sub-second cadence — far
  // faster than the 1 Hz latency monitor — so the anti-stall slow-down can react
  // to a draining buffer before it empties into a hard stall.
  // The latency / watchdog / rewind monitoring boxes (`mon`, `latencyReadout`,
  // `rewindReadout`), the scrub-input coordinator and the trackpad monitor now
  // live on `PlayerModel` and are reached via forwarding accessors. They use
  // plain (non-`@Observable`) reference boxes so the once-per-second / per-frame
  // monitoring never invalidates the whole player; only the latency badge and
  // rewind transport observe the `@Observable` readouts. See `PlayerModel.swift`.

  // MARK: Stream Rewind (DVR) / scrub / VOD hand-off
  // The rewind/scrub/VOD-handoff engine state (isUserPaused, isScrubbing,
  // scrubTargetSeconds, lastScrubSeekAt, scrubCommitTask, pinnedToLive,
  // vodPlaybackRate, liveVODHandoff, lastBroadcastVODResolveAt,
  // vodHandoffTransitionInFlight) now lives on `PlayerModel` and is reached via
  // forwarding accessors; see `PlayerModel.swift` for the per-property docs.

  var wallClockLatencySeconds: Double? {
    get { mon.wallClockLatencySeconds }
    nonmutating set { mon.wallClockLatencySeconds = newValue }
  }
  var liveEdgeLatencySeconds: Double? {
    get { mon.liveEdgeLatencySeconds }
    nonmutating set { mon.liveEdgeLatencySeconds = newValue }
  }
  var smoothedLatencySeconds: Double? {
    get { mon.smoothedLatencySeconds }
    nonmutating set { mon.smoothedLatencySeconds = newValue }
  }
  var latencySampleCount: Int {
    get { mon.latencySampleCount }
    nonmutating set { mon.latencySampleCount = newValue }
  }
  var latencyStableCount: Int {
    get { mon.latencyStableCount }
    nonmutating set { mon.latencyStableCount = newValue }
  }
  var latencyOutlierStreak: Int {
    get { mon.latencyOutlierStreak }
    nonmutating set { mon.latencyOutlierStreak = newValue }
  }
  // The real (pre-proxy) source URL, alt-source bookkeeping and the video-output
  // frame tap now live on `PlayerModel` (see "Playback engine state" /
  // "Alternate source" there) and are reached via forwarding accessors.
  var isPlaybackActive: Bool {
    get { mon.isPlaybackActive }
    nonmutating set { mon.isPlaybackActive = newValue }
  }
  var didRequestPlayback: Bool {
    get { mon.didRequestPlayback }
    nonmutating set { mon.didRequestPlayback = newValue }
  }
  var edgeLatencyLowConfidenceStreak: Int {
    get { mon.edgeLatencyLowConfidenceStreak }
    nonmutating set { mon.edgeLatencyLowConfidenceStreak = newValue }
  }
  var wallClockLowConfidenceStreak: Int {
    get { mon.wallClockLowConfidenceStreak }
    nonmutating set { mon.wallClockLowConfidenceStreak = newValue }
  }
  var lastPlaybackDateSample: Date? {
    get { mon.lastPlaybackDateSample }
    nonmutating set { mon.lastPlaybackDateSample = newValue }
  }
  var lastPlaybackTimeSampleSeconds: Double? {
    get { mon.lastPlaybackTimeSampleSeconds }
    nonmutating set { mon.lastPlaybackTimeSampleSeconds = newValue }
  }
  var lastObservedPlaybackTimeSeconds: Double? {
    get { mon.lastObservedPlaybackTimeSeconds }
    nonmutating set { mon.lastObservedPlaybackTimeSeconds = newValue }
  }
  var stalledPlaybackSamples: Int {
    get { mon.stalledPlaybackSamples }
    nonmutating set { mon.stalledPlaybackSamples = newValue }
  }
  var isRecoveringPlayback: Bool {
    get { mon.isRecoveringPlayback }
    nonmutating set { mon.isRecoveringPlayback = newValue }
  }
  var lastRecoveryAttemptAt: Date {
    get { mon.lastRecoveryAttemptAt }
    nonmutating set { mon.lastRecoveryAttemptAt = newValue }
  }
  var lastLiveResyncAt: Date {
    get { mon.lastLiveResyncAt }
    nonmutating set { mon.lastLiveResyncAt = newValue }
  }
  var liveResyncAttempts: Int {
    get { mon.liveResyncAttempts }
    nonmutating set { mon.liveResyncAttempts = newValue }
  }
  var liveStallWaitingSince: Date? {
    get { mon.liveStallWaitingSince }
    nonmutating set { mon.liveStallWaitingSince = newValue }
  }
  /// Highest live seekable-edge position seen this session, and when it last
  /// stopped advancing — used to detect an ended broadcast (the edge freezes)
  /// independently of the flaky waiting/stall state.
  var lastLiveEdgeSeconds: Double? {
    get { mon.lastLiveEdgeSeconds }
    nonmutating set { mon.lastLiveEdgeSeconds = newValue }
  }
  var liveEdgeFrozenSince: Date? {
    get { mon.liveEdgeFrozenSince }
    nonmutating set { mon.liveEdgeFrozenSince = newValue }
  }
  var offlineProbeInFlight: Bool {
    get { mon.offlineProbeInFlight }
    nonmutating set { mon.offlineProbeInFlight = newValue }
  }
  var lastOfflineProbeAt: Date {
    get { mon.lastOfflineProbeAt }
    nonmutating set { mon.lastOfflineProbeAt = newValue }
  }
  var recentInstabilityEvents: [Date] {
    get { mon.recentInstabilityEvents }
    nonmutating set { mon.recentInstabilityEvents = newValue }
  }
  var streamUnstableSince: Date? {
    get { mon.streamUnstableSince }
    nonmutating set { mon.streamUnstableSince = newValue }
  }
  var lastStallAt: Date? {
    get { mon.lastStallAt }
    nonmutating set { mon.lastStallAt = newValue }
  }
  var streamPlaybackStartedAt: Date? {
    get { mon.streamPlaybackStartedAt }
    nonmutating set { mon.streamPlaybackStartedAt = newValue }
  }
  /// When AVPlayer first parked in a "waiting despite a healthy buffer" soft-stall
  /// deadlock, and when we last nudged it. Drives the playImmediately kick that
  /// breaks `evaluatingBufferingRate`/`toMinimizeStalls` parks.
  var softStallSince: Date? {
    get { mon.softStallSince }
    nonmutating set { mon.softStallSince = newValue }
  }
  var lastSoftStallNudgeAt: Date {
    get { mon.lastSoftStallNudgeAt }
    nonmutating set { mon.lastSoftStallNudgeAt = newValue }
  }
  var lastFrozenPlayheadNudgeAt: Date {
    get { mon.lastFrozenPlayheadNudgeAt }
    nonmutating set { mon.lastFrozenPlayheadNudgeAt = newValue }
  }
  var streamUnstableWasPredicted: Bool {
    get { mon.streamUnstableWasPredicted }
    nonmutating set { mon.streamUnstableWasPredicted = newValue }
  }
  /// True while the stream-stability watchdog has us in deep-buffer stability mode.
  var isStreamUnstable: Bool { mon.streamUnstableSince != nil }
  @State var lastControlFocus: Focusable = .quality
  /// Non-nil while chat is "soft paused" (Twitch-style): the list is frozen so
  /// the viewer can read, with a countdown that auto-resumes. A second Up press
  /// promotes it to manual scroll mode. (State now on PlayerModel.)
  let softPauseSeconds = 10
  /// Messages to advance per up/down swipe while scrolling.
  let chatScrollStep = 4
  /// Swipe-to-scroll (Siri Remote trackpad) state. The `trackpad` monitor (now on
  /// `PlayerModel`) reports the finger's position; a loop maps finger *travel* to
  /// scroll position so the chat follows a swipe and holds still when the finger
  /// does. Discrete presses still step (and press-and-hold repeats). (State on PlayerModel.)
  /// Finger position magnitude below this reads as "not touching" (lifted).
  let chatScrollTouchEpsilon: Double = 0.02
  /// Per-frame finger movement below this reads as "resting" (no swipe), so a
  /// held/pressing finger's natural jitter doesn't register as a swipe — which
  /// would otherwise keep resetting the gesture timer and block press-and-hold.
  let chatScrollMoveEpsilon: Double = 0.012
  /// Messages scrolled per unit of finger travel across the trackpad.
  let chatScrollSwipeSensitivity: Double = 16
  /// Per-frame velocity decay once the finger lifts, giving swipes momentum so
  /// the chat coasts and eases to a stop instead of halting dead.
  let chatScrollFriction: Double = 0.94
  /// Below this coasting speed (index-units per frame) momentum is considered
  /// spent and stops.
  let chatScrollMomentumMin: Double = 0.04
  /// Press-and-hold auto-repeat. tvOS won't emit system key-repeat here because
  /// focus is trapped on the composer, so we drive an accelerating repeat
  /// ourselves while the finger stays pressed/down on the pad. (State on PlayerModel.)
  /// Delay after click-down before the continuous hold-scroll engages, so a quick
  /// tap stays a single discrete step.
  let chatHoldInitialDelay: Double = 0.2
  /// Continuous hold-scroll speed (messages per 60Hz frame) at engage time.
  let chatHoldStartVelocity: Double = 0.18
  /// Top speed the hold accelerates to (messages per frame).
  let chatHoldMaxVelocity: Double = 1.4
  /// Per-frame multiplier that ramps the hold speed up (acceleration).
  let chatHoldVelocityAccel: Double = 1.035
  /// When the composer last became focused, used to ignore a stray up-swipe that
  /// rides in on a diagonal move from the chat-toggle button (accidental pause).
  @State var chatInputFocusedAt = Date.distantPast
  /// True while chat is held for reading — either the soft pause or full scroll
  /// mode. The composer keeps real focus throughout, but it should *look*
  /// unfocused so the held chat reads as the thing being interacted with.
  var chatIsFrozen: Bool {
    isChatScrolling || chatSoftPauseRemaining != nil
  }
  @State var lastChatSettingsFocus: Focusable = .chatSettingsButton
  /// Initial focus target for the control row when the chrome appears. The row
  /// is rebuilt from scratch each time controls are revealed, so an explicit
  /// `focus =` set in the same tick is dropped (the buttons don't exist yet) and
  /// tvOS auto-focuses the leftmost control (the channel button). Driving the
  /// row's `.defaultFocus` from this lets a reveal land directly on the intended
  /// button (quality on up, channel on left, etc.) with no leftmost detour.
  @State var pendingControlFocus: Focusable = .quality
  /// Reasserts focus onto the composer after leaving a chat scroll; see
  /// `resumeChatLive(restoreFocus:)`.
  @State var chatExitFocusTask: Task<Void, Never>?
  /// Set for the duration of a deliberate, throttled hop from the collapse button
  /// into the chat input, which momentarily admits the composer to the focus
  /// engine. Cleared as soon as focus returns to a control button so a plain swipe
  /// across the row can never fling into chat.
  @State var chatInputArmed = false
  /// True only when the viewer deliberately asked for the seek bar via an
  /// up-press from a control button. The bar is otherwise kept out of the focus
  /// engine so it can't act as a vertical magnet — a swipe between control
  /// buttons with a slight upward component would otherwise drift focus onto it
  /// (the engine moves focus natively; our up-press guard can't veto that). Reset
  /// the moment focus leaves the bar.
  @State var seekBarRequested = false
  /// A just-activated settings control to briefly defend against tvOS's
  /// transient focus jump when toggling an option resizes the panel.
  @State var chatFocusPin: Focusable?
  @State var chatFocusPinTask: Task<Void, Never>?
  // Raid banner state (incoming/outgoing) now lives in PlayerModel.

  // MARK: Sleep timer (hidden inside the Quality menu)
  // A single countdown task pauses playback after a chosen duration so the
  // Apple TV can sleep when the viewer dozes off. It lives inside the Quality
  // menu (no dedicated button) and surfaces a small top-right countdown badge.
  // Sleep-timer state now lives in PlayerModel.

  // MARK: Stream Rewind → VOD hand-off tuning

  /// How close (seconds) the scrub target must come to the DVR floor before the
  /// player resolves and hands off to the in-progress broadcast VOD. A small lead
  /// so the seam happens just before the viewer hits the hard wall.
  let vodHandoffFloorThresholdSeconds: Double = 8
  /// How close (seconds) the scrub target must come to the VOD's recorded edge
  /// before the player hands back to the live stream.
  let vodReturnEdgeThresholdSeconds: Double = 8
  /// Minimum spacing between in-progress-VOD resolve attempts, so reaching the
  /// floor before the VOD is available retries later without hammering Twitch.
  let broadcastVODResolveCooldownSeconds: Double = 30

  // MARK: Diagnostics (experimental troubleshooting overlay)
  // The diagnostics counters / rolling event log / freeze-tracking state now live
  // on `PlayerModel` and are reached via forwarding accessors.

  let controlsAutoHideSeconds: Double = 10
  /// How much live history the Stream Rewind DVR retains (and therefore how far
  /// back you can scrub). Capped because Twitch's segment URLs eventually age off
  /// its CDN; deeper history is offered via the in-progress VOD ("From Start").
  let rewindWindowSeconds: Double = 1800
  /// Seconds the rewind step buttons jump per press.
  let rewindStepSeconds: Double = 10
  /// Trackpad swipe sensitivity, expressed as how much finger travel it takes to
  /// scrub across the *entire* current seekable window (the surface spans roughly
  /// -1...1, so one firm edge-to-edge swipe ≈ 1.5 units). Scrubbing is therefore
  /// proportional to the window — like YouTube/Apple's players — so a tiny
  /// just-arrived DVR window and a full 30-min one both feel the same instead of
  /// the small one being hypersensitive.
  let scrubFullWindowTravelUnits: Double = 4
  // The latency win comes from the proxy promoting Twitch prefetch segments — not
  // from starving buffers or chasing the edge, both of which caused freezes and
  // blur on-device. Per-mode buffer/ABR behavior lives in LivePlaybackPolicy;
  // this is the shared target gap used by live-edge follow + drift recovery.
  let targetLiveEdgeSeconds: Double = 3.5
  let edgeLatencyUnavailableEpsilonSeconds: Double = 0.2
  let edgeLatencyUnavailableSamples = 4
  let wallClockUnavailableSamples = 4
  let wallClockStaleDateDeltaEpsilonSeconds: Double = 0.08
  let wallClockStalePlaybackAdvanceThresholdSeconds: Double = 0.6
  let resolveTimeoutSeconds: Double = 18
  let startupPlaybackTimeoutSeconds: Double = 14
  let startupPlaybackPollMilliseconds: UInt64 = 500
  let stalledPlaybackThresholdSamples = 6
  /// Warm-up gating for the latency badge. The live-edge gap reads ~0 right
  /// after playback starts and climbs to the true value over a few seconds, so
  /// we keep showing "Estimating latency…" until the reading settles: a couple
  /// of consecutive stable samples above a plausible floor. The max cap means a
  /// genuinely low-latency stream still resolves instead of estimating forever.
  let latencyWarmUpMinSamples = 3
  let latencyWarmUpMaxSamples = 10
  let latencyStableSamplesRequired = 2
  let latencyPlausibleFloorSeconds: Double = 2
  let latencyStableDeltaSeconds: Double = 2
  /// A single latency sample deviating from the smoothed value by at least this
  /// much is treated as a suspect outlier and held back until corroborated.
  let latencyOutlierSeconds: Double = 25
  let latencyOutlierConfirmSamples = 2
  let playbackWatchdogIntervalSeconds: Double = 2
  /// Cadence for the adaptive playback-rate controller. Sub-second so the
  /// anti-stall slow-down can catch a fast buffer drain (a 1 Hz loop reacts too
  /// late — the buffer can empty between samples).
  let rateControlIntervalSeconds: Double = 0.25
  let hardStallRecoverySeconds: Double = 10
  let recoveryCooldownSeconds: Double = 15
  /// Live-edge drift recovery. When the player is following live (`pinnedToLive`)
  /// but the playhead has involuntarily fallen this far behind the seekable edge,
  /// snap it back toward live with a lightweight seek instead of waiting for the
  /// frozen-playhead watchdog (which a slow-playing-after-rewind player defeats).
  /// The live *edge gap* (distance from the playhead to the seekable tail) sits
  /// near 0 in normal playback and only a couple seconds during ordinary rebuffer
  /// jitter, so a gap this large unambiguously means "rewound far back and stuck."
  /// The gentle rate catch-up can't recover a hole this big (1.12× would take
  /// minutes), so seek back directly. Kept well above the ~2s catch-up target so
  /// it never fights ordinary drift.
  let liveEdgeResyncThresholdSeconds: Double = 15
  /// Minimum spacing between lightweight live-edge resync seeks.
  let liveResyncCooldownSeconds: Double = 6
  /// After this many resync seeks fail to hold the edge, escalate to a full reload.
  let maxLiveResyncAttempts = 3
  let stallNotificationDebounceSeconds: Double = 2.5
  /// Stream-stability watchdog. It counts destabilizing events — stalls plus
  /// involuntary backward playhead jumps (an AVPlayer rewind we never request) —
  /// within a rolling window. Reaching the threshold flags the stream as
  /// chronically unstable and switches to deep-buffer stability mode (drop the
  /// prefetch proxy and ride behind the edge instead of chasing it). A struggling
  /// broadcaster encoder trips this; healthy streams effectively never do.
  let unstableEventWindowSeconds: Double = 45
  /// Steady-state: any two destabilizing events in the window trip it (so "2
  /// stalls", "2 jumps", or "1 stall + 1 jump" all qualify).
  let unstableEventThreshold = 2
  /// During the opening seconds of a stream a single event trips it, so a stream
  /// that stutters the moment you arrive is stabilized almost immediately instead
  /// of making you watch it sort itself out.
  let unstableStartupEventThreshold = 1
  let unstableStartupGraceSeconds: Double = 12
  /// On entering stability mode, seek back to roughly this far behind the live
  /// edge to build a cushion (and skip past a stuck near-edge segment). Only used
  /// when the proxy was already off; otherwise a reload repositions the timeline.
  let stabilityTargetBehindEdgeSeconds: Double = 20
  /// Predictive stability: the proxy (`LowLatencyHLSProxy`) analyzes each HLS
  /// media-playlist refresh and latches a `predictedUnstable` verdict when a
  /// struggling encoder's manifests show structural trouble (media-sequence
  /// stalls, irregular `#EXTINF`, recurring discontinuities) in the opening
  /// refreshes. The watchdog polls that verdict here and trips the same
  /// `enterStreamStabilityMode()` path *before* the viewer sits through stalls.
  /// The scoring thresholds live next to the data they score, as the
  /// `static let`s on `LowLatencyHLSProxy`.
  /// How long the player may sit unable to play (waiting on a starved buffer)
  /// before we authoritatively ask Twitch whether the channel is still live.
  /// Short enough to surface an ended broadcast promptly, long enough that a
  /// brief transient buffer dip won't trigger a needless GraphQL probe.
  let offlineProbeStallSeconds: Double = 6
  /// Minimum spacing between authoritative offline probes while still stuck.
  let offlineProbeCooldownSeconds: Double = 8
  /// End-of-stream detection by a frozen live edge. A live broadcast keeps
  /// appending segments, so its seekable edge advances; an ended one freezes it.
  /// Once the edge hasn't advanced for this long while we're trying to follow
  /// live, ask Twitch whether the channel is still up (this is independent of the
  /// waiting/stall state, which the anti-stall slow-down keeps flickering). A
  /// merely-struggling stream still advances its edge, so it won't trip this.
  let endOfStreamEdgeFrozenSeconds: Double = 8
  /// Safety net for when Twitch's status lookup keeps returning `.unknown` for an
  /// ended stream: if the edge has been frozen this long AND the buffer is empty,
  /// surface the offline state anyway rather than sit on a dead frame forever.
  /// Kept tight (a frozen edge + drained buffer is an unmistakably dead stream)
  /// so the viewer reaches the offline screen — with its Try Again button —
  /// quickly instead of staring at a frozen final frame.
  let endOfStreamEdgeForceOfflineSeconds: Double = 12
  /// Fast end-of-stream force-offline for the unambiguous "ended" signature: the
  /// live edge has stopped advancing AND playback is hard-stalled on a starved
  /// buffer. A struggling-but-live stream keeps advancing its edge (clearing the
  /// freeze timer) and a deep-buffer stability ride stays non-starved, so neither
  /// trips this. Kept below the hard-stall reload window so a dead stream surfaces
  /// offline before a (futile) recovery reload can reset the freeze timer.
  let endOfStreamStalledForceOfflineSeconds: Double = 8
  /// Soft-stall deadlock recovery. AVPlayer can park in
  /// `.waitingToPlayAtSpecifiedRate` (reason `.evaluatingBufferingRate` or
  /// `.toMinimizeStalls`) even while it holds a perfectly healthy forward buffer:
  /// it decides the network might not sustain the rate and then never re-evaluates
  /// on its own, because our adaptive-rate controller only issues a play command
  /// when the *target rate changes* (here it stays 1.0×). The playhead creeps,
  /// behind-live grows without bound, yet no buffer-empty hard-stall path fires.
  /// We detect "waiting despite a healthy buffer" and kick it with playImmediately.
  /// Minimum forward buffer that makes a `.waitingToPlayAtSpecifiedRate` state a
  /// deadlock to break rather than a legitimate rebuffer to wait out.
  let softStallBufferFloorSeconds: Double = 1.5
  /// How long the player may sit waiting-with-healthy-buffer before the first nudge
  /// (a brief wait right after a seek/start is normal and shouldn't be kicked).
  let softStallNudgeSeconds: Double = 3
  /// If repeated nudges can't break the deadlock within this long, reload — which
  /// also re-lands near live, recovering the latency that grew while we were stuck.
  let softStallReloadSeconds: Double = 12
  /// Buffer-agnostic frozen-playhead failsafe. The hard- and soft-stall paths each
  /// classify the buffer (empty / not-likely-to-keep-up, or a *known* forward
  /// reading at/above the soft floor). AVPlayer's `toMinimizeStalls` deadlock can
  /// satisfy neither: it parks `.waitingToPlayAtSpecifiedRate` while reporting the
  /// buffer non-empty *and* likely to keep up, yet our own forward-buffer reading
  /// is unknown (no loaded range spans the playhead) — so the soft-stall floor
  /// check fails and the playhead simply freezes with nothing recovering it for
  /// tens of seconds. This catches that gap on a fast timer: nudge with
  /// playImmediately first (cheap, no rebuffer/latency reset — usually enough to
  /// break the park), then reload as a backstop. Only runs while the live edge is
  /// still advancing (a genuine still-live broadcast, not an ended one — the
  /// offline paths own that), so it never reload-loops a dead stream.
  let frozenPlayheadNudgeSeconds: Double = 2
  let frozenPlayheadReloadSeconds: Double = 5
  // Diagnostics: how much unexplained playhead movement between 1s samples counts
  // as a "jump". Catch-up rate nudges (≤1.05x) only add a fraction of a second,
  // so a multi-second drift is a genuine AVPlayer skip, not normal catch-up.
  let diagJumpForwardThresholdSeconds: Double = 2.0
  let diagJumpBackwardThresholdSeconds: Double = 1.0
  /// Decode-freeze watchdog. AVPlayer can keep its playback clock running — so
  /// `currentTime()` advances, the buffer stays healthy and `timeControlStatus`
  /// reads `.playing` (or flickers into an `evaluatingBufferingRate` wait while
  /// catch-up re-targets the rate) — while the video decoder is wedged and no new
  /// frames reach the screen (the picture freezes but PROGRAM-DATE-TIME-synced
  /// captions and chat keep scrolling, even running ahead of the frozen picture).
  /// None of the playhead/buffer/edge watchdogs can see this; only the video
  /// output can. Once the clock has advanced this long with zero fresh frames,
  /// reload through the same cooldown-gated failsafe path as a hard stall. Kept
  /// above ordinary decode jitter so a brief hiccup during a quality switch or an
  /// ad discontinuity never reloads, but low enough to recover promptly.
  let videoDecodeFreezeRecoverySeconds: Double = 5
  let chatReplayMessageCount = 30
  let chatComposerRowHeight: CGFloat = 62

  @FocusState var focus: Focusable?
  // FOCUS CONTRACT: see `isChatSettingsFocus(_:)` below. Every focusable control
  // in the player/chat-settings panel needs a unique case here, must pass it as
  // its `focusTag`, and must be registered in that allow-list — otherwise tvOS
  // can't land focus on it and traps on a neighbor.
  enum Focusable: Hashable {
    case video, streamInfo, quality, chatToggle, chatInput, errorBack
    case offlineViewChannel, offlineTryAgain
    case chatSend
    /// VOD-only: invisible target inside the chat pane that holds focus while the
    /// viewer pauses/scrolls chat replay (reached by pressing right off the
    /// collapse-chat button).
    case chatScroller
    case raidFollowCancel
    case sleepKeepWatching, sleepResume
    case chatSettingsButton
    // Stream Rewind transport bar
    case rewindScrubber
    // Main settings page
    // ⚠️ Every chat-settings (`chat*` / *Merge*) case below must also be listed
    // in `isChatSettingsFocus(_:)` (PlayerView+BottomOverlay.swift), or focus
    // will bounce off the control. See that function's doc comment.
    case chatPresetOption(Int)
    case chatAdvancedButton
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
    case chatCaptionsToggle
    case chatCaptionsBackgroundOption(Int)
    case chatCaptionsColorOption(Int)
    case chatCaptionsOutlineToggle
    case chatCaptionsShadowToggle
    case chatCaptionsWeightOption(Int)
    case chatSyncToggle
    case youtubeMergeToggle
    case youtubeMergeURL
    case kickMergeToggle
    case kickMergeURL
    // Events sub-page
    case chatEventsButton
    case chatRaidEventToggle
    case chatHypeTrainEventToggle
    case chatPollEventToggle
    case chatPredictionEventToggle
    case chatGoalEventToggle
    // Advanced settings page
    case chatAdvancedBack
    case chatStepperDec(ChatStepperField)
    case chatStepperInc(ChatStepperField)
    case chatEmoteAutoToggle
    case chatAnimatedToggle
    case chatFontOption(Int)
    case chatBadgesToggle
    case chatPlatformBadgesToggle
    case chatHighlightToggle
    case chatHighlightKeywords
    case chatResetButton
  }

  /// Which page of the chat settings panel is currently shown.
  enum ChatSettingsPage: Hashable {
    /// Top-level: presets, layout, multistream, and drill-in rows.
    case main
    /// Fine-grained version of the Size preset (text/emote/line/spacing).
    case appearance
    /// Per-event visibility toggles (raids, hype trains, polls, etc.).
    case events
    /// On-device live captions ("Captions (beta)"), opened standalone from the
    /// native Playback menu's "Caption Options…".
    case captions
  }

  /// The granular dimensions adjusted by the Advanced page steppers.
  enum ChatStepperField: Hashable {
    case text
    case emote
    case lineHeight
    case letterSpacing
    case messageSpacing
    case width
    // Caption settings sub-page steppers.
    case captionFontSize
    case captionPosition
    case captionTiming
    case captionOpacity
  }

  var chatTextSize: CGFloat {
    CGFloat(chatTextSizeValue)
  }

  var chatLineHeight: CGFloat {
    CGFloat(chatLineHeightValue)
  }

  var chatLetterSpacing: CGFloat {
    CGFloat(chatLetterSpacingValue)
  }

  var chatMessageSpacing: CGFloat {
    CGFloat(chatMessageSpacingValue)
  }

  /// Normalized highlight keywords: split on commas/newlines, trimmed,
  /// lowercased, de-duplicated, empties dropped.
  var chatHighlightKeywordList: [String] {
    var seen = Set<String>()
    var out: [String] = []
    for piece in chatHighlightKeywords.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
      let token = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !token.isEmpty, seen.insert(token).inserted else { continue }
      out.append(token)
    }
    return out
  }

  /// Resolved emote height: derived from the text size in Auto mode, otherwise
  /// the explicit stored value.
  var chatEmoteSize: CGFloat {
    chatEmoteAuto
      ? ChatAppearance.autoEmoteHeight(forTextSize: chatTextSize)
      : CGFloat(chatEmoteSizeValue)
  }

  /// The active readability preset, or `nil` when the values are "Custom".
  var activeChatPreset: ChatAppearancePreset? {
    ChatAppearancePreset.resolve(
      textSize: chatTextSize,
      lineHeight: chatLineHeight,
      messageSpacing: chatMessageSpacing,
      emoteIsAuto: chatEmoteAuto
    )
  }

  var chatLayoutMode: ChatLayoutMode {
    ChatLayoutMode(rawValue: chatLayoutModeRaw) ?? .side
  }

  var chatWidth: CGFloat {
    CGFloat(chatWidthValue)
  }

  var chatFontStyle: ChatFontStyle {
    ChatFontStyle(rawValue: chatFontStyleRaw) ?? .standard
  }

  /// The chat list driving both rendering and scroll math. While the viewer is
  /// reading/scrolling we serve a frozen snapshot (see `chatFrozenMessages`) so
  /// the list can't shift; otherwise it's the live, growing buffer.
  var visibleChatMessages: [ChatMessage] {
    if let chatFrozenMessages { return chatFrozenMessages }
    return liveVisibleChatMessages
  }

  /// The live chat buffer, windowed to the replay start when chat was toggled
  /// open mid-stream. This is what gets snapshotted into `chatFrozenMessages`.
  var liveVisibleChatMessages: [ChatMessage] {
    if isVOD { return replay.messages }
    guard let startID = chatReplayStartMessageID else { return chat.messages }
    guard let startIndex = chat.messages.firstIndex(where: { $0.id == startID }) else {
      return chat.messages
    }
    return Array(chat.messages[startIndex...])
  }

  /// Trailing inset for the bottom control bar so its right-aligned buttons
  /// stay clear of (to the left of) the chat panel when chat floats over the
  /// full-width video in overlay/glass mode. In side mode the controls live in
  /// the shrunken video column, so the default edge padding is enough.
  var controlsTrailingInset: CGFloat {
    guard showChat, chatLayoutMode.isOverlay else { return 48 }
    let gap: CGFloat = 24
    switch chatLayoutMode {
    case .glass:
      return chatWidth + GlassChatPaneStyle.edgeInset + gap
    case .overlay:
      return chatWidth + gap
    case .side:
      return 48
    }
  }

  /// Trailing inset for the full-bleed loading surface so it occupies only the
  /// *uncovered* video region instead of stretching the full screen under the
  /// (often translucent) chat in overlay/glass modes — which made the loading
  /// art read as fullscreen even though the video is sharing the screen with
  /// chat. Side mode already shrinks the video column, so no inset is needed.
  var loadingChatInset: CGFloat {
    guard showChat, chatLayoutMode.isOverlay else { return 0 }
    switch chatLayoutMode {
    case .glass:
      return chatWidth + GlassChatPaneStyle.edgeInset
    case .overlay:
      return chatWidth
    case .side:
      return 0
    }
  }

  var body: some View {
    ZStack {
      palette.playerBackdrop.ignoresSafeArea()
        // Attached to the backdrop (a child) rather than the root ZStack so it
        // doesn't collide with the sign-in `.fullScreenCover` below. Two
        // presentation modifiers on the *same* view conflict on tvOS and only
        // one fires, which previously left the avatar button doing nothing.
        .fullScreenCover(item: $channelPageTarget, onDismiss: { resumeAfterChannelPage() }) {
          target in
          ChannelPageView(
            target: target,
            onWatchChannel: { channel in
              // Tapping the live card of the channel we're already watching just
              // resumes playback; picking a *different* channel (e.g. from the
              // "More like this" rail) switches the player to it on dismiss.
              if channel.login.caseInsensitiveCompare(activeChannel) != .orderedSame {
                pendingSwitchLogin = channel.login
              }
              channelPageTarget = nil
            }
          )
          .environment(\.themePalette, palette)
        }

      if chatLayoutMode.isOverlay {
        videoColumn
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .ignoresSafeArea()

        if showChat {
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            chatPane
          }
          .ignoresSafeArea()
          .transition(.move(edge: .trailing))
        }
      } else {
        HStack(spacing: 0) {
          videoColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          if showChat {
            chatPane
              .transition(.move(edge: .trailing))
          }
        }
        .ignoresSafeArea()
      }

      if showRaidEvents, let raid = chat.pendingRaid, shouldShowIncomingRaid(raid) {
        raidBanner(raid)
          .transition(.motionAware(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
          .zIndex(10)
      }

      if let raid = outgoingRaid {
        outgoingRaidBanner(raid)
          .transition(.motionAware(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
          .zIndex(11)
      }

      if showStillWatching, !isSleeping {
        stillWatchingBanner()
          .transition(.motionAware(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
          .zIndex(12)
      }

      // Live polls / predictions / hype trains / goals are surfaced docked above
      // the chat list (see `chatPane`) so they share the chat's width and glass
      // treatment and only appear when chat is open — matching how Twitch shows
      // them beside the stream. Read-only.

      if let goLive, let event = goLive.pending {
        goLiveToast(goLive, event: event)
          .transition(.motionAware(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
          .zIndex(13)
      }

      if isSleeping {
        sleepingOverlay
          .transition(.opacity)
      }
    }
    // Render the whole player tree in the app theme's color scheme so native
    // Liquid Glass, materials, and `.buttonStyle(.glass)` pills go
    // light-but-translucent in the Light theme (with transparency on), instead
    // of always rendering dark. No-op for dark/OLED (already `.dark`).
    .environment(\.colorScheme, palette.chromeColorScheme)
    .animation(.motionAware(.easeInOut(duration: 0.35), reduceMotion: reduceMotion), value: hermes.currentMoment)
    .animation(.motionAware(.easeOut(duration: 0.25), reduceMotion: reduceMotion), value: goLive?.pending)
    .onChange(of: chat.pendingRaid) { _, newRaid in
      // Incoming raids (someone raiding the channel you're watching) are purely
      // informational: show a passive banner and auto-dismiss it. We never steal
      // focus or offer to "follow", because following would take you away from
      // the channel that is actually being raided.
      guard let newRaid else {
        incomingRaidAvatarURL = nil
        return
      }
      // Filter out raids too small to matter for the size of the channel you're
      // on (e.g. a 1-viewer raid into a 250k-viewer stream): drop them silently.
      guard shouldShowIncomingRaid(newRaid) else {
        chat.pendingRaid = nil
        return
      }
      // Resolve the raider's channel avatar so the banner can show who's raiding,
      // mirroring the go-live toast. Best-effort: the banner renders immediately
      // with a placeholder and fills in the icon once it arrives.
      incomingRaidAvatarURL = nil
      Task {
        guard let metadata = await PlaybackService.channelMetadata(for: newRaid.login) else { return }
        guard chat.pendingRaid?.login == newRaid.login else { return }
        incomingRaidAvatarURL = metadata.profileImageURL
      }
      raidBannerDismissTask?.cancel()
      raidBannerDismissTask = Task {
        try? await Task.sleep(for: .seconds(12))
        guard !Task.isCancelled else { return }
        withAnimation { chat.pendingRaid = nil }
      }
    }
    .onChange(of: eventSub.pendingOutgoingRaid) { _, newRaid in
      // Outgoing raids (the channel you're watching raiding someone else):
      // mirror Twitch's native behavior and follow by default, but give a brief
      // cancelable window first.
      guard let newRaid else { return }
      beginOutgoingRaidFollow(newRaid)
    }
    .onChange(of: isOffline) { _, offline in
      // "End of current stream" sleep mode: when the channel goes offline, let
      // the device sleep (the offline empty-state is already shown, so no extra
      // overlay is needed).
      guard offline, sleepUntilStreamEnds else { return }
      sleepUntilStreamEnds = false
      sleepSelectionIndex = 0
      sleepRemainingSeconds = nil
      setIdleTimer(disabled: false)
    }
    .onChange(of: showStillWatching) { _, showing in
      // Pull focus to the "Keep watching" button so an awake viewer can dismiss
      // the pending sleep with a single press. Cancel the quality menu's focus
      // recovery first so it can't yank focus back to the quality button (this
      // matters when a short test timer surfaces the banner right as the menu
      // is still closing).
      if showing {
        focusRecoveryTask?.cancel()
        focus = .sleepKeepWatching
      }
    }
    .task {
      if activeChannel.isEmpty { activeChannel = channel }
      if isVOD {
        await startVOD()
      } else {
        // Don't toast the channel we're already watching.
        goLive?.suppressedLogin = activeChannel
        configurePlayerForLive()
        resetDiagnostics()
        applyExperimentalYouTubeSettings()
        applyExperimentalKickSettings()
        chat.connect(to: activeChannel)
        eventSub.start(forChannel: activeChannel, auth: auth)
        hermes.start(forChannel: activeChannel)
        async let metadataTask: Void = refreshChannelMetadata()
        await load()
        _ = await metadataTask
      }
      focus = .video
    }
    .onAppear {
      setIdleTimer(disabled: true)
      trackpad.start()
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) {
      notification in
      guard let stalledItem = notification.object as? AVPlayerItem else { return }
      guard stalledItem == player.currentItem else { return }
      // Ignore stalls while intentionally paused or scrubbing for DVR rewind.
      guard !isUserPaused, !isScrubbing else { return }
      let now = Date()
      guard now.timeIntervalSince(lastStallNotificationAt) >= stallNotificationDebounceSeconds
      else { return }
      lastStallNotificationAt = now
      markDiagnosticsStall(reason: "AVPlayerItemPlaybackStalled")
      // Re-kick immediately. With automaticallyWaitsToMinimizeStalling the player
      // usually self-resumes once buffered, but an explicit nudge shortens the
      // gap and helps the player that has stalled without auto-resuming.
      player.playImmediately(atRate: 1.0)
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
      notification in
      guard let endedItem = notification.object as? AVPlayerItem else { return }
      guard endedItem == player.currentItem else { return }
      // Ignore while intentionally paused or scrubbing for DVR rewind.
      guard !isUserPaused, !isScrubbing else { return }
      // A live HLS that ends with #EXT-X-ENDLIST plays to the very end and then
      // pauses here on a frozen final frame. Confirm with Twitch and surface the
      // offline empty state instead of leaving the viewer on a dead frame.
      probeOfflineIfStreamEnded()
    }
    .onDisappear {
      hideTask?.cancel()
      focusRecoveryTask?.cancel()
      chatSyncSendClearTask?.cancel()
      outgoingRaidFollowTask?.cancel()
      softPauseTask?.cancel()
      trackpadScrollTask?.cancel()
      chatHoldTask?.cancel()
      trackpad.stop()
      sleepTimerTask?.cancel()
      stopPlaybackWatchdog()
      stopLatencyMonitor()
      stopScrubInput()
      audioLevelMonitor.stop()
      removeVODTimeObserver()
      replay.stop()
      player.pause()
      player.replaceCurrentItem(with: nil)
      captionController.stop()
      chat.disconnect()
      eventSub.stop()
      hermes.stop()
      // Hand go-live suppression back to Home now that no channel is on screen.
      goLive?.suppressedLogin = nil
      setIdleTimer(disabled: false)
    }
    .onExitCommand {
      if isSleeping {
        wakeFromSleep()
      } else if isChatScrolling || chatSoftPauseRemaining != nil {
        // Deliberate exit from a chat scroll: land focus on the composer (live)
        // / collapse button (VOD), reasserting past the control row rejoining the
        // focus engine so it can't bounce to the far-side channel button.
        resumeChatLive(restoreFocus: true)
      } else if showChatSettings {
        if chatSettingsPage != .main {
          closeSubpage()
        } else {
          showChatSettings = false
          focus = .chatSettingsButton
        }
      } else if showControls {
        hideControls()
      } else {
        dismiss()
      }
    }
    .onMoveCommand { direction in
      // While actively scrolling with the chrome hidden, route every directional
      // input through the scroll handler (and swallow horizontal) so a stray
      // swipe can't surface the chrome and bump you out of the scroll.
      if !showControls, showChat, isChatScrolling {
        switch direction {
        case .up: handleChatUpPress()
        case .down: handleChatDownPress()
        default: break
        }
        return
      }
      if !showControls {
        // From the bare video (chrome hidden) a directional press surfaces the
        // controls and lands focus deliberately rather than letting the focus
        // engine pick a magnet: up → the middle of the control row
        // (quality/speed), left → the channel button, right → the chat composer
        // (opening chat if it's hidden). Down rejoins an in-progress chat scroll,
        // otherwise it just surfaces the controls. Chat scrolling is only ever
        // *started* from inside chat (an up-press on the composer) — never by a
        // bare up-swipe here, which used to dive straight into the scroll area
        // without ever focusing the input.
        guard !isOffline else {
          scheduleHide()
          return
        }
        switch direction {
        case .up:
          pendingControlFocus = .quality
          revealControls(preferredFocus: .quality)
        case .left:
          pendingControlFocus = .streamInfo
          revealControls(preferredFocus: .streamInfo)
        case .right:
          if !showChat {
            showChat = true
            chatReplayStartMessageID = chat.messages.suffix(chatReplayMessageCount).first?.id
          }
          // Land on the chat composer (already mounted, so this sticks). Point
          // the row's default at the collapse button so a later move into the
          // row from chat is sensible.
          pendingControlFocus = .chatToggle
          revealControls(preferredFocus: chatFocusAnchor)
        case .down where showChat && (isChatScrolling || chatSoftPauseRemaining != nil):
          handleChatDownPress()
        default:
          pendingControlFocus = .quality
          revealControls(preferredFocus: .quality)
        }
      } else {
        scheduleHide()
      }
    }
    .onChange(of: focus) { oldFocus, newFocus in
      // Disarm the chat-input hop the moment focus is back on a control button, so
      // the composer drops out of the engine again and a plain swipe can't reach it.
      if isControlRowButton(newFocus), chatInputArmed {
        chatInputArmed = false
      }
      // The seek bar is only focusable while requested/held; once focus leaves it
      // (e.g. a down-press back to a control) drop it out of the engine again so
      // it can't be a vertical magnet on the next swipe.
      if oldFocus == .rewindScrubber, newFocus != .rewindScrubber, seekBarRequested {
        seekBarRequested = false
      }
      // Start/stop precision trackpad scrubbing as the rewind bar gains/loses
      // focus. The analog jog (GameController + display link) only runs while the
      // bar is focused so it never competes with normal control navigation.
      if newFocus == .rewindScrubber, oldFocus != .rewindScrubber {
        startScrubInput()
      } else if oldFocus == .rewindScrubber, newFocus != .rewindScrubber {
        stopScrubInput()
      }
      // Track when the composer becomes focused so an up-swipe that rides in on
      // a diagonal move from the chat-toggle button can't accidentally pause.
      if newFocus == .chatInput, oldFocus != .chatInput {
        chatInputFocusedAt = Date()
      }
      // VOD: moving focus into the chat scroller (right off the collapse button)
      // immediately surfaces the paused indicator, and leaving it resumes the
      // replay's auto-scroll — so chat pause/scroll is driven purely by focus.
      if isVOD {
        if newFocus == .chatScroller, oldFocus != .chatScroller {
          chatInputFocusedAt = Date()
          if !isChatScrolling, chatSoftPauseRemaining == nil { startSoftPause() }
        } else if oldFocus == .chatScroller, newFocus != .chatScroller {
          if isChatScrolling || chatSoftPauseRemaining != nil { resumeChatLive() }
        }
      }
      // Keep the swipe target stable while chat is held.
      if isChatScrolling {
        // Active scroll traps focus on the composer so a stray diagonal swipe
        // can't jump to a control and silently end the scroll. The only
        // exception is `.video`, which is the page-level handler that drives
        // scrolling while the chrome is hidden. Exit is via Back or scrolling
        // back to the bottom.
        if let newFocus, newFocus != chatFocusAnchor, newFocus != .video {
          focus = chatFocusAnchor
        }
      } else if chatSoftPauseRemaining != nil {
        // Lightweight read pause: navigating away to a real control resumes live
        // so the frozen state can't get stranded.
        if let newFocus, newFocus != chatFocusAnchor, isControlFocus(newFocus) {
          resumeChatLive()
        }
      }

      if showChatSettings {
        guard let newFocus else {
          focus = chatFocusPin ?? lastChatSettingsFocus
          return
        }

        // A control was just activated: defend it against the transient focus
        // jump tvOS performs when toggling an option resizes the panel, which
        // dumps focus onto the section's first focusable (the back button). We
        // only revert that specific spurious target so deliberate navigation to
        // any other control is never fought, and consume the pin after one move.
        if let pin = chatFocusPin, newFocus != pin {
          chatFocusPin = nil
          chatFocusPinTask?.cancel()
          if newFocus == firstChatSettingsFocus {
            focus = pin
            return
          }
        }

        if isChatSettingsFocus(newFocus) {
          lastChatSettingsFocus = newFocus
        } else {
          // Focus landed on something the chat-settings registry doesn't know,
          // so bounce back to the last good control. If you just added a control
          // to the settings panel and it won't hold focus, the cause is almost
          // certainly a missing case in `isChatSettingsFocus(_:)` — this is the
          // recurring trap. Surface it loudly in debug builds.
          #if DEBUG
          if showChatSettings, newFocus != .video {
            print(
              "⚠️ [chat-settings focus] '\(newFocus)' is not registered in "
                + "isChatSettingsFocus(_:), so focus is bouncing off it. Add this "
                + "case to that switch in PlayerView+BottomOverlay.swift."
            )
          }
          #endif
          focus = lastChatSettingsFocus
        }
        return
      }

      // Keep control navigation deterministic: if tvOS drops focus to nil
      // while controls are visible, immediately restore last valid control.
      guard showControls else {
        return
      }

      if let newFocus, isControlFocus(newFocus) {
        focusRecoveryTask?.cancel()
        lastControlFocus = newFocus
        scheduleHide()
      } else if newFocus == nil, !isQualityMenuPresented {
        // tvOS can briefly drop focus to nil after system surfaces (like Menu)
        // dismiss. Re-assert the last control if focus doesn't come back.
        focusRecoveryTask?.cancel()
        let target = lastControlFocus
        focusRecoveryTask = Task {
          try? await Task.sleep(for: .milliseconds(140))
          guard !Task.isCancelled else { return }
          await MainActor.run {
            guard showControls, !showChatSettings, !isQualityMenuPresented else { return }
            guard focus == nil else { return }
            focus = target
          }
        }
      }
    }
    .onChange(of: experimentalYouTubeMergeEnabled) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: experimentalYouTubeMergeChannelOrURL) { _, _ in
      applyExperimentalYouTubeSettings()
    }
    .onChange(of: experimentalKickMergeEnabled) { _, _ in
      applyExperimentalKickSettings()
    }
    .onChange(of: experimentalKickMergeChannelOrURL) { _, _ in
      applyExperimentalKickSettings()
    }
    .onChange(of: activeChannel) { _, _ in
      // A manual override is scoped to the channel it was entered for; clear it
      // when the channel changes (e.g. following a raid) so it can't leak.
      experimentalYouTubeMergeChannelOrURL = ""
      youtubeAutoResolvedTarget = ""
      // The alternate (YouTube) source is per-channel; drop it on a channel
      // change so a stale simulcast URL can't leak into the next stream.
      isUsingAltSource = false
      altYouTubeMasterURL = nil
      altSourceStatus = nil
      youtubeSourceAvailable = false
      youtubeViewerCount = nil
      // Auto-default vs. manual intent is per-channel: clear the manual flag so
      // the "prefer YouTube" auto-default can apply once on the new channel.
      didManuallySelectSource = false
      experimentalKickMergeChannelOrURL = ""
      kickAutoResolvedTarget = ""
      // The rewind window is per-stream: drop the previous channel's DVR history.
      lowLatencyProxy.resetDVR()
      // …and any resolved/active hand-off into the previous channel's VOD.
      resetVODHandoff()
      isUserPaused = false
      // Keep the go-live watcher from toasting whatever we just switched to.
      goLive?.suppressedLogin = activeChannel
    }
    .task(id: activeChannel) {
      await refreshYouTubeAutoTarget()
    }
    .task(id: activeChannel) {
      await refreshYouTubeSourceAvailability()
    }
    .task(id: activeChannel) {
      await refreshKickAutoTarget()
    }
    .onChange(of: lowLatencyProxyEnabled) { _, _ in
      guard !isVOD else { return }
      if suppressLowLatencyToggleReload {
        suppressLowLatencyToggleReload = false
        return
      }
      // Rebuild the asset pipeline so the proxy is attached/detached cleanly.
      configurePlayerForLive()
      Task { await load(reason: "lowLatencyToggle", resetMetadata: false) }
    }
    .onChange(of: streamRewindEnabled) { _, _ in
      guard !isVOD else { return }
      // Toggling Stream Rewind changes whether the proxy retains history (and,
      // when low-latency is off, whether the proxy is attached at all), so
      // rebuild the pipeline from a clean DVR state.
      lowLatencyProxy.resetDVR()
      configurePlayerForLive()
      Task { await load(reason: "rewindToggle", resetMetadata: false) }
    }
    .onChange(of: captionsEnabled) { _, _ in syncCaptions() }
    .onChange(of: captionsTimingOffset) { _, _ in syncCaptions() }
    .onChange(of: captionAudioSourceURL) { _, _ in syncCaptions() }
    // Switching between the Twitch and YouTube simulcast sources changes which
    // stream's audio the captions must transcribe; re-sync so captions follow
    // the active source (and recover when switching back to Twitch).
    .onChange(of: isUsingAltSource) { _, _ in syncCaptions() }
    .onChange(of: isLoading) { _, _ in syncCaptions() }
    .onChange(of: isOffline) { _, _ in syncCaptions() }
    .fullScreenCover(isPresented: $showSignInSheet) {
      SignInView(auth: auth)
    }
  }

  // MARK: - Video + controls

  /// True when the user has explicitly pinned the audio-only rendition, so the
  /// player surface is black and the visualizer should take over.
  var isAudioOnlyActive: Bool {
    guard let playback else { return false }
    guard let audioName = playback.qualities.first(where: { $0.isAudioOnly })?.name else {
      return false
    }
    return audioName == preferredQuality
  }

  /// Direct media-playlist URL for the audio-only rendition, used by the
  /// visualizer's level decoder.
  var audioOnlyPlaylistURL: URL? {
    playback?.qualities.first(where: { $0.isAudioOnly })?.url
  }

  /// Playlist the caption engine pulls audio from. Prefers the dedicated
  /// audio-only rendition (least bandwidth), but **falls back to the
  /// lowest-bitrate video rendition** when a stream doesn't publish an
  /// audio-only variant — without this, captions silently never start on those
  /// streams, which is the "works on some streams, not others" inconsistency.
  /// Any rendition carries the same audio track, so the lowest one is the
  /// cheapest usable source.
  ///
  /// When the YouTube simulcast is the active source, captions must transcribe
  /// **that** stream's audio, not Twitch's — so we hand the engine the YouTube
  /// master playlist (it resolves a media/audio rendition itself). Pointing the
  /// engine at the Twitch audio while YouTube plays is why captions appeared
  /// broken on the YouTube source.
  var captionAudioSourceURL: URL? {
    if isUsingAltSource { return altYouTubeMasterURL }
    guard let qualities = playback?.qualities, !qualities.isEmpty else { return nil }
    if let audioOnly = qualities.first(where: { $0.isAudioOnly }) {
      return audioOnly.url
    }
    return qualities.min(by: { $0.bitrate < $1.bitrate })?.url
  }

  /// HTTP headers the caption engine uses to fetch its audio playlist/segments.
  /// Must match the identity of the active source: the YouTube simulcast needs a
  /// browser User-Agent (googlevideo blocks the default UA), Twitch needs its
  /// player Referer/Origin.
  var captionAudioSourceHeaders: [String: String] {
    isUsingAltSource ? Self.altSourceHTTPHeaders : PlaybackService.streamHeaders
  }

  /// Reconcile the on-device caption engine with current playback state. Cheap
  /// to call from multiple hooks — the controller no-ops on unchanged inputs.
  /// Live-only: captioning rides the audio-only side-channel, which doesn't
  /// exist for VOD/clip playback.
  func syncCaptions() {
    captionController.sync(
      enabled: captionsEnabled,
      playlistURL: captionAudioSourceURL,
      headers: captionAudioSourceHeaders,
      isLive: !isVOD,
      isReady: !isLoading && errorMessage == nil && !isOffline,
      timingOffset: captionsTimingOffset,
      playerClock: { [weak player] in player?.currentItem?.currentDate() }
    )
  }


  // MARK: - Chat layout constants (stored; must live on the struct)
  let chatSettingsPanelWidth: CGFloat = 560
  let chatSettingsPanelGap: CGFloat = 16
  /// Measured height of the right-side control buttons row. The stream title is
  /// capped to this so a long (2-line) title can't grow the row and shove the
  /// buttons up off their fixed position — instead the title stays vertically
  /// centered against the buttons.
  @State var controlButtonsHeight: CGFloat = 0
  /// Approximate on-screen height the rewind scrub bar adds beneath the control
  /// row: the bar's own height (~68pt) plus the control VStack's 18pt spacing.
  let scrubBarClusterHeight: CGFloat = 86
}

