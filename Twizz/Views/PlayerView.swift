import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// AVPlayer host that is intentionally non-interactive: Twizz handles all remote
/// input in SwiftUI and never lets AVKit consume transport/scrub commands.
private final class PassivePlayerViewController: AVPlayerViewController {
  override var canBecomeFirstResponder: Bool { false }
}

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twizz UI while preserving Apple's media rendering paths
/// better than a raw `AVPlayerLayer`.
struct VideoSurface: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = PassivePlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    // Keep output mode stable while toggling in-app layouts (chat on/off).
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    // Prevent AVKit's internal gesture/press recognizers from handling Siri
    // Remote input (seek/scrub/skip). Twizz UI remains fully interactive.
    controller.view.isUserInteractionEnabled = false
    controller.view.backgroundColor = .black
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    controller.view.isUserInteractionEnabled = false
  }
}

/// A `UIView` whose backing layer *is* an `AVPlayerLayer`, so corner rounding is
/// applied on the exact layer that composites the video.
final class PlayerLayerHostView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Lightweight, controls-free video surface for rounded preview tiles.
///
/// Rounding an *ancestor* of the video — SwiftUI's `.clipShape` or an enclosing
/// `AVPlayerViewController` view layer — leaves a sub-pixel "bleed" at the
/// corners on tvOS, because the video composites in its own pass and isn't
/// affected by the ancestor's mask. Applying `cornerRadius` + `masksToBounds`
/// directly on the `AVPlayerLayer` clips the video at the layer that actually
/// renders it, which removes the fringe.
struct PreviewVideoSurface: UIViewRepresentable {
  let player: AVPlayer
  var cornerRadius: CGFloat = 0

  func makeUIView(context: Context) -> PlayerLayerHostView {
    let view = PlayerLayerHostView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    apply(to: view)
    return view
  }

  func updateUIView(_ view: PlayerLayerHostView, context: Context) {
    if view.playerLayer.player !== player {
      view.playerLayer.player = player
    }
    view.playerLayer.videoGravity = .resizeAspect
    apply(to: view)
  }

  private func apply(to view: PlayerLayerHostView) {
    let layer = view.playerLayer
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    layer.masksToBounds = cornerRadius > 0
  }
}

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

  /// True while playing a recorded broadcast rather than a live stream.
  var isVOD: Bool { vod != nil }

  /// VODs always expose the transport bar (seek is essential); live exposes it
  /// only when the user has Stream Rewind enabled.
  var rewindAvailable: Bool { isVOD || streamRewindEnabled }

  /// The focus target that "holds" chat while the viewer scrolls it. Live keeps
  /// focus on the composer (tvOS can't reliably focus a ScrollView); VODs have no
  /// composer, so a dedicated invisible scroller target stands in.
  var chatFocusAnchor: Focusable { isVOD ? .chatScroller : .chatInput }

  /// Keep the seek bar and the chat scroller mutually non-neighboring so a
  /// sideways swipe can never escape from one into the other.
  var scrubberFocusable: Bool {
    if isVOD { return focus != .chatScroller }
    return focus != .chatInput && focus != .chatSend
  }

  /// Selectable VOD playback rates, cycled by the speed control.
  var vodSpeedOptions: [Float] { [0.5, 1.0, 1.25, 1.5, 2.0] }

  /// Compact label for the current VOD rate, e.g. "1×", "1.5×", "0.5×".
  var vodSpeedLabel: String { String(format: "%g×", Double(vodPlaybackRate)) }


  /// The currently-active channel, which can change if the user follows a raid.
  @State var activeChannel: String = ""

  @Environment(\.dismiss) var dismiss
  @Environment(\.themePalette) var palette
  @AppStorage("preferredQuality") var preferredQuality = "Auto"
  @AppStorage("chatTextSizeValue") var chatTextSizeValue = Double(
    ChatAppearance.defaultTextSize)
  @AppStorage("chatEmoteAuto") var chatEmoteAuto = ChatAppearance.defaultEmoteAuto
  @AppStorage("chatEmoteSizeValue") var chatEmoteSizeValue = Double(
    ChatAppearance.defaultEmoteSize)
  @AppStorage("chatLineHeightValue") var chatLineHeightValue = Double(
    ChatAppearance.defaultLineHeight)
  @AppStorage("chatLetterSpacingValue") var chatLetterSpacingValue = Double(
    ChatAppearance.defaultLetterSpacing)
  @AppStorage("chatMessageSpacingValue") var chatMessageSpacingValue = Double(
    ChatAppearance.defaultMessageSpacing)
  @AppStorage("chatWidthValue") var chatWidthValue = Double(ChatAppearance.defaultWidth)
  @AppStorage("chatAnimatedEmotes") var chatAnimatedEmotes = ChatAppearance
    .defaultAnimatedEmotes
  @AppStorage("chatFontStyle") var chatFontStyleRaw = ChatAppearance.defaultFontStyle
    .rawValue
  @AppStorage("chatShowBadges") var chatShowBadges = ChatAppearance.defaultShowBadges
  @AppStorage("chatLayoutMode") var chatLayoutModeRaw = ChatLayoutMode.side.rawValue
  @AppStorage("chatSyncToStream") var chatSyncToStream = false
  @AppStorage("experimentalYouTubeMergeEnabled") var experimentalYouTubeMergeEnabled = false
  /// Optional manual override for the YouTube merge target. Kept per-channel and
  /// non-persistent so a value entered for one streamer never leaks into another
  /// (previously this was global `@AppStorage`, which made every channel merge
  /// with whatever handle was last entered).
  @State var experimentalYouTubeMergeChannelOrURL = ""
  /// Best-effort YouTube target derived from the active Twitch channel (its
  /// social links, then description, then a name-based guess).
  @State var youtubeAutoResolvedTarget = ""
  @AppStorage(LowLatencyHLSProxy.settingsKey) var lowLatencyProxyEnabled = true
  @AppStorage(LowLatencyHLSProxy.rewindSettingsKey) var streamRewindEnabled = true
  @AppStorage("showLatencyDiagnostics") var showLatencyDiagnostics = false

  @State var chat = ChatService()
  /// Drives chat replay when in VOD mode (reveals comments up to the playhead).
  @State var replay = VODChatReplayService()
  /// Periodic player time observer used in VOD mode to sync chat replay + the
  /// seek readout to the playhead.
  @State var vodTimeObserver: Any?
  /// Detects *outgoing* raids (the watched channel raiding away) via EventSub.
  @State var eventSub = EventSubService()

  /// Surfaces live polls / predictions / hype trains / goals for the watched
  /// channel via Twitch's private Hermes WebSocket (read-only).
  @State var hermes = HermesEventService()
  /// Debug-only cursor for the "Simulate Interactive Moment" cycle button.
  @State var debugMomentIndex = 0
  @State var player = AVPlayer()
  /// Drives the audio-only visualizer orb. Reacts to real audio when the player
  /// item exposes a tappable audio track (best effort on live HLS), otherwise
  /// runs an ambient animation.
  @State var audioLevelMonitor = AudioLevelMonitor()
  /// Retained for the player's lifetime: `AVURLAsset` only holds its resource
  /// loader delegate weakly, so the proxy must be owned here to stay alive.
  @State var lowLatencyProxy = LowLatencyHLSProxy(headers: PlaybackService.streamHeaders)
  @State var playback: StreamPlayback?
  @State var errorMessage: String?
  @State var isOffline = false
  @State var isLoading = true
  @State var showChat: Bool =
    UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool ?? true
  @State var chatReplayStartMessageID: ChatMessage.ID?
  /// Live resolution AVPlayer's adaptive (Auto) selection is currently showing,
  /// e.g. "1080p60". Drives the "Auto (1080p60)" label on the quality button.
  @State var resolvedQualityName: String?
  @State var showSignInSheet = false
  @State var showChatSettings = false
  @State var chatSettingsPage: ChatSettingsPage = .main
  /// Natural (content) height of the current settings page, used to size the
  /// floating panel to its content and animate when the page/content changes.
  @State var chatSettingsContentHeight: CGFloat = 0
  @State var showControls = false
  @State var streamTitle: String = ""
  @State var channelDisplayName: String = ""
  @State var channelAvatarURL: URL?
  @State var channelPageTarget: ChannelPageTarget?
  /// When the user picks a "More like this" channel from the channel page, we
  /// stash its login and switch to it once the page cover finishes dismissing.
  @State var pendingSwitchLogin: String?
  @State var chatDraft: String = ""
  @State var chatInputActivationToken: Int = 0
  @State var youtubeInputActivationToken: Int = 0
  @State var isSendingChat = false
  @State var chatSendError: String?
  /// When chat sync is active, a sent message is held until it appears in the
  /// delayed stream. This is the wall-clock moment it should surface.
  @State var chatSyncSendDeadline: Date?
  @State var chatSyncSendDelay: Double = 0
  @State var chatSyncSendClearTask: Task<Void, Never>?
  @State var hideTask: Task<Void, Never>?
  @State var focusRecoveryTask: Task<Void, Never>?
  @State var isQualityMenuPresented = false
  @State var latencyTask: Task<Void, Never>?
  @State var playbackWatchdogTask: Task<Void, Never>?
  // The live-latency and playback-watchdog tasks rewrite a large set of
  // bookkeeping values once per second. Storing them as `@State` re-executed the
  // entire (very large) PlayerView body every tick, which rebuilt the focused
  // quality button and made its focus highlight visibly flash ~once a second.
  // They live in a plain (non-Observable) reference box instead: mutating the
  // box's properties never invalidates the view, so the per-second monitoring
  // no longer churns the UI. The forwarding computed properties below keep the
  // original names so the monitoring code reads unchanged. UI that needs the
  // latency reading goes through `latencyReadout` (an `@Observable` the badge
  // leaf observes), so only the badge — not the whole player — updates.
  @State var mon = PlaybackMonitorBox()
  @State var latencyReadout = LatencyReadout()

  // MARK: Stream Rewind (DVR)
  /// Observed by the rewind transport bar only, so its once-per-second updates
  /// don't churn the whole player (same isolation pattern as `latencyReadout`).
  @State var rewindReadout = RewindReadout()
  /// True while the viewer has explicitly paused the live stream. Pausing keeps
  /// the playhead in place while the DVR window keeps growing, so resuming/seeking
  /// stays inside the retained window. Also gates the stall watchdog so an
  /// intentional pause is never mistaken for a freeze.
  @State var isUserPaused = false
  /// True while the viewer is actively scrubbing the rewind bar (analog trackpad
  /// glide). Gates the latency monitor's rate-force and the stall watchdog so
  /// repositioning the playhead is never mistaken for a freeze or fought.
  @State var isScrubbing = false
  /// Live scrub position (seconds on the player timeline) while a trackpad jog is
  /// in progress. The orb tracks this instantly for buttery feedback; the actual
  /// `AVPlayerItem.seek` is throttled/coalesced against it.
  @State var scrubTargetSeconds: Double?
  /// Throttle clock for the coalesced scrub seeks issued during a jog.
  @State var lastScrubSeekAt = Date.distantPast
  /// Debounced "settle" that commits a final frame-accurate seek and clears the
  /// intended position once rapid stepping/jogging stops.
  @State var scrubCommitTask: Task<Void, Never>?
  /// True while the playhead is following the live edge. The real seekable edge
  /// quantizes in segment-sized steps, so `behindLiveSeconds` wobbles a few
  /// seconds even when "at live"; this flag lets us pin the orb to the right edge
  /// and show LIVE deterministically until the viewer actually rewinds.
  @State var pinnedToLive = true
  /// Drives the analog (precision) trackpad scrubbing while the bar is focused.
  @State var scrubInput = ScrubInputCoordinator()
  /// Selected VOD playback rate. Applied whenever VOD playback (re)starts so it
  /// survives pause/resume and seek. Ignored for live (always 1.0).
  @State var vodPlaybackRate: Float = 1.0

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
  // The real (pre-proxy) source URL of the currently loaded item, so we can tell
  // whether a quality switch actually needs to replace the item. AVURLAsset.url
  // is the rewritten twizz-ll:// URL in low-latency mode, so it can't be used
  // for this comparison directly.
  @State var currentSourceURL: URL?
  var isPlaybackActive: Bool {
    get { mon.isPlaybackActive }
    nonmutating set { mon.isPlaybackActive = newValue }
  }
  var didRequestPlayback: Bool {
    get { mon.didRequestPlayback }
    nonmutating set { mon.didRequestPlayback = newValue }
  }
  var lastHardCatchUpJumpAt: Date {
    get { mon.lastHardCatchUpJumpAt }
    nonmutating set { mon.lastHardCatchUpJumpAt = newValue }
  }
  var lastWallClockCatchUpAt: Date {
    get { mon.lastWallClockCatchUpAt }
    nonmutating set { mon.lastWallClockCatchUpAt = newValue }
  }
  var edgeLatencyLowConfidenceStreak: Int {
    get { mon.edgeLatencyLowConfidenceStreak }
    nonmutating set { mon.edgeLatencyLowConfidenceStreak = newValue }
  }
  var wallClockHighLatencyStreak: Int {
    get { mon.wallClockHighLatencyStreak }
    nonmutating set { mon.wallClockHighLatencyStreak = newValue }
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
  var liveStallWaitingSince: Date? {
    get { mon.liveStallWaitingSince }
    nonmutating set { mon.liveStallWaitingSince = newValue }
  }
  var offlineProbeInFlight: Bool {
    get { mon.offlineProbeInFlight }
    nonmutating set { mon.offlineProbeInFlight = newValue }
  }
  var lastOfflineProbeAt: Date {
    get { mon.lastOfflineProbeAt }
    nonmutating set { mon.lastOfflineProbeAt = newValue }
  }
  @State var lastStallNotificationAt = Date.distantPast
  @State var suppressLowLatencyToggleReload = false
  @State var consecutiveLoadFailures = 0
  @State var lastControlFocus: Focusable = .quality
  /// Non-nil while chat is "soft paused" (Twitch-style): the list is frozen so
  /// the viewer can read, with a countdown that auto-resumes. A second Up press
  /// promotes it to manual scroll mode.
  @State var chatSoftPauseRemaining: Int?
  @State var softPauseTask: Task<Void, Never>?
  let softPauseSeconds = 10
  /// True once the viewer has promoted the pause into manual scroll mode. Focus
  /// stays on the composer; up/down swipes drive `chatScrollTarget` directly,
  /// because tvOS will not reliably hand (and keep) focus on the chat ScrollView.
  @State var isChatScrolling = false
  /// The message currently pinned near the top of the viewport while scrolling,
  /// tracked by id so incoming messages don't shift our place.
  @State var chatScrollAnchorID: ChatMessage.ID?
  /// Latest scroll instruction handed to ChatView. The nonce makes repeated
  /// scrolls to the same id still register as a change.
  @State var chatScrollTarget: ChatScrollTarget?
  @State var chatScrollNonce = 0
  /// Messages to advance per up/down swipe while scrolling.
  let chatScrollStep = 4
  /// Swipe-to-scroll (Siri Remote trackpad) state. The monitor reports the
  /// finger's position; a loop maps finger *travel* to scroll position so the
  /// chat follows a swipe and holds still when the finger does. Discrete presses
  /// still step (and press-and-hold repeats).
  @State var trackpad = RemoteTrackpadMonitor()
  @State var trackpadScrollTask: Task<Void, Never>?
  @State var trackpadScrollIndex: Double = 0
  @State var lastSentScrollIndex: Int = -1
  /// When the swipe loop last moved the scroll, used to suppress the discrete
  /// focus-move events a swipe also emits so a swipe and a press don't double up.
  @State var lastGestureScrollAt = Date.distantPast
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
  /// ourselves while the finger stays pressed/down on the pad.
  @State var chatHoldTask: Task<Void, Never>?
  /// Delay after click-down before the continuous hold-scroll engages, so a quick
  /// tap stays a single discrete step.
  let chatHoldInitialDelay: Double = 0.2
  /// Continuous hold-scroll speed (messages per 60Hz frame) at engage time.
  let chatHoldStartVelocity: Double = 0.18
  /// Top speed the hold accelerates to (messages per frame).
  let chatHoldMaxVelocity: Double = 1.4
  /// Per-frame multiplier that ramps the hold speed up (acceleration).
  let chatHoldVelocityAccel: Double = 1.035
  /// When the hold last scrolled, used to swallow the single discrete move event
  /// the click also emits on release.
  @State var lastHoldRepeatAt = Date.distantPast
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
  /// A just-activated settings control to briefly defend against tvOS's
  /// transient focus jump when toggling an option resizes the panel.
  @State var chatFocusPin: Focusable?
  @State var chatFocusPinTask: Task<Void, Never>?
  @State var raidBannerDismissTask: Task<Void, Never>?
  /// The outgoing raid currently being followed (with a cancel window).
  @State var outgoingRaid: OutgoingRaidEvent?
  @State var outgoingRaidSecondsRemaining = 0
  @State var outgoingRaidFollowTask: Task<Void, Never>?

  // MARK: Sleep timer (hidden inside the Quality menu)
  // A single countdown task pauses playback after a chosen duration so the
  // Apple TV can sleep when the viewer dozes off. It lives inside the Quality
  // menu (no dedicated button) and surfaces a small top-right countdown badge.
  @State var sleepTimerTask: Task<Void, Never>?
  /// Wall-clock instant playback should pause at, for the timed durations.
  @State var sleepDeadline: Date?
  /// "End of stream" mode: sleep when the channel goes offline, not on a clock.
  @State var sleepUntilStreamEnds = false
  /// Seconds left before sleep, republished each second for the countdown badge.
  @State var sleepRemainingSeconds: Int?
  /// Index of the chosen option, so the submenu shows a checkmark.
  @State var sleepSelectionIndex = 0
  /// Shown ~30s before a timed sleep so an awake viewer can keep watching.
  @State var showStillWatching = false
  /// True once the timer fires: playback is paused under a dim "Sleeping"
  /// overlay until the viewer presses to resume.
  @State var isSleeping = false

  // MARK: Diagnostics (experimental troubleshooting overlay)
  // Counters and a rolling event log so freezes/jumps can be observed on-device
  // and reported back, rather than inferred. Only meaningful while the overlay
  // toggle is on; reset on each fresh load.
  @State var diagStallCount = 0
  @State var diagJumpCount = 0
  @State var diagReloadCount = 0
  @State var diagEvents: [DiagnosticsEvent] = []
  @State var diagLastPlayheadSeconds: Double?
  @State var diagLastSampleAt: Date?
  @State var diagWasStalled = false
  @State var diagIsFrozen = false
  @State var diagFrozenSince: Date?
  @State var diagSessionStartedAt: Date?

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
  // Latency tuning stays at the proven-stable baseline even in low-latency mode.
  // The latency win comes from the proxy promoting Twitch prefetch segments — not
  // from starving buffers or chasing the edge, both of which caused freezes and
  // blur on-device. Freeze-free playback is the top priority, then sharpness.
  let targetLiveEdgeSeconds: Double = 3.5
  let softCatchUpThresholdSeconds: Double = 8
  // In low-latency mode the proxy adds prefetch segments to the seekable window,
  // which inflates the seekable-edge latency metric. A zero-tolerance hard seek
  // against that inflated edge rebuffers and freezes, so disable hard seeks while
  // low-latency mode is on and rely on gentle rate correction + a healthy buffer.
  var hardCatchUpThresholdSeconds: Double {
    lowLatencyProxyEnabled ? .greatestFiniteMagnitude : 14
  }
  let hardCatchUpCooldownSeconds: Double = 20
  let maxCatchUpRate: Float = 1.04
  let edgeLatencyUnavailableEpsilonSeconds: Double = 0.2
  let edgeLatencyUnavailableSamples = 4
  let wallClockSoftCatchUpThresholdSeconds: Double = 12
  let wallClockHardCatchUpThresholdSeconds: Double = 16
  let wallClockHardCatchUpRequiredSamples = 10
  let wallClockHardCatchUpCooldownSeconds: Double = 90
  let targetWallClockSeconds: Double = 6.5
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
  let playbackWatchdogIntervalSeconds: Double = 2
  let hardStallRecoverySeconds: Double = 10
  let recoveryCooldownSeconds: Double = 15
  let stallNotificationDebounceSeconds: Double = 2.5
  /// How long the player may sit unable to play (waiting on a starved buffer)
  /// before we authoritatively ask Twitch whether the channel is still live.
  /// Short enough to surface an ended broadcast promptly, long enough that a
  /// brief transient buffer dip won't trigger a needless GraphQL probe.
  let offlineProbeStallSeconds: Double = 6
  /// Minimum spacing between authoritative offline probes while still stuck.
  let offlineProbeCooldownSeconds: Double = 8
  // Diagnostics: how much unexplained playhead movement between 1s samples counts
  // as a "jump". Catch-up rate nudges (≤1.05x) only add a fraction of a second,
  // so a multi-second drift is a genuine AVPlayer skip, not normal catch-up.
  let diagJumpForwardThresholdSeconds: Double = 2.0
  let diagJumpBackwardThresholdSeconds: Double = 1.0
  let chatReplayMessageCount = 30
  let chatComposerRowHeight: CGFloat = 62

  @FocusState var focus: Focusable?
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
    case simulateRaidButton
    case simulateOfflineButton
    case simulateMomentButton
    case simulateGoLiveButton
    case chatSettingsButton
    // Stream Rewind transport bar
    case rewindScrubber
    // Main settings page
    case chatPresetOption(Int)
    case chatAdvancedButton
    case chatMoreButton
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
    case chatSyncToggle
    case chatLowLatencyToggle
    case chatRewindToggle
    case chatDiagnosticsToggle
    case youtubeMergeToggle
    case youtubeMergeURL
    // Advanced settings page
    case chatAdvancedBack
    case chatStepperDec(ChatStepperField)
    case chatStepperInc(ChatStepperField)
    case chatEmoteAutoToggle
    case chatAnimatedToggle
    case chatFontOption(Int)
    case chatBadgesToggle
    case chatResetButton
  }

  /// Which page of the chat settings panel is currently shown.
  enum ChatSettingsPage: Hashable {
    /// Top-level: presets, layout, and drill-in rows.
    case main
    /// Fine-grained version of the Size preset (text/emote/line/spacing).
    case appearance
    /// Playback, stream sync, diagnostics, and experimental toggles.
    case playback
  }

  /// The granular dimensions adjusted by the Advanced page steppers.
  enum ChatStepperField: Hashable {
    case text
    case emote
    case lineHeight
    case letterSpacing
    case messageSpacing
    case width
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

  var visibleChatMessages: [ChatMessage] {
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

      if let raid = chat.pendingRaid {
        raidBanner(raid)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(10)
      }

      if let raid = outgoingRaid {
        outgoingRaidBanner(raid)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(11)
      }

      if showStillWatching, !isSleeping {
        stillWatchingBanner()
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(12)
      }

      // Live polls / predictions / hype trains / goals are surfaced docked above
      // the chat list (see `chatPane`) so they share the chat's width and glass
      // treatment and only appear when chat is open — matching how Twitch shows
      // them beside the stream. Read-only.

      if let goLive, let event = goLive.pending {
        goLiveToast(goLive, event: event)
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(13)
      }

      if isSleeping {
        sleepingOverlay
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: hermes.currentMoment)
    .animation(.easeOut(duration: 0.25), value: goLive?.pending)
    .onChange(of: chat.pendingRaid) { _, newRaid in
      // Incoming raids (someone raiding the channel you're watching) are purely
      // informational: show a passive banner and auto-dismiss it. We never steal
      // focus or offer to "follow", because following would take you away from
      // the channel that is actually being raided.
      guard newRaid != nil else { return }
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
        resumeChatLive()
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
        // Directional movement should immediately surface controls. Pressing
        // right with chat open means the user wants the composer, so land
        // there directly instead of bouncing focus to the chat toggle first.
        // Up/down with chat open drive the soft-pause / scroll flow even while
        // the chrome is hidden (scrolling doesn't depend on focus).
        switch direction {
        case .right where showChat:
          revealControls(preferredFocus: chatFocusAnchor)
        case .up where showChat:
          handleChatUpPress()
        case .down where showChat && (isChatScrolling || chatSoftPauseRemaining != nil):
          handleChatDownPress()
        default:
          revealControls(preferredFocus: .chatToggle)
        }
      } else {
        scheduleHide()
      }
    }
    .onChange(of: focus) { oldFocus, newFocus in
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
    .onChange(of: activeChannel) { _, _ in
      // A manual override is scoped to the channel it was entered for; clear it
      // when the channel changes (e.g. following a raid) so it can't leak.
      experimentalYouTubeMergeChannelOrURL = ""
      youtubeAutoResolvedTarget = ""
      // The rewind window is per-stream: drop the previous channel's DVR history.
      lowLatencyProxy.resetDVR()
      isUserPaused = false
      // Keep the go-live watcher from toasting whatever we just switched to.
      goLive?.suppressedLogin = activeChannel
    }
    .task(id: activeChannel) {
      await refreshYouTubeAutoTarget()
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

  var videoColumn: some View {
    ZStack(alignment: .bottom) {
      VideoSurface(player: player)
        .ignoresSafeArea()

      if isAudioOnlyActive, !isLoading, errorMessage == nil, !isOffline {
        AudioVisualizerContainer(
          monitor: audioLevelMonitor,
          avatarURL: channelAvatarURL,
          palette: palette
        )
        .transition(.opacity)
        .onAppear {
          audioLevelMonitor.start(
            audioPlaylistURL: audioOnlyPlaylistURL,
            headers: PlaybackService.streamHeaders,
            currentDate: { [weak player] in player?.currentItem?.currentDate() }
          )
        }
        .onDisappear { audioLevelMonitor.stop() }
      }

      if showControls, !isLoading,
        errorMessage == nil, !isOffline
      {
        VStack {
          HStack {
            if !isVOD {
              LatencyBadge(readout: latencyReadout)
            }
            Spacer()
            if let remaining = sleepRemainingSeconds {
              SleepCountdownBadge(text: SleepCountdownBadge.format(seconds: remaining))
            } else if sleepUntilStreamEnds {
              SleepCountdownBadge(text: "End of stream")
            }
          }
          if showLatencyDiagnostics {
            HStack {
              DiagnosticsPanel(lines: diagnosticsLines, events: diagEvents)
              Spacer()
            }
            .padding(.top, 12)
          }
          Spacer()
        }
        .padding(.top, 36)
        .padding(.leading, 40)
        .padding(.trailing, 40)
      }

      // Only expose the video focus target while controls are hidden.
      // Otherwise, left-edge movement from the control cluster can escape
      // into this invisible target and appear as lost focus.
      if !showControls, !isOffline {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .focusable()
          .focused($focus, equals: .video)
          .onTapGesture { revealControls(preferredFocus: .quality) }
      }

      if isLoading {
        ProgressView(isVOD ? "Loading broadcast…" : "Loading \(activeChannel)…")
          .font(.title3)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }

      if isOffline {
        offlineState
      } else if let errorMessage {
        VStack(spacing: 24) {
          Text("Couldn't play \(activeChannel)")
            .font(.title2).bold()
          Text(errorMessage)
            .foregroundStyle(.secondary)
          Button("Back") { dismiss() }
            .focused($focus, equals: .errorBack)
        }
        .padding(40)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
      } else if showControls {
        bottomOverlay
      }
    }
    .onPlayPauseCommand {
      guard rewindAvailable, errorMessage == nil, !isOffline, !isLoading else { return }
      toggleRewindPlayPause()
    }
  }

  // MARK: - Offline empty state

  var offlineDisplayName: String {
    channelDisplayName.isEmpty ? activeChannel : channelDisplayName
  }

  /// Horizontal shift applied to the offline empty-state content so it stays
  /// visually centered in the *uncovered* area. In overlay/glass chat modes the
  /// video (and this empty state) spans the full screen while the chat pane
  /// floats over the right edge, so without this the content reads as
  /// off-center. Shift left by half the width the chat occupies. The chat width
  /// is user-customizable, so this tracks `chatWidth`.
  var offlineContentHorizontalOffset: CGFloat {
    guard showChat, chatLayoutMode.isOverlay else { return 0 }
    switch chatLayoutMode {
    case .glass:
      return -(chatWidth + GlassChatPaneStyle.edgeInset) / 2
    case .overlay:
      return -chatWidth / 2
    case .side:
      return 0
    }
  }

  var offlineState: some View {
    ZStack {
      // Opaque backdrop so the frozen last frame never bleeds through.
      palette.playerBackdrop.ignoresSafeArea()

      VStack(spacing: 28) {
        offlineAvatar

        VStack(spacing: 10) {
          Text("OFFLINE")
            .font(.caption.weight(.bold))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.white.opacity(0.10), in: Capsule())

          Text(offlineDisplayName)
            .font(.system(size: 46, weight: .bold))
            .foregroundStyle(.white)

          Text("The stream has ended.")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))

          Text("Catch up on recent videos and clips, or check back soon.")
            .font(.body)
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
        }

        HStack(spacing: 20) {
          Button {
            presentChannelPage()
          } label: {
            Label("View Channel", systemImage: "play.rectangle.on.rectangle")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .buttonStyle(.borderedProminent)
          .tint(ThemePalette.brandPurple)
          .focused($focus, equals: .offlineViewChannel)
          .onMoveCommand { direction in
            if direction == .right { focus = .offlineTryAgain }
          }

          Button {
            retryFromOffline()
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .TwizzControlButtonStyle()
          .focused($focus, equals: .offlineTryAgain)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              focus = .offlineViewChannel
            case .right:
              // Deliberate exit out of the focus section into chat, mirroring
              // the control row's chat-toggle button.
              if showChat { focus = chatFocusAnchor }
            default:
              break
            }
          }
        }
        .padding(.top, 8)
        // Group the two buttons as one focus section so the full-height chat
        // pane (a strong geometric focus magnet) can't out-pull the adjacent
        // Try Again button. Within the section the explicit move handlers above
        // step View Channel -> Try Again, and only a right-press from Try Again
        // exits into chat. Mirrors the bottom control row's focus corralling.
        .focusSection()
      }
      .frame(maxWidth: 760)
      .padding(48)
      .offset(x: offlineContentHorizontalOffset)
      .animation(.easeOut(duration: 0.18), value: offlineContentHorizontalOffset)
    }
    .transition(.opacity)
  }

  @ViewBuilder
  var offlineAvatar: some View {
    Group {
      if let channelAvatarURL {
        CachedAsyncImage(url: channelAvatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          offlineAvatarPlaceholder
        }
      } else {
        offlineAvatarPlaceholder
      }
    }
    .frame(width: 132, height: 132)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .grayscale(0.6)
    .opacity(0.9)
  }

  var offlineAvatarPlaceholder: some View {
    ZStack {
      Circle().fill(.white.opacity(0.10))
      Icon(glyph: .userCircle, size: 64)
        .foregroundStyle(.white.opacity(0.7))
    }
  }

  /// Twitch-style live viewer count shown under the stream title: a red people
  /// glyph plus the current count. Live-only; the number animates as updates
  /// arrive (~every 20-30s) via `.numericText()` content transitions.
  @ViewBuilder
  func liveViewerBadge(_ count: Int) -> some View {
    HStack(spacing: 6) {
      Icon(glyph: .users, size: 18)
        .foregroundStyle(.red)
      Text(count.formatted(.number))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
    .transition(.opacity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(count.formatted(.number)) watching")
  }

  var bottomOverlay: some View {
    VStack(spacing: 18) {
      HStack(alignment: .center, spacing: 24) {
      HStack(alignment: .center, spacing: 12) {
        Button {
          presentChannelPage()
        } label: {
          Group {
            if let channelAvatarURL {
              CachedAsyncImage(url: channelAvatarURL) { image in
                image
                  .resizable()
                  .scaledToFill()
              } placeholder: {
                ZStack {
                  Circle().fill(.white.opacity(0.16))
                  Icon(glyph: .userCircle, size: 64)
                    .foregroundStyle(.white.opacity(0.85))
                }
              }
            } else {
              ZStack {
                Circle().fill(.white.opacity(0.16))
                Icon(glyph: .userCircle, size: 64)
                  .foregroundStyle(.white.opacity(0.85))
              }
            }
          }
          .frame(width: 64, height: 64)
          .clipShape(Circle())
          // Let the avatar fill more of the button: the larger frame is pulled
          // back with negative padding so the glass button keeps its original
          // footprint, just with less empty space around the image.
          .padding(-6)
        }
        .TwizzControlButtonStyle()
        .buttonBorderShape(.circle)
        .focused($focus, equals: .streamInfo)
        .onMoveCommand { direction in
          switch direction {
          case .right:
            focus = .quality
          case .left:
            focus = .streamInfo
          case .down:
            if rewindAvailable { focus = .rewindScrubber }
          default:
            break
          }
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(streamTitle.isEmpty ? channelDisplayName : streamTitle)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)

          // Live-only viewer count (VODs have no live audience). Seeded from
          // channel metadata on open, then driven live by Hermes pubsub.
          if !isVOD, let viewers = hermes.viewerCount {
            liveViewerBadge(viewers)
          }
        }
        // Cap the block to the buttons' height so a tall title centers against
        // the buttons instead of growing the bottom-pinned row and pushing the
        // buttons upward off their fixed position.
        .frame(maxWidth: .infinity, maxHeight: controlButtonsHeight > 0 ? controlButtonsHeight : nil, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: hermes.viewerCount)
      }

      Spacer(minLength: 18)

      HStack(spacing: 14) {
        // The visible menu content is kept `.equatable()` so the player's
        // once-per-second latency churn doesn't re-render (and blink) the open
        // menu. The focus + navigation modifiers are applied OUTSIDE that
        // equatable boundary on purpose: `.equatable()` freezes the wrapped
        // subtree when its inputs are unchanged, and if `.focused` lived inside
        // it the focus binding would freeze too — so when the menu closed the
        // focus system had no live binding to restore to and focus only snapped
        // back on the next unrelated re-render (~1-2s later). Keeping `.focused`
        // here keeps the binding live so focus returns to the button instantly.
        // Quality / adaptive bitrate is live-only; VODs play a fixed recording.
        if !isVOD {
        QualityMenu(
          options: qualityOptions,
          selectedOption: preferredQuality,
          buttonLabel: qualityButtonLabel,
          reservedWidthLabels: qualityButtonLabelCandidates,
          displayLabel: { qualityDisplayLabel($0) },
          onSelect: { selectQuality(at: $0) },
          onMenuPresented: {
            focusRecoveryTask?.cancel()
            isQualityMenuPresented = true
            // Keep `focus == .quality` while the menu is open so tvOS keeps the
            // button visually "lifted" (its focus shadow) behind the popup for
            // the menu's whole lifetime, and so focus returns to it instantly
            // on dismiss.
          },
          onMenuDismissed: {
            isQualityMenuPresented = false
            focusRecoveryTask?.cancel()
            // If selecting a (short) sleep timer already surfaced the
            // still-watching banner or the sleeping overlay, don't yank focus
            // back to the quality button — let those own it.
            guard !showStillWatching, !isSleeping else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              focus = .quality
            }
            focusRecoveryTask = Task {
              // Let close animation settle, then restore anchor focus if needed.
              try? await Task.sleep(for: .milliseconds(40))
              guard !Task.isCancelled else { return }
              await MainActor.run {
                guard showControls, !showChatSettings, !isQualityMenuPresented else { return }
                guard !showStillWatching, !isSleeping else { return }
                guard focus == nil || focus == .quality else { return }
                focus = .quality
              }
            }
          },
          sleepOptions: sleepTimerOptionLabels,
          sleepSelectedIndex: sleepSelectionIndex,
          sleepIsArmed: sleepTimerIsArmed,
          onSelectSleep: { selectSleepTimer(at: $0) }
        )
        .equatable()
        .focused($focus, equals: .quality)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .streamInfo
          case .right:
            focus = .chatSettingsButton
          case .down:
            if rewindAvailable { focus = .rewindScrubber }
          default:
            break
          }
        }
        }

        // VODs have no adaptive quality; the same control slot becomes a playback
        // speed cycler. Shares the `.quality` focus tag so existing left/right
        // navigation around it is unchanged.
        if isVOD {
          Button {
            cycleVODSpeed()
          } label: {
            Text(vodSpeedLabel)
              .font(.headline.weight(.semibold))
              .monospacedDigit()
              .frame(minWidth: 52)
              .accessibilityLabel("Playback Speed")
          }
          .focused($focus, equals: .quality)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              focus = .streamInfo
            case .right:
              focus = .chatSettingsButton
            case .down:
              if rewindAvailable { focus = .rewindScrubber }
            default:
              break
            }
          }
        }

        Button {
          openChatSettingsFromControlBar()
        } label: {
          Icon(glyph: showChatSettings ? .x : .adjustmentsHorizontal)
            .accessibilityLabel("Chat Settings")
        }
        .focused($focus, equals: .chatSettingsButton)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .quality
          case .right:
            focus = .chatToggle
          case .down:
            if rewindAvailable { focus = .rewindScrubber }
          default:
            break
          }
        }

        Button {
          toggleChatVisibility()
          if !showChat, focus == .chatInput {
            focus = .chatToggle
          }
          scheduleHide()
        } label: {
          Icon(glyph: showChat ? .sidebarRightCollapse : .sidebarRightExpand)
            .accessibilityLabel(showChat ? "Hide Chat" : "Show Chat")
        }
        .focused($focus, equals: .chatToggle)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            focus = .chatSettingsButton
          case .right:
            if showChat {
              focus = chatFocusAnchor
            }
          case .down:
            if rewindAvailable { focus = .rewindScrubber }
          default:
            break
          }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .TwizzControlButtonStyle()
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: ControlButtonsHeightKey.self,
            value: proxy.size.height
          )
        }
      )
      .focusSection()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onPreferenceChange(ControlButtonsHeightKey.self) { height in
      controlButtonsHeight = height
    }
    // Treat the whole control row (avatar, quality, settings, chat toggle) as one
    // focus section so tvOS keeps focus within it during fast trackpad swipes.
    // Without this, when chat is open the adjacent chat pane (composer, message
    // list) offers competing focus targets and a quick swipe can fling focus out of
    // the row or drop it entirely — which never happens with chat closed.
    .focusSection()

      if rewindAvailable {
        Button {
          toggleRewindPlayPause()
        } label: {
          RewindScrubBar(readout: rewindReadout, isFocused: focus == .rewindScrubber)
        }
        .buttonStyle(ScrubBarButtonStyle())
        // Mutually exclusive focusability with the chat composer: while a chat
        // field is focused the bar removes itself from the focus engine, so a
        // left-press out of chat can't land here (it goes to the collapse
        // button instead). Combined with the composer doing the reverse, the
        // engine never treats the two as neighbors — no sideways escape, no
        // focus flash, no after-the-fact reverts.
        .focusable(scrubberFocusable)
        .focused($focus, equals: .rewindScrubber)
        .onMoveCommand { direction in
          // Left/right step the timeline. Up is intentionally left to the focus
          // engine: forcing an explicit target here fought the engine's own
          // upward move and produced a visible double-hop (it would land on the
          // nearest control, then yank sideways to ours). Sideways escape to
          // chat is prevented structurally (see .focusable above).
          switch direction {
          case .left:
            if !isScrubbing { rewindStep(-rewindStepSeconds) }
          case .right:
            if !isScrubbing { rewindStep(rewindStepSeconds) }
          default:
            break
          }
        }
        .focusSection()
        .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 48)
    .padding(.trailing, controlsTrailingInset)
    .padding(.top, 12)
    .padding(.bottom, controlsBottomPadding)
    .background(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.0),
          .init(color: .black.opacity(0.72), location: 0.56),
          .init(color: .black.opacity(1.0), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity)
      .frame(height: 280)
      .allowsHitTesting(false),
      alignment: .bottom
    )
  }

  // MARK: - Diagnostics overlay

  /// The fixed metric rows, each computed live from the current item.
  var diagnosticsLines: [String] {
    var lines: [String] = []

    let mode = lowLatencyProxyEnabled ? "LL proxy ON" : "LL proxy off"
    let pin = preferredQuality == "Auto" ? "Auto/adaptive" : "\(preferredQuality) (pinned)"
    lines.append("Mode: \(mode) · \(pin)")

    if let item = player.currentItem {
      let size = item.presentationSize
      if size.width > 0, size.height > 0 {
        lines.append(
          "Render: \(Int(size.width))×\(Int(size.height)) · Rate: \(diagFormat(Double(player.rate), decimals: 2))x"
        )
      } else {
        lines.append("Render: — · Rate: \(diagFormat(Double(player.rate), decimals: 2))x")
      }

      if let event = item.accessLog()?.events.last {
        lines.append(
          "Bitrate: \(diagBitrate(event.indicatedBitrate)) shown · \(diagBitrate(event.observedBitrate)) obs"
        )
        lines.append(
          "Dropped frames: \(event.numberOfDroppedVideoFrames) · AVStalls: \(event.numberOfStalls)"
        )
      } else {
        lines.append("Bitrate: — (no access log yet)")
      }

      lines.append("Buffer ahead: \(diagBufferAheadDescription(item))")
    } else {
      lines.append("No active item")
    }

    let edge = liveEdgeLatencySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "—"
    let wall = wallClockLatencySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "—"
    let chatHold =
      chatSyncToStream
      ? (chatSyncDelaySeconds.map { "\(diagFormat($0, decimals: 1))s" } ?? "measuring")
      : "off"
    if diagIsFrozen {
      let frozenFor =
        diagFrozenSince.map { max(0, Int(Date().timeIntervalSince($0).rounded())) } ?? 0
      lines.append("State: FROZEN (\(frozenFor)s) · Waiting: \(diagWaitingReasonDescription())")
    } else {
      lines.append("State: Playing/waiting · Waiting: \(diagWaitingReasonDescription())")
    }
    lines.append("Edge gap: \(edge) · Encoder: \(wall)")
    lines.append("Chat hold: \(chatHold)")
    lines.append(
      "Stalls: \(diagStallCount) · Jumps: \(diagJumpCount) · Reloads: \(diagReloadCount)")

    return lines
  }

  // MARK: - Controls visibility

  /// Left-press target when leaving the chat composer. While the channel is
  /// offline the bottom controls (and `.chatToggle`) aren't rendered — the
  /// offline empty state is shown instead — so revealing controls would focus a
  /// target that doesn't exist and trap focus on the composer. Return to the
  /// offline state's "Try Again" button, which is the control adjacent to the
  /// chat pane, so a subsequent right-press hops straight back into chat.
  func exitChatComposerLeft() {
    if isOffline {
      focus = .offlineTryAgain
    } else {
      revealControls(preferredFocus: .chatToggle)
    }
  }

  func revealControls(preferredFocus: Focusable) {
    focusRecoveryTask?.cancel()
    if !showControls {
      showControls = true
    }
    if isControlFocus(preferredFocus) {
      lastControlFocus = preferredFocus
    }
    focus = preferredFocus
    scheduleHide()
  }

  func hideControls() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    showControls = false
    focus = .video
  }

  func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(controlsAutoHideSeconds))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        // Don't auto-hide while the quality menu is engaged. When the native
        // Menu is open, tvOS owns focus and our FocusState reads nil, while
        // `lastControlFocus` still points at `.quality`. In that case re-arm
        // instead of hiding so the control bar — and the menu anchored to it —
        // stay on screen. Normal auto-hide resumes once focus lands on another
        // control.
        if focus == .quality || (focus == nil && lastControlFocus == .quality) {
          scheduleHide()
          return
        }
        if isQualityMenuPresented {
          scheduleHide()
          return
        }
        // Keep the controls (and the chat composer beneath them) on screen while
        // chat is frozen for reading or scrolling, so focus stays on the composer
        // and up/down swipes keep driving the scroll instead of hiding the chrome.
        if isChatScrolling || chatSoftPauseRemaining != nil {
          scheduleHide()
          return
        }
        // The settings button now lives in the control bar, so keep the bar up
        // while its panel is open — closing the panel returns focus to it.
        if showChatSettings {
          scheduleHide()
          return
        }
        hideControls()
      }
    }
  }

  // MARK: - Channel page

  /// Opens the full-screen channel page for the active channel. The live stream
  /// is paused while the page is up, and its latency monitor + watchdog are
  /// suspended so the non-advancing playhead isn't mistaken for a stall.
  func presentChannelPage() {
    hideTask?.cancel()
    focusRecoveryTask?.cancel()
    if !isVOD {
      stopPlaybackWatchdog()
      stopLatencyMonitor()
    }
    player.pause()
    channelPageTarget = ChannelPageTarget(
      login: activeChannel,
      displayName: channelDisplayName.isEmpty ? activeChannel : channelDisplayName,
      profileImageURL: channelAvatarURL
    )
  }

  /// Resumes live playback once the channel page is dismissed — or switches to a
  /// different channel if the user picked one from the page's "More like this".
  func resumeAfterChannelPage() {
    if let login = pendingSwitchLogin {
      pendingSwitchLogin = nil
      followRaid(login)
      return
    }
    // Don't resurrect a dead stream — if we entered the channel page from the
    // offline empty state, return straight back to it.
    if isOffline {
      focus = .offlineViewChannel
      return
    }
    if isVOD {
      player.play()
    } else {
      startPlayback()
      startLatencyMonitor()
      startPlaybackWatchdog()
    }
    if showControls {
      focus = .streamInfo
      scheduleHide()
    } else {
      focus = .video
    }
  }


  func isControlFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .streamInfo, .quality, .chatToggle, .chatInput, .rewindScrubber:
      return true
    default:
      return false
    }
  }

  func isChatSettingsFocus(_ focus: Focusable) -> Bool {
    switch focus {
    case .chatSettingsButton,
      .chatPresetOption,
      .chatAdvancedButton,
      .chatMoreButton,
      .chatWidthOption,
      .chatLayoutOption,
      .chatSyncToggle,
      .chatLowLatencyToggle,
      .chatRewindToggle,
      .chatDiagnosticsToggle,
      .simulateRaidButton,
      .simulateOfflineButton,
      .simulateMomentButton,
      .simulateGoLiveButton,
      .youtubeMergeToggle,
      .youtubeMergeURL,
      .chatAdvancedBack,
      .chatStepperDec,
      .chatStepperInc,
      .chatEmoteAutoToggle,
      .chatAnimatedToggle,
      .chatFontOption,
      .chatBadgesToggle,
      .chatResetButton:
      return true
    default:
      return false
    }
  }

  /// Surface style for the docked interactive-moment card, mirroring the chat
  /// list it sits above so it only reads *light* when the chat itself is light
  /// (Side layout under the light theme). Glass/Overlay chat stay dark.
  func momentDockStyle(isGlass: Bool) -> MomentDockStyle {
    switch chatLayoutMode {
    case .glass:
      return MomentDockStyle(surface: .glass)
    case .overlay:
      return MomentDockStyle(surface: .darkOverlay)
    case .side:
      return MomentDockStyle(
        surface: .side(
          surface: palette.chatSideSurface,
          primaryText: palette.chatSidePrimaryText))
    }
  }

  var chatPane: some View {
    let isGlass = chatLayoutMode == .glass
    let useLighterOverlayBackground = chatLayoutMode == .overlay
    return VStack(spacing: 0) {
      // ChatView is wrapped so the live `chat.messages` read happens inside the
      // wrapper's body, not PlayerView's. Otherwise every incoming chat message
      // (several per second on busy channels) re-executes the whole PlayerView
      // body and flashes the focused Quality menu while it's open.
      ChatMessagesColumn(
        chat: isVOD ? nil : chat,
        replay: isVOD ? replay : nil,
        channel: channel,
        replayStartMessageID: chatReplayStartMessageID,
        textSize: chatTextSize,
        emoteSize: chatEmoteSize,
        messageSpacing: chatMessageSpacing,
        lineHeight: chatLineHeight,
        letterSpacing: chatLetterSpacing,
        animatedEmotes: chatAnimatedEmotes,
        fontStyle: chatFontStyle,
        showBadges: chatShowBadges,
        useGlassBackground: isGlass,
        useLighterOverlayBackground: useLighterOverlayBackground,
        autoScroll: !(isChatScrolling || chatSoftPauseRemaining != nil),
        softPauseRemaining: chatSoftPauseRemaining,
        softPauseTotal: softPauseSeconds,
        scrollTarget: chatScrollTarget
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        // VOD chat is read-only: there's no composer to send from. Instead an
        // invisible focusable sits over the message list. Pressing right off the
        // collapse-chat button lands here (surfacing the paused indicator); from
        // here up/down scroll the replay and left returns to the controls.
        if isVOD {
          Color.clear
            .contentShape(Rectangle())
            .focusable(showChat && focus != .rewindScrubber)
            .focused($focus, equals: .chatScroller)
            .onMoveCommand { direction in
              switch direction {
              case .up: handleChatUpPress()
              case .down: handleChatDownPress()
              case .left:
                resumeChatLive()
                revealControls(preferredFocus: .chatToggle)
              default: break
              }
            }
        }
      }
      // Live interactive moments (polls / predictions / hype trains / goals)
      // float over the TOP of the chat list rather than pushing it down, so the
      // messages scroll behind the card (matching Twitch on the web). Only
      // visible while chat is open (this whole pane is). Passive +
      // non-interactive: never takes focus, so chat keeps scrolling underneath.
      .overlay(alignment: .top) {
        if let moment = hermes.currentMoment, !isSleeping {
          dockedInteractiveMoment(moment, style: momentDockStyle(isGlass: isGlass))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }

      if !isVOD {
        chatComposerBar
      }
    }
    .frame(width: chatWidth)
    .modifier(GlassChatPaneStyle(enabled: isGlass))
    // Prevent the glass container from showing a focus glow when interactive
    // elements inside (e.g. the chat input) receive focus.
    .focusEffectDisabled()
    // The settings panel floats to the LEFT of the chat so the whole chat stays
    // visible while you adjust it, anchored toward the BOTTOM so it sits near the
    // settings button (now in the bottom control row) instead of way up top. It
    // is attached *outside* GlassChatPaneStyle so the glass pane's rounded clip
    // never hides it in glass layout mode.
    .overlay(alignment: .bottomLeading) {
      if showChatSettings {
        let topInset: CGFloat = isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16
        GeometryReader { geo in
          chatSettingsPanel(
            maxHeight: max(geo.size.height - topInset - chatSettingsBottomClearance, 0)
          )
          .frame(width: chatSettingsPanelWidth)
          .padding(.top, topInset)
          .padding(.bottom, chatSettingsBottomClearance)
          .offset(x: -(chatSettingsPanelWidth + chatSettingsPanelGap))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: chatSettingsPanelWidth)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.18), value: showChatSettings)
  }

  let chatSettingsPanelWidth: CGFloat = 560
  let chatSettingsPanelGap: CGFloat = 16
  /// Distance the bottom control row sits above the screen's bottom edge. Kept
  /// generous so the row (and the chat composer it aligns with) clears typical TV
  /// overscan instead of hugging the very bottom.
  let controlsBottomPadding: CGFloat = 8
  /// Measured height of the right-side control buttons row. The stream title is
  /// capped to this so a long (2-line) title can't grow the row and shove the
  /// buttons up off their fixed position — instead the title stays vertically
  /// centered against the buttons.
  @State var controlButtonsHeight: CGFloat = 0
  /// How far above the screen bottom the floating settings panel must start so it
  /// floats *above* the control row rather than behind/under it. Control row
  /// bottom inset plus its approximate height plus a small gap. When the rewind
  /// scrub bar is present it sits *below* the control row in the same VStack, so
  /// the panel has to clear that extra element too (bar height + the VStack's
  /// 18pt spacing) or it overlaps the seek bar and the buttons beneath it.
  var chatSettingsBottomClearance: CGFloat {
    let base = controlsBottomPadding + 104
    return rewindAvailable ? base + scrubBarClusterHeight : base
  }
  /// Approximate on-screen height the rewind scrub bar adds beneath the control
  /// row: the bar's own height (~68pt) plus the control VStack's 18pt spacing.
  let scrubBarClusterHeight: CGFloat = 86


  var hasChatDraft: Bool {
    !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var chatComposerBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let chatSendError {
        Text(chatSendError)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }

      if let deadline = chatSyncSendDeadline, chatSyncSendDelay > 0 {
        ChatSyncSendIndicator(deadline: deadline, total: chatSyncSendDelay)
      }

      if auth.isAuthenticated {
        HStack(spacing: 16) {
          Button {
            chatInputActivationToken &+= 1
          } label: {
            Text(chatDraft.isEmpty ? "Send a message" : chatDraft)
              .font(.subheadline)
              .foregroundStyle(
                focus == .chatInput && !chatIsFrozen
                  ? .black.opacity(chatDraft.isEmpty ? 0.55 : 1.0)
                  : .white.opacity(chatDraft.isEmpty ? 0.5 : 1.0)
              )
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 28)
              .frame(maxWidth: .infinity)
              .frame(height: chatComposerRowHeight)
              .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput && !chatIsFrozen))
              // The keyboard host sits *behind* the glass capsule as a full-size,
              // visually clear field. Keeping it out of the styled content (and at
              // full size) avoids a second nested background blob and stops tvOS
              // from resigning first responder on an undersized field.
              .background(
                ChatKeyboardHostField(
                  text: $chatDraft,
                  activationToken: chatInputActivationToken,
                  onSubmit: submitChatMessage
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
              )
          }
          .buttonStyle(ChatInputButtonStyle())
          .focusEffectDisabled()
          // Mirror of the scrubber's gate: while the rewind bar is focused the
          // composer leaves the focus engine so a right-swipe/press on the bar
          // can't fling focus over here. We use `.disabled` rather than
          // `.focusable(_:)` because applying `.focusable` to a Button on tvOS
          // hijacks the Select press and stops the button's own action from
          // firing (which broke opening the keyboard). A disabled button is
          // likewise dropped from the focus engine, but only ever while the bar
          // is focused — never while the composer itself is focused — so focus
          // is never dropped.
          .disabled(focus == .rewindScrubber)
          .focused($focus, equals: .chatInput)
          .animation(.easeOut(duration: 0.18), value: focus == .chatInput && !chatIsFrozen)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              exitChatComposerLeft()
            case .up:
              handleChatUpPress()
            case .down:
              handleChatDownPress()
            case .right:
              if hasChatDraft { focus = .chatSend }
            default:
              break
            }
          }

          if hasChatDraft {
            Button {
              submitChatMessage()
            } label: {
              if isSendingChat {
                ProgressView()
                  .frame(width: 24, height: 24)
              } else {
                Icon(glyph: .send, size: 24)
                  .frame(width: 24, height: 24)
              }
            }
            .TwizzControlButtonStyle()
            .frame(width: chatComposerRowHeight, height: chatComposerRowHeight)
            // `.disabled` also doubles as the rewind-bar focus gate; see the
            // composer button above for why we avoid `.focusable` on a Button.
            .disabled(isSendingChat || focus == .rewindScrubber)
            .focused($focus, equals: .chatSend)
            .transition(.opacity)
            .onMoveCommand { direction in
              switch direction {
              case .left:
                focus = .chatInput
              case .up:
                focus = .chatSettingsButton
              default:
                break
              }
            }
          }
        }
        .frame(height: chatComposerRowHeight)
        .animation(.easeOut(duration: 0.18), value: hasChatDraft)
      } else {
        Button {
          showSignInSheet = true
          scheduleHide()
        } label: {
          Text("Sign in to send messages")
            .font(.subheadline)
            .foregroundStyle(
              focus == .chatInput && !chatIsFrozen
                ? .black.opacity(0.7)
                : .white.opacity(0.45)
            )
            .lineLimit(1)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: chatComposerRowHeight)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput && !chatIsFrozen))
            .animation(.easeOut(duration: 0.18), value: focus == .chatInput && !chatIsFrozen)
        }
        .buttonStyle(ChatInputButtonStyle())
        .focusEffectDisabled()
        // Rewind-bar focus gate, expressed via `.disabled` rather than
        // `.focusable` so the Button's Select action still fires on tvOS (see
        // the signed-in composer button for the full rationale).
        .disabled(focus == .rewindScrubber)
        .focused($focus, equals: .chatInput)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            exitChatComposerLeft()
          case .up:
            handleChatUpPress()
          case .down:
            handleChatDownPress()
          default:
            break
          }
        }
        .frame(height: chatComposerRowHeight)
        .accessibilityLabel("Sign in to send messages")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    // Match the composer's bottom gap to the 16pt left/right inset so it sits
    // evenly inside the glass pane's rounded corners.
    .padding(.bottom, 16)
    .background(
      chatLayoutMode == .glass
        ? AnyShapeStyle(Color.black.opacity(0.22))
        : (chatLayoutMode == .overlay
          ? AnyShapeStyle(Color(white: 0.13).opacity(0.90))
          : AnyShapeStyle(Color(white: 0.07).opacity(0.96)))
    )
  }

  func submitChatMessage() {
    let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isSendingChat else { return }
    // Dismiss the tvOS keyboard overlay before sending.
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    isSendingChat = true
    chatSendError = nil
    Task {
      do {
        try await auth.sendChatMessage(text, toChannel: activeChannel)
        chatDraft = ""
        beginChatSyncSendIndicatorIfNeeded()
      } catch {
        chatSendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      isSendingChat = false
    }
  }

  /// When stream-sync is holding chat, a sent message won't appear until it
  /// reaches the delayed video. Show a short progress countdown so the user
  /// knows it was sent and roughly when it will surface.
  func beginChatSyncSendIndicatorIfNeeded() {
    guard chatSyncToStream, let delay = chatSyncDelaySeconds, delay >= 0.75 else {
      return
    }
    chatSyncSendClearTask?.cancel()
    chatSyncSendDelay = delay
    chatSyncSendDeadline = Date().addingTimeInterval(delay)
    chatSyncSendClearTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        chatSyncSendDeadline = nil
      }
    }
  }

  /// The effective YouTube merge target shown in the settings input: the manual
  /// entry when present, otherwise the resolved default handle for the channel.
  var youtubeMergeDisplayText: String {
    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    return youtubeMergeDefaultTarget.isEmpty
      ? "YouTube handle or channel URL" : youtubeMergeDefaultTarget
  }

  /// The handle the merge falls back to when no manual value is entered. Prefers
  /// the YouTube channel discovered from the Twitch channel's social links /
  /// description, and only guesses `@<twitch-login>` when nothing better exists.
  var youtubeMergeDefaultTarget: String {
    let auto = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if !auto.isEmpty { return auto }
    let base = activeChannel.isEmpty ? channel : activeChannel
    return base.isEmpty ? "" : "@\(base)"
  }

  func applyExperimentalYouTubeSettings() {
    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let resolvedTarget = manual.isEmpty ? youtubeMergeDefaultTarget : manual

    chat.configureExperimentalYouTubeMerge(
      enabled: experimentalYouTubeMergeEnabled,
      channelOrURL: resolvedTarget
    )
  }

  /// Resolves the best YouTube target for the active channel and pushes it to the
  /// chat service. Runs whenever the active channel changes.
  func refreshYouTubeAutoTarget() async {
    let login = activeChannel
    guard !login.isEmpty else { return }
    let resolved = await Self.resolveYouTubeTarget(forTwitchLogin: login)
    guard login == activeChannel else { return }
    youtubeAutoResolvedTarget = resolved
    applyExperimentalYouTubeSettings()
  }

  /// Makes an educated guess at a channel's YouTube live source from its Twitch
  /// profile. Streamers often list several YouTube links (main channel, a VOD
  /// channel, a podcast, …), so we score each one against the streamer's Twitch
  /// identity instead of blindly taking the first. Falls back to a YouTube link
  /// in the bio, then a `@<twitch-login>` guess.
  static func resolveYouTubeTarget(forTwitchLogin login: String) async -> String {
    let fallback = "@\(login)"
    guard let profile = await ChannelProfileService.fetch(login: login) else {
      return fallback
    }

    if let best = bestYouTubeChannelURL(
      among: profile.socialLinks,
      twitchLogin: login,
      displayName: profile.displayName
    ) {
      return best
    }
    if let descLink = firstYouTubeChannelURL(in: profile.description ?? "") {
      return descLink
    }
    return fallback
  }

  /// Picks the YouTube channel link most likely to be the streamer's *primary*
  /// live channel. Returns nil when no candidate looks confident enough, so the
  /// caller can fall back rather than merge with the wrong channel (e.g. a
  /// podcast or clips channel the streamer also links).
  static func bestYouTubeChannelURL(
    among links: [ChannelSocialLink],
    twitchLogin: String,
    displayName: String
  ) -> String? {
    let candidates = links.filter { isYouTubeChannelURL($0.url) }
    guard !candidates.isEmpty else { return nil }

    let loginKey = normalizeIdentity(twitchLogin)
    let nameKey = normalizeIdentity(displayName)
    let secondaryMarkers = [
      "podcast", "vod", "vods", "clip", "clips", "shorts", "archive", "replay",
      "replays", "music", "topic", "highlight", "highlights", "fan", "second",
    ]

    func score(_ link: ChannelSocialLink) -> Int {
      var score = 0
      let handle = normalizeIdentity(youtubeHandle(from: link.url) ?? "")
      let label = link.title.lowercased()
      let haystack = "\(label) \(handle)"

      // Strongest signal: the YouTube handle matches the Twitch identity.
      if !handle.isEmpty {
        if handle == loginKey || (!nameKey.isEmpty && handle == nameKey) {
          score += 100
        } else if !loginKey.isEmpty, handle.contains(loginKey) {
          score += 60
        } else if nameKey.count >= 3, handle.contains(nameKey) {
          score += 50
        }
      }

      // The streamer labelled it as their main YouTube.
      if ["youtube", "youtube channel", "main", "main channel", "live"].contains(label) {
        score += 20
      }

      // Down-rank obvious secondary channels (podcasts, VOD/clip dumps, …).
      if secondaryMarkers.contains(where: { haystack.contains($0) }) {
        score -= 40
      }

      return score
    }

    let scored = candidates.map { ($0.url, score($0)) }
    guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
      return nil
    }
    return best.0
  }

  /// True for URLs that point at a YouTube *channel* (rather than a single video),
  /// e.g. `/@handle`, `/channel/UC…`, `/c/Name`, or `/user/Name`.
  static func isYouTubeChannelURL(_ string: String) -> Bool {
    let lower = string.lowercased()
    guard lower.contains("youtube.com") else { return false }
    return lower.contains("/@")
      || lower.contains("/channel/")
      || lower.contains("/c/")
      || lower.contains("/user/")
  }

  /// Extracts the channel handle / id segment from a YouTube channel URL.
  static func youtubeHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    let parts = comps.path.split(separator: "/").map(String.init)
    if let at = parts.first(where: { $0.hasPrefix("@") }) {
      return String(at.dropFirst())
    }
    if parts.count >= 2, ["channel", "c", "user"].contains(parts[0].lowercased()) {
      return parts[1]
    }
    return parts.first
  }

  /// Lowercases and strips everything but letters/digits for loose comparison.
  static func normalizeIdentity(_ raw: String) -> String {
    String(
      String.UnicodeScalarView(
        raw.lowercased().unicodeScalars.filter {
          CharacterSet.alphanumerics.contains($0)
        }))
  }

  static func firstYouTubeChannelURL(in text: String) -> String? {
    let separators = CharacterSet(charactersIn: " \n\t\r,;|()<>[]\"'")
    for raw in text.components(separatedBy: separators) {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, isYouTubeChannelURL(token) else { continue }
      return token
    }
    return nil
  }

  /// The delay to hold chat by so it lines up with the on-screen video.
  ///
  /// This must be the *broadcast* (glass-to-glass) latency, i.e. how far behind
  /// real time the picture is — which is exactly what the wall-clock estimate
  /// (`now − EXT-X-PROGRAM-DATE-TIME`) measures. The live-edge value is only the
  /// small in-buffer gap to the playlist edge (a few seconds) and would leave
  /// chat running far ahead, so it's not used for syncing.
  var chatSyncDelaySeconds: Double? {
    wallClockLatencySeconds
  }

  /// Push the current sync preference + measured latency into the chat service.
  /// Called when the toggle changes and on each latency sample.
  func applyChatSyncSettings() {
    chat.configureChatSync(
      enabled: chatSyncToStream,
      delaySeconds: chatSyncDelaySeconds ?? 0
    )
  }

  /// Human-readable explanation shown under the Stream Sync toggle.
  var chatSyncStatusDescription: String {
    guard chatSyncToStream else {
      return "Chat shows in real time, so it runs ahead of the delayed video."
    }
    if let seconds = chatSyncDelaySeconds, seconds >= 0.75 {
      return "Holding chat ~\(formatLatencySeconds(seconds)) to match the video."
    }
    return "Measuring stream delay… chat will sync once latency is known."
  }
}

extension View {
  @ViewBuilder
  fileprivate func TwizzControlButtonStyle() -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.automatic)
    }
  }

  /// Native Liquid Glass for the compact chat-settings controls: the exact same
  /// `.glass` / `.glassProminent` button styles the app's main SettingsView
  /// uses, so these pills/rows look and focus identically to the rest of the
  /// app (and to the playback controls on the player bar) instead of a custom
  /// imitation. Selected options render prominent; everything else is plain
  /// glass. Falls back to bordered styles before tvOS 26.
  @ViewBuilder
  func chatSettingsGlassButton(isSelected: Bool = false) -> some View {
    if #available(tvOS 26.0, *) {
      if isSelected {
        // Active state mirrors the main SettingsView pills: native prominent
        // glass plus a trailing checkmark (added by the caller). No tint — the
        // prominent fill + checkmark is the established app pattern.
        self.buttonStyle(.glassProminent)
      } else {
        self.buttonStyle(.glass)
      }
    } else {
      if isSelected {
        self.buttonStyle(.borderedProminent)
      } else {
        self.buttonStyle(.bordered)
      }
    }
  }
}

/// Reports the natural height of the chat-settings content so the floating panel
/// can size itself to fit (and animate) rather than always filling the pane.
struct ChatSettingsHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Reports the measured height of the player's right-side control buttons row so
/// the stream title can be capped to it (keeping the buttons at a fixed position
/// regardless of title length).
private struct ControlButtonsHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A completely passthrough button style for the chat input surface.
/// Suppresses all platform button visuals (hover, scale, ring) so only
/// the SwiftUI glass shell controls the appearance.
struct ChatInputButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Gives the chat composer field a single Liquid Glass capsule that is the *same*
/// element at rest and when focused — it simply brightens (white-tinted glass) and
/// lifts slightly on focus, the way native tvOS controls do, instead of swapping in
/// a separate opaque card on top. Keeping one view subtree (only the parameters
/// change with `isFocused`) preserves view identity so SwiftUI animates it as one
/// element growing. Falls back to `.ultraThinMaterial` on systems older than tvOS 26.
struct ChatGlassFieldStyle: ViewModifier {
  let isFocused: Bool

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .glassEffect(isFocused ? .regular.tint(.white) : .regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    } else {
      content
        .background(
          isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: shape
        )
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    }
  }
}

/// Wraps `ChatView` and reads the live `ChatService` itself. New chat messages
/// mutate `chat.messages`; doing that read inside this small view (instead of in
/// the giant PlayerView body) means only the chat column re-renders per message.
/// Previously the PlayerView body observed `chat.messages`, so every incoming
/// message re-executed the whole body and flashed the open Quality menu's focus
/// many times a second on busy channels.
private struct ChatMessagesColumn: View {
  /// Live IRC source (live player). Mutually exclusive with `replay`.
  var chat: ChatService? = nil
  /// VOD chat-replay source. Mutually exclusive with `chat`.
  var replay: VODChatReplayService? = nil
  let channel: String
  let replayStartMessageID: ChatMessage.ID?
  let textSize: CGFloat
  let emoteSize: CGFloat
  let messageSpacing: CGFloat
  let lineHeight: CGFloat
  let letterSpacing: CGFloat
  let animatedEmotes: Bool
  let fontStyle: ChatFontStyle
  let showBadges: Bool
  let useGlassBackground: Bool
  let useLighterOverlayBackground: Bool
  let autoScroll: Bool
  let softPauseRemaining: Int?
  let softPauseTotal: Int
  let scrollTarget: ChatScrollTarget?

  private var visibleMessages: [ChatMessage] {
    if let replay { return replay.messages }
    guard let chat else { return [] }
    guard let startID = replayStartMessageID else { return chat.messages }
    guard let startIndex = chat.messages.firstIndex(where: { $0.id == startID }) else {
      return chat.messages
    }
    return Array(chat.messages[startIndex...])
  }

  private var isConnected: Bool { replay?.isReady ?? chat?.isConnected ?? false }
  private var emoteURLs: [String: URL] { replay?.emoteURLs ?? chat?.emoteURLs ?? [:] }
  private var badgeURLs: [String: URL] { replay?.badgeURLs ?? chat?.badgeURLs ?? [:] }
  private var cheermotes: [Cheermote] { replay?.cheermotes ?? chat?.cheermotes ?? [] }
  /// VOD comments carry no `bits` tag, so cheermote tokens there are matched by
  /// token alone (the way Twitch renders VOD cheers). Live chat stays gated on
  /// the IRC `bits` tag to avoid false positives.
  private var matchCheersWithoutBits: Bool { replay != nil }

  var body: some View {
    ChatView(
      channel: channel,
      messages: visibleMessages,
      textSize: textSize,
      emoteSize: emoteSize,
      messageSpacing: messageSpacing,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      animatedEmotes: animatedEmotes,
      fontStyle: fontStyle,
      showBadges: showBadges,
      isConnected: isConnected,
      emoteURLs: emoteURLs,
      badgeURLs: badgeURLs,
      cheermotes: cheermotes,
      matchCheersWithoutBits: matchCheersWithoutBits,
      useGlassBackground: useGlassBackground,
      useLighterOverlayBackground: useLighterOverlayBackground,
      autoScroll: autoScroll,
      softPauseRemaining: softPauseRemaining,
      softPauseTotal: softPauseTotal,
      scrollTarget: scrollTarget
    )
  }
}

/// The native quality picker, extracted into its own `Equatable` view so the
/// player's once-per-second latency/diagnostics state churn doesn't re-render
/// (and visibly re-focus / "blink") the open `Menu`. SwiftUI only re-evaluates
/// this view when one of the value inputs compared in `==` actually changes.
private struct QualityMenu: View, Equatable {
  let options: [String]
  let selectedOption: String
  let buttonLabel: String
  let reservedWidthLabels: [String]
  let displayLabel: (String) -> String
  let onSelect: (Int) -> Void
  let onMenuPresented: () -> Void
  let onMenuDismissed: () -> Void
  // Sleep timer, nested as a submenu under the quality list (no extra button).
  let sleepOptions: [String]
  let sleepSelectedIndex: Int
  let sleepIsArmed: Bool
  let onSelectSleep: (Int) -> Void

  nonisolated static func == (lhs: QualityMenu, rhs: QualityMenu) -> Bool {
    lhs.options == rhs.options
      && lhs.selectedOption == rhs.selectedOption
      && lhs.buttonLabel == rhs.buttonLabel
      && lhs.reservedWidthLabels == rhs.reservedWidthLabels
      && lhs.sleepSelectedIndex == rhs.sleepSelectedIndex
      && lhs.sleepIsArmed == rhs.sleepIsArmed
  }

  /// Drives the inline `Picker` selection. Reading derives the current index
  /// from `selectedOption`; writing routes through `onSelect` so the player
  /// applies the quality change and its side effects.
  private var selection: Binding<Int> {
    Binding(
      get: { options.firstIndex(of: selectedOption) ?? 0 },
      set: { onSelect($0) }
    )
  }

  private var sleepSelection: Binding<Int> {
    Binding(
      get: { sleepSelectedIndex },
      set: { onSelectSleep($0) }
    )
  }

  private var sleepMenuLabel: String {
    guard sleepIsArmed, sleepOptions.indices.contains(sleepSelectedIndex) else {
      return "Sleep timer"
    }
    return "Sleep timer: \(sleepOptions[sleepSelectedIndex])"
  }

  var body: some View {
    // Invisible barrier: hidden copies of every possible label reserve the
    // width of the widest one, so the in-player title's available space stays
    // constant. The barrier draws nothing and isn't focusable — only the Menu
    // is interactive, and its platter hugs the live label, so the visible
    // button stays variable-width. Trailing alignment parks the button against
    // the next control, letting the reserved slack sit (invisibly) on its left.
    ZStack(alignment: .trailing) {
      ForEach(reservedWidthLabels, id: \.self) { candidate in
        qualityLabelText(candidate).hidden()
      }

      Menu {
        // A `Picker` is Apple's recommended single-selection control inside a
        // menu: it renders a checkmark in a reserved leading gutter so every
        // row's text stays aligned (no per-row shift), unlike hand-placed
        // checkmark labels.
        Picker("Quality", selection: selection) {
          ForEach(Array(options.enumerated()), id: \.element) { index, option in
            Text(displayLabel(option)).tag(index)
          }
        }
        .pickerStyle(.inline)
        .onAppear(perform: onMenuPresented)
        .onDisappear(perform: onMenuDismissed)

        Divider()

        // Sleep timer kept as a nested submenu so Quality stays the primary,
        // one-tap control while the timer hides one level deeper.
        Menu {
          Picker("Sleep timer", selection: sleepSelection) {
            ForEach(Array(sleepOptions.enumerated()), id: \.element) { index, option in
              Text(option).tag(index)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label(sleepMenuLabel, systemImage: "moon.zzz")
        }
      } label: {
        qualityLabelText(buttonLabel)
          .accessibilityLabel("Quality, \(buttonLabel)")
      }
    }
  }

  /// `true` for the live "Auto (1080p60)" form, which we render slightly
  /// smaller so the parenthetical resolution reads as a secondary detail.
  private func isAutoResolutionLabel(_ text: String) -> Bool {
    text.hasPrefix("Auto (")
  }

  @ViewBuilder
  private func qualityLabelText(_ text: String) -> some View {
    Group {
      if isAutoResolutionLabel(text) {
        Text(text)
          .font(.system(size: Self.compactQualityFontSize, weight: .semibold))
      } else {
        Text(text)
          .font(.subheadline)
          .fontWeight(.semibold)
      }
    }
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
  }

  /// 20% smaller than `.subheadline`, used for the "Auto (1080p60)" label.
  private static var compactQualityFontSize: CGFloat {
    UIFont.preferredFont(forTextStyle: .subheadline).pointSize * 0.8
  }
}

/// A `UITextField` subclass that refuses focus-engine focus on tvOS. The chat
/// composer's SwiftUI `Button` owns focus and draws the visible capsule; this
/// field exists only to host the keyboard via `becomeFirstResponder()`. Without
/// this, the tvOS focus engine focuses the embedded field too and paints its own
/// rounded platter, producing a "button inside the input" look.
private final class NonFocusableTextField: UITextField {
  override var canBecomeFocused: Bool { false }
}

/// Hosts the tvOS keyboard for the chat composer. The visible capsule and draft
/// text are drawn in SwiftUI; this `UITextField` stays visually clear so only
/// the Liquid Glass capsule shows. It deliberately keeps a normal (non‑zero)
/// alpha — tvOS treats near‑invisible views as hidden and instantly resigns
/// their first responder, which is why the previous version's keyboard vanished
/// the moment it appeared. Becoming first responder is also deferred off the
/// SwiftUI update pass so it isn't torn down by the in‑flight view update.
struct ChatKeyboardHostField: UIViewRepresentable {
  @Binding var text: String
  var activationToken: Int = 0
  var onSubmit: () -> Void = {}
  /// Keyboard return-key label. The chat composer uses `.send`; the settings
  /// URL field uses `.done` (and dismisses on return rather than posting).
  var returnKeyType: UIReturnKeyType = .send
  /// When true, pressing return resigns first responder and dismisses the
  /// keyboard instead of keeping the field active.
  var dismissesOnReturn: Bool = false

  /// Shown only as the prompt at the top of the tvOS keyboard entry screen
  /// (the placeholder is surfaced there by the system). It is applied just
  /// before the keyboard presents and cleared when editing ends, so it never
  /// renders inline behind the resting glass capsule.
  var keyboardPrompt: String = "Your message posts to chat immediately"

  func makeUIView(context: Context) -> UITextField {
    let field = NonFocusableTextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.backgroundColor = .clear
    field.textColor = .clear
    field.tintColor = .clear
    field.font = .preferredFont(forTextStyle: .callout)
    field.returnKeyType = returnKeyType
    field.enablesReturnKeyAutomatically = !dismissesOnReturn
    field.autocorrectionType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.addTarget(
      context.coordinator,
      action: #selector(Coordinator.editingChanged(_:)),
      for: .editingChanged
    )
    return field
  }

  func updateUIView(_ uiView: UITextField, context: Context) {
    context.coordinator.parent = self
    if uiView.text != text {
      uiView.text = text
    }

    if context.coordinator.lastActivationToken != activationToken {
      context.coordinator.lastActivationToken = activationToken
      DispatchQueue.main.async {
        if !uiView.isFirstResponder {
          // Set the prompt right before presenting so the keyboard screen shows
          // it; it's cleared again in textFieldDidEndEditing to avoid leaking
          // behind the resting capsule.
          uiView.placeholder = self.keyboardPrompt
          uiView.becomeFirstResponder()
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self, lastActivationToken: activationToken)
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: ChatKeyboardHostField
    var lastActivationToken: Int

    init(_ parent: ChatKeyboardHostField, lastActivationToken: Int) {
      self.parent = parent
      self.lastActivationToken = lastActivationToken
    }

    @objc func editingChanged(_ field: UITextField) {
      parent.text = field.text ?? ""
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      // Clear the prompt so it never renders inline behind the resting capsule.
      textField.placeholder = nil
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.onSubmit()
      if parent.dismissesOnReturn {
        textField.resignFirstResponder()
        return true
      }
      return false
    }
  }
}

/// A small progress pill shown after sending a chat message while stream-sync
/// is holding chat back, counting down until the sent message reaches the
/// delayed video on screen.
private struct ChatSyncSendIndicator: View {
  let deadline: Date
  let total: Double

  var body: some View {
    TimelineView(.animation) { context in
      let remaining = max(0, deadline.timeIntervalSince(context.date))
      let progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 1
      HStack(spacing: 10) {
        Icon(glyph: .clock, size: 16)
          .foregroundStyle(.white.opacity(0.7))
        VStack(alignment: .leading, spacing: 4) {
          Text(
            remaining > 0.5
              ? "Sent — appears in \(Int(remaining.rounded()))s"
              : "Appearing now…"
          )
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.82))
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(.purple)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

/// Styles the chat pane as a floating, rounded Liquid Glass panel when enabled,
/// otherwise leaves it as a full-height docked panel.
private struct GlassChatPaneStyle: ViewModifier {
  let enabled: Bool

  /// Inset between the glass panel and the screen edges.
  static let edgeInset: CGFloat = 24

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 40, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      glassBody(content)
        .padding(.vertical, GlassChatPaneStyle.edgeInset)
        .padding(.trailing, GlassChatPaneStyle.edgeInset)
    } else {
      content.frame(maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func glassBody(_ content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

/// Gives the floating chat-settings panel the same real Liquid Glass surface as
/// the Glass chat pane (`.glassEffect(.regular)`), with a matching subtle white
/// hairline. Unlike `GlassChatPaneStyle` it does not clip or inset, so the
/// panel can size to its content and its inner focus effects can lift freely.
struct ChatSettingsPanelGlassStyle: ViewModifier {
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 40, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        // Same darkening scrim the Glass chat pane paints over its glass
        // (ChatView uses Color.black.opacity(0.22)); without it the panel's bare
        // glass read noticeably lighter than the chat beside it.
        .background(Color.black.opacity(0.22), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(Color.black.opacity(0.22), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

/// A single timestamped diagnostics event (stall, jump, or reload) shown in the
/// experimental latency overlay so playback hiccups can be observed directly.
struct DiagnosticsEvent: Identifiable {
  let id = UUID()
  let at: Date
  let text: String
}

/// Passive latency HUD chip. Its own `View` type so the per-second latency
/// refresh only invalidates this chip, not the whole `PlayerView` body.
/// Holds the once-per-second monitoring bookkeeping written by the live-latency
/// and playback-watchdog tasks. It is a *plain* (non-`@Observable`) reference
/// type on purpose: `PlayerView` keeps it in `@State`, and mutating these
/// properties therefore never invalidates the view. Previously these were
/// individual `@State` values, so each per-second write re-executed the entire
/// PlayerView body and made the focused quality button's highlight flash. None
/// of these values drive the UI directly — the only on-screen latency reading is
/// pushed (de-duplicated) into `LatencyReadout`, which the badge observes.
final class PlaybackMonitorBox {
  var wallClockLatencySeconds: Double?
  var liveEdgeLatencySeconds: Double?
  var smoothedLatencySeconds: Double?
  /// Total settled latency samples since playback became active.
  var latencySampleCount = 0
  /// Consecutive samples whose smoothed value barely moved — i.e. the reading
  /// has stopped climbing off the live edge and looks trustworthy.
  var latencyStableCount = 0
  var isPlaybackActive = false
  var didRequestPlayback = false
  var lastHardCatchUpJumpAt = Date.distantPast
  var lastWallClockCatchUpAt = Date.distantPast
  var edgeLatencyLowConfidenceStreak = 0
  var wallClockHighLatencyStreak = 0
  var wallClockLowConfidenceStreak = 0
  var lastPlaybackDateSample: Date?
  var lastPlaybackTimeSampleSeconds: Double?
  var lastObservedPlaybackTimeSeconds: Double?
  var stalledPlaybackSamples = 0
  var isRecoveringPlayback = false
  var lastRecoveryAttemptAt = Date.distantPast
  /// When the player first entered a sustained "waiting with a starved buffer"
  /// state. Drives the authoritative end-of-stream (offline) probe.
  var liveStallWaitingSince: Date?
  /// Guards against overlapping offline probes and rate-limits them.
  var offlineProbeInFlight = false
  var lastOfflineProbeAt = Date.distantPast
}

/// The only latency state SwiftUI observes for the on-screen badge. Updated once
/// per second (and only when the rendered value actually changes), so the badge
/// leaf re-renders in isolation instead of churning the whole player.
@Observable
final class LatencyReadout {
  var color: Color = .gray
  var label: String = "Waiting for playback"

  /// Assigns only on change so an unchanged tick produces no SwiftUI update.
  func update(color newColor: Color, label newLabel: String) {
    if color != newColor { color = newColor }
    if label != newLabel { label = newLabel }
  }
}

private struct LatencyBadge: View {
  @Bindable var readout: LatencyReadout

  var body: some View {
    let shape = Capsule(style: .continuous)
    return HStack(spacing: 8) {
      Circle()
        .fill(readout.color)
        .frame(width: 8, height: 8)

      Text(readout.label)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    // Frosted material rather than focusable Liquid Glass: this is a passive
    // HUD readout, so it should read as an info chip, not a pressable control.
    .background(.ultraThinMaterial, in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }
}

/// Isolated state the rewind transport bar observes, mirrored from the player's
/// real `seekableTimeRanges` once per second (and immediately after each seek).
/// Assigns only on change so an unchanged tick produces no SwiftUI update and the
/// bar re-renders in isolation instead of churning the whole player.
@Observable
final class RewindReadout {
  /// 0 = oldest retained moment, 1 = live edge.
  var positionFraction: Double = 1
  /// How far the playhead sits behind the live edge, in seconds.
  var behindLiveSeconds: Double = 0
  /// Total length of the seekable (retained) window, in seconds.
  var windowSeconds: Double = 0
  var isPaused: Bool = false
  var isAtLiveEdge: Bool = true
  /// VOD mode: show elapsed/total time and a neutral (non-live) track instead of
  /// the LIVE edge + "behind live" readout.
  var isVOD: Bool = false
  var elapsedSeconds: Double = 0
  var totalSeconds: Double = 0

  func update(
    positionFraction pf: Double,
    behindLiveSeconds behind: Double,
    windowSeconds window: Double,
    isPaused paused: Bool,
    isAtLiveEdge live: Bool
  ) {
    let clampedPF = min(max(pf, 0), 1)
    if abs(positionFraction - clampedPF) > 0.002 { positionFraction = clampedPF }
    if abs(behindLiveSeconds - behind) > 0.49 { behindLiveSeconds = behind }
    if abs(windowSeconds - window) > 0.49 { windowSeconds = window }
    if isPaused != paused { isPaused = paused }
    if isAtLiveEdge != live { isAtLiveEdge = live }
  }
}

/// Single DVR scrub bar shown along the bottom of the live player, modeled on
/// YouTube's live transport bar. It is the label of a focus-trapping `Button`
/// (the player surface is passive), so left/right step ±10s, the trackpad scrubs
/// with analog precision, clicking it (or the remote play/pause button) toggles
/// pause, and scrubbing/swiping right returns to the live edge. The container is a
/// subtle, fixed Liquid Glass pill; focus emphasis lives on the seek orb, which
/// grows and glows — not on the whole bar.
private struct RewindScrubBar: View {
  @Bindable var readout: RewindReadout
  let isFocused: Bool

  private func behindLabel() -> String {
    if readout.isVOD {
      return "\(Self.clock(readout.elapsedSeconds)) / \(Self.clock(readout.totalSeconds))"
    }
    if readout.isAtLiveEdge { return "LIVE" }
    let total = Int(readout.behindLiveSeconds.rounded())
    let m = total / 60
    let s = total % 60
    return String(format: "-%d:%02d", m, s)
  }

  /// Formats a number of seconds as M:SS, or H:MM:SS for hour-plus durations.
  private static func clock(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    let trackHeight: CGFloat = 6
    let orbSize: CGFloat = isFocused ? 30 : 16
    let fillColor = (readout.isAtLiveEdge && !readout.isVOD) ? Color.red : Color.white

    return HStack(spacing: 18) {
      GeometryReader { geo in
        let width = geo.size.width
        let x = max(0, min(width, width * readout.positionFraction))
        ZStack(alignment: .leading) {
          // Full track (retained window).
          Capsule()
            .fill(.white.opacity(0.20))
            .frame(height: trackHeight)
          // Played / behind-to-live portion.
          Capsule()
            .fill(fillColor)
            .frame(width: x, height: trackHeight)
          // Seek orb — the focus target. Grows and glows when focused.
          ZStack {
            Circle()
              .fill(.white)
              .frame(width: orbSize, height: orbSize)
              .shadow(
                color: .white.opacity(isFocused ? 0.7 : 0.0),
                radius: isFocused ? 10 : 0)
              .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            if readout.isPaused, isFocused {
              Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
            }
          }
          .frame(width: orbSize, height: orbSize)
          .offset(x: x - orbSize / 2)
          .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .frame(maxHeight: .infinity, alignment: .center)
      }
      .frame(height: 36)

      HStack(spacing: 6) {
        if readout.isAtLiveEdge {
          Circle().fill(.red).frame(width: 8, height: 8)
        }
        Text(behindLabel())
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundStyle(.white)
          .monospacedDigit()
      }
      .frame(minWidth: 72, alignment: .trailing)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 16)
    .modifier(ScrubBarGlassBackground(shape: shape, isFocused: isFocused))
  }
}

/// Liquid Glass backing for the scrub bar pill. Stays the *same* subtle glass at
/// rest and focused (a faint white-tint lift on focus), mirroring the chat pane
/// glass, so the focus signal reads on the orb rather than the container. Falls
/// back to `.ultraThinMaterial` on systems older than tvOS 26.
private struct ScrubBarGlassBackground: ViewModifier {
  let shape: RoundedRectangle
  let isFocused: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .glassEffect(isFocused ? .regular.tint(.white.opacity(0.10)) : .regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.22 : 0.10), lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.22 : 0.10), lineWidth: 1))
        .clipShape(shape)
    }
  }
}

/// Passthrough button style for the scrub bar: the bar provides its own focus
/// emphasis (the orb), so we suppress tvOS's default button chrome (the lift,
/// scale and pressed dimming) that would otherwise fight the custom look.
private struct ScrubBarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Reads the Siri Remote trackpad as a *relative* swipe surface for scrubbing.
/// A plain (non-`@Observable`) reference type held in `@State` so its per-frame
/// work never invalidates `PlayerView`; it only calls back out through closures.
///
/// The Siri Remote surfaces as a `GCMicroGamepad`. Setting
/// `reportsAbsoluteDpadValues = true` makes `dpad` report the finger's absolute
/// position in [-1, 1], snapping to exactly (0, 0) on lift. We integrate the
/// frame-to-frame *change* in that position — so a resting finger (however
/// off-center) produces no movement, and only an actual swipe scrubs. The orb
/// tracks how far/fast the finger moved, and a momentum tail continues the glide
/// after release, decaying to a stop.
final class ScrubInputCoordinator {
  /// Fires once a swipe passes the tap threshold (so a click-to-pause never
  /// registers as a scrub). The view pauses playback here.
  var onScrubBegan: (() -> Void)?
  /// Per-frame finger travel (in trackpad units) while swiping or coasting. The
  /// view converts this to timeline seconds proportional to the window.
  var onScrubMoved: ((Double) -> Void)?
  /// Fires when the swipe and its momentum tail have fully settled.
  var onScrubEnded: (() -> Void)?

  private enum Phase { case idle, pending, tracking, momentum }

  private var displayLink: CADisplayLink?
  private var connectObserver: NSObjectProtocol?
  private var phase: Phase = .idle
  private var lastX: Double = 0
  private var pendingTravel: Double = 0
  /// Smoothed finger velocity in units/sec, used to seed the momentum tail.
  private var velocity: Double = 0

  /// Movement (in dpad units) required before a touch counts as a swipe rather
  /// than a tap/click.
  private let tapThreshold = 0.05
  /// Per-frame multiplicative decay applied to the momentum velocity.
  private let momentumDecay = 0.88
  /// Below this speed (units/sec) the momentum tail is considered stopped.
  private let momentumStop = 0.12
  /// Clamp on the seed velocity so a hard flick can't launch a huge jump.
  private let maxMomentumVelocity = 3.0

  func start() {
    guard displayLink == nil else { return }
    configureControllers()
    connectObserver = NotificationCenter.default.addObserver(
      forName: .GCControllerDidConnect, object: nil, queue: .main
    ) { [weak self] _ in self?.configureControllers() }
    let link = CADisplayLink(target: self, selector: #selector(handleTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    if let connectObserver {
      NotificationCenter.default.removeObserver(connectObserver)
    }
    connectObserver = nil
    let wasActive = (phase == .tracking || phase == .momentum)
    phase = .idle
    velocity = 0
    pendingTravel = 0
    if wasActive { onScrubEnded?() }
  }

  private func configureControllers() {
    for controller in GCController.controllers() {
      controller.microGamepad?.reportsAbsoluteDpadValues = true
    }
    GCController.current?.microGamepad?.reportsAbsoluteDpadValues = true
  }

  private func currentTouch() -> (x: Double, touching: Bool) {
    let pad = GCController.current?.microGamepad
      ?? GCController.controllers().first(where: { $0.microGamepad != nil })?.microGamepad
    let x = Double(pad?.dpad.xAxis.value ?? 0)
    let y = Double(pad?.dpad.yAxis.value ?? 0)
    // The dpad snaps to exactly (0, 0) only on lift; a mid-swipe pass through the
    // center still reports tiny non-zero noise, so exact-zero means "not touching".
    return (x, x != 0 || y != 0)
  }

  @objc private func handleTick(_ link: CADisplayLink) {
    let duration = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
    let sample = currentTouch()

    switch phase {
    case .idle:
      if sample.touching {
        phase = .pending
        lastX = sample.x
        pendingTravel = 0
        velocity = 0
      }

    case .pending:
      if sample.touching {
        let dx = sample.x - lastX
        lastX = sample.x
        pendingTravel += dx
        velocity = velocity * 0.6 + (dx / duration) * 0.4
        if abs(pendingTravel) > tapThreshold {
          phase = .tracking
          onScrubBegan?()
          onScrubMoved?(pendingTravel)
        }
      } else {
        // Released without moving far enough — it was a tap/click, not a scrub.
        phase = .idle
      }

    case .tracking:
      if sample.touching {
        let dx = sample.x - lastX
        lastX = sample.x
        velocity = velocity * 0.6 + (dx / duration) * 0.4
        if dx != 0 { onScrubMoved?(dx) }
      } else {
        // Finger lifted: start coasting from the smoothed release velocity.
        velocity = min(max(velocity, -maxMomentumVelocity), maxMomentumVelocity)
        phase = .momentum
      }

    case .momentum:
      velocity *= momentumDecay
      if abs(velocity) < momentumStop {
        phase = .idle
        velocity = 0
        onScrubEnded?()
      } else {
        onScrubMoved?(velocity * duration)
      }
    }
  }
}

/// Small top-right chip showing the armed sleep timer: a `m:ss` countdown for
/// timed sleeps, or a short label (e.g. "End") when set to sleep at end of
/// stream.
private struct SleepCountdownBadge: View {
  let text: String

  static func format(seconds: Int) -> String {
    let clamped = max(0, seconds)
    return String(format: "%d:%02d", clamped / 60, clamped % 60)
  }

  var body: some View {
    let shape = Capsule(style: .continuous)
    return HStack(spacing: 8) {
      Image(systemName: "moon.zzz.fill")
        .font(.caption)
        .foregroundStyle(.white)

      Text(text)
        .font(.caption)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }
}

// MARK: - Sleeping screen

/// Deterministic, seedable RNG so the star field is generated once and never
/// reshuffles between frames.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
  mutating func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    var x = state
    x ^= x >> 33
    x = x &* 0xFF51AFD7ED558CCD
    x ^= x >> 33
    return x
  }
}

private struct SleepStar {
  let x: Double
  let y: Double
  let size: Double
  let baseOpacity: Double
  let twinkleSpeed: Double
  let phase: Double
  let warmth: Double   // 0 = cool dim white, 1 = warm red
}

private struct SleepShootingStar {
  let startX: Double
  let startY: Double
  let dx: Double
  let dy: Double
  let length: Double
  let period: Double
  let offset: Double
  let duration: Double
}

/// A cute, low-brightness starry-night scene for the post-sleep-timer state.
/// Warm reds + near-black keep it gentle on the eyes in a dark room, and the
/// palette is hard-coded (plus a forced dark color scheme) so it looks the same
/// whether the app is in light or dark mode.
struct SleepingScreen: View {
  private let stars: [SleepStar]
  private let shootingStars: [SleepShootingStar]

  init() {
    var rng = SeededGenerator(seed: 0x5_7A_84)
    stars = (0..<90).map { _ in
      SleepStar(
        x: Double.random(in: 0...1, using: &rng),
        y: Double.random(in: 0...1, using: &rng),
        size: Double.random(in: 1.5...3.8, using: &rng),
        baseOpacity: Double.random(in: 0.26...0.78, using: &rng),
        twinkleSpeed: Double.random(in: 0.4...1.5, using: &rng),
        phase: Double.random(in: 0...(2 * .pi), using: &rng),
        warmth: Double.random(in: 0...1, using: &rng)
      )
    }
    shootingStars = [
      SleepShootingStar(startX: 0.08, startY: 0.16, dx: 0.42, dy: 0.20,
                        length: 0.10, period: 9.0, offset: 1.5, duration: 1.1),
      SleepShootingStar(startX: 0.55, startY: 0.10, dx: 0.36, dy: 0.26,
                        length: 0.08, period: 14.0, offset: 6.0, duration: 1.3)
    ]
  }

  // Hard-coded, night-vision-friendly palette: warm reds blended with the
  // Twizz brand purple so it ties back to the logo while staying eye-friendly.
  private let skyTop = Color(red: 0.06, green: 0.01, blue: 0.04)
  private let skyBottom = Color(red: 0.08, green: 0.015, blue: 0.07)
  private let emberLow = Color(red: 0.30, green: 0.05, blue: 0.06)
  private let ember = Color(red: 0.62, green: 0.16, blue: 0.16)
  private let emberSoft = Color(red: 0.74, green: 0.28, blue: 0.24)
  private let brandPurple = Color(red: 0.569, green: 0.275, blue: 1.0)
  private let purpleGlow = Color(red: 0.42, green: 0.20, blue: 0.78)
  private let purpleSoft = Color(red: 0.66, green: 0.42, blue: 0.96)

  /// Dim white → warm red → brand purple as `warmth` rises, so the star field
  /// is a gentle blend of red and purple sparkle.
  private func starColor(_ warmth: Double, opacity: Double) -> Color {
    let cool = (r: 0.92, g: 0.82, b: 0.80)
    let red = (r: 0.86, g: 0.30, b: 0.28)
    let purple = (r: 0.64, g: 0.38, b: 0.96)
    let c: (r: Double, g: Double, b: Double)
    if warmth < 0.55 {
      let f = warmth / 0.55
      c = (cool.r + (red.r - cool.r) * f,
           cool.g + (red.g - cool.g) * f,
           cool.b + (red.b - cool.b) * f)
    } else {
      let f = (warmth - 0.55) / 0.45
      c = (red.r + (purple.r - red.r) * f,
           red.g + (purple.g - red.g) * f,
           red.b + (purple.b - red.b) * f)
    }
    return Color(red: c.r, green: c.g, blue: c.b).opacity(opacity)
  }

  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      // Slowly drifting glow centers give the scene a gentle, living motion.
      let driftA = UnitPoint(x: 0.30 + 0.14 * sin(t * 0.043),
                             y: 0.34 + 0.10 * cos(t * 0.037))
      let driftB = UnitPoint(x: 0.72 + 0.12 * cos(t * 0.031),
                             y: 0.64 + 0.13 * sin(t * 0.049))
      ZStack {
        // Blur whatever is paused behind (stream frame + chat), then bank it
        // way down into a dark, warm night so it stays easy on the eyes.
        Rectangle()
          .fill(.ultraThinMaterial)
          .ignoresSafeArea()

        LinearGradient(
          colors: [skyTop.opacity(0.92), skyBottom.opacity(0.90), Color.black.opacity(0.92)],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        RadialGradient(
          colors: [emberLow.opacity(0.30), .clear],
          center: driftA, startRadius: 10, endRadius: 620
        )
        .blendMode(.screen)
        .ignoresSafeArea()

        RadialGradient(
          colors: [purpleGlow.opacity(0.26), .clear],
          center: driftB, startRadius: 10, endRadius: 560
        )
        .blendMode(.screen)
        .ignoresSafeArea()

        Canvas { context, size in
          for star in stars {
            let twinkle = 0.5 + 0.5 * sin(t * star.twinkleSpeed + star.phase)
            let opacity = star.baseOpacity * (0.45 + 0.55 * twinkle)
            let d = star.size
            let cx = star.x * size.width
            let cy = star.y * size.height
            // Soft halo for a touch more presence without getting harsh.
            let halo = d * 3.0
            context.fill(
              Path(ellipseIn: CGRect(x: cx - halo / 2, y: cy - halo / 2,
                                     width: halo, height: halo)),
              with: .color(starColor(star.warmth, opacity: opacity * 0.22))
            )
            context.fill(
              Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2,
                                     width: d, height: d)),
              with: .color(starColor(star.warmth, opacity: opacity))
            )
          }

          for shot in shootingStars {
            let local = (t + shot.offset).truncatingRemainder(dividingBy: shot.period)
            guard local >= 0, local <= shot.duration else { continue }
            let p = local / shot.duration
            // Ease in/out so it streaks in and fades away.
            let fade = sin(p * .pi)
            let headX = (shot.startX + shot.dx * p) * size.width
            let headY = (shot.startY + shot.dy * p) * size.height
            let tailX = headX - shot.dx * shot.length * size.width
            let tailY = headY - shot.dy * shot.length * size.height
            var path = Path()
            path.move(to: CGPoint(x: tailX, y: tailY))
            path.addLine(to: CGPoint(x: headX, y: headY))
            context.stroke(
              path,
              with: .linearGradient(
                Gradient(colors: [
                  emberSoft.opacity(0.0),
                  emberSoft.opacity(0.55 * fade)
                ]),
                startPoint: CGPoint(x: tailX, y: tailY),
                endPoint: CGPoint(x: headX, y: headY)
              ),
              lineWidth: 2
            )
          }
        }
        .ignoresSafeArea()

        centerContent(pulse: 0.5 + 0.5 * sin(t * 0.6))
      }
      .ignoresSafeArea()
    }
    .environment(\.colorScheme, .dark)
  }

  private func centerContent(pulse: Double) -> some View {
    VStack(spacing: 22) {
      Image("TwizzPixelLogo")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 132, height: 132)
        .opacity(0.82 + 0.15 * pulse)
        .shadow(color: brandPurple.opacity(0.45), radius: 26)
        .shadow(color: ember.opacity(0.35), radius: 14)

      Text("Sleeping")
        .font(.system(size: 48, weight: .bold))
        .foregroundStyle(
          LinearGradient(
            colors: [emberSoft.opacity(0.85 + 0.15 * pulse),
                     purpleSoft.opacity(0.80 + 0.15 * pulse)],
            startPoint: .leading,
            endPoint: .trailing
          )
        )

      Text("Press to resume")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(emberSoft.opacity(0.5))
    }
  }
}

/// Its own `View` type so the per-second diagnostics refresh invalidates only
/// this panel. The parent computes `lines` (it owns the player state) and
/// passes them in; rendering lives here.
private struct DiagnosticsPanel: View {
  let lines: [String]
  let events: [DiagnosticsEvent]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text("DIAGNOSTICS")
        .font(.system(size: 13, weight: .heavy).monospaced())
        .foregroundStyle(.white.opacity(0.6))

      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.system(size: 14, weight: .semibold).monospaced())
          .foregroundStyle(.white)
      }

      if !events.isEmpty {
        Divider().overlay(.white.opacity(0.2)).padding(.vertical, 2)
        ForEach(events) { event in
          Text(Self.eventLine(event))
            .font(.system(size: 13, weight: .regular).monospaced())
            .foregroundStyle(.white.opacity(0.8))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 520, alignment: .leading)
    .background(.black.opacity(0.55), in: shape)
    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }

  private static func eventLine(_ event: DiagnosticsEvent) -> String {
    let ago = max(0, Int(Date().timeIntervalSince(event.at).rounded()))
    return "• \(event.text)  (\(ago)s ago)"
  }
}

/// Reads the Siri Remote trackpad's absolute finger position so chat can be
/// scrolled by gesture (and held). tvOS only delivers discrete focus-move
/// events to SwiftUI, which makes scrolling feel like fixed little hops; for
/// continuous, gesture-following scrolling we read the remote's micro-gamepad
/// directly. `verticalValue` is +1 at the top of the trackpad, -1 at the
/// bottom, and 0 when the finger is centered or lifted.
final class RemoteTrackpadMonitor {
  private(set) var verticalValue: Float = 0
  private(set) var horizontalValue: Float = 0
  private(set) var hasController = false
  /// True while the touch surface is physically clicked (held down). Used to
  /// drive press-and-hold repeat, which tvOS won't deliver via discrete events.
  private(set) var clickPressed = false
  /// Directional click/press states reported by the micro-gamepad dpad buttons.
  /// These are what we probe to find a signal that distinguishes a *held*
  /// directional press from a mere finger rest.
  private(set) var dpadUpPressed = false
  private(set) var dpadDownPressed = false
  /// Direction (+1 up / -1 down / 0 none) captured at the instant of a click,
  /// while the finger position is still trustworthy. The live dpad/`y` reading
  /// flickers once the surface is clicked, so a held repeat keys off this latch
  /// plus `clickPressed` rather than the live position.
  private(set) var clickLatchedDirection = 0
  private var observers: [NSObjectProtocol] = []

  func start() {
    for controller in GCController.controllers() { configure(controller) }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .GCControllerDidConnect, object: nil, queue: .main
      ) { [weak self] note in
        if let controller = note.object as? GCController { self?.configure(controller) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .GCControllerDidDisconnect, object: nil, queue: .main
      ) { [weak self] _ in
        self?.hasController = !GCController.controllers().isEmpty
        self?.verticalValue = 0
        self?.horizontalValue = 0
        self?.clickPressed = false
        self?.dpadUpPressed = false
        self?.dpadDownPressed = false
        self?.clickLatchedDirection = 0
      })
  }

  func stop() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    verticalValue = 0
    horizontalValue = 0
    clickPressed = false
    dpadUpPressed = false
    dpadDownPressed = false
    clickLatchedDirection = 0
  }

  private func configure(_ controller: GCController) {
    guard let micro = controller.microGamepad else { return }
    hasController = true
    // Absolute values report where the finger *is* on the pad. We use the change
    // in position (finger travel) to drive a swipe, and treat ~(0,0) as lifted.
    micro.reportsAbsoluteDpadValues = true
    micro.dpad.valueChangedHandler = { [weak self] _, x, y in
      self?.horizontalValue = x
      self?.verticalValue = y
    }
    // buttonA is the physical click of the touch surface. Holding it down (with
    // the finger over the up/down zone) is how we detect a held directional
    // press for auto-repeat.
    micro.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self else { return }
      self.clickPressed = pressed
      if pressed {
        // Latch direction now, while the finger position is still reliable.
        if self.dpadUpPressed || self.verticalValue > 0.2 {
          self.clickLatchedDirection = 1
        } else if self.dpadDownPressed || self.verticalValue < -0.2 {
          self.clickLatchedDirection = -1
        } else {
          self.clickLatchedDirection = 0
        }
      } else {
        self.clickLatchedDirection = 0
      }
    }
    micro.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.dpadUpPressed = pressed
    }
    micro.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.dpadDownPressed = pressed
    }
  }
}
