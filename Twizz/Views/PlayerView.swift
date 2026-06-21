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

  /// True while playing a recorded broadcast rather than a live stream — either a
  /// VOD session opened from the channel page (`vod`) or an active Stream Rewind
  /// hand-off into the live broadcast's in-progress VOD (`liveVODHandoff`).
  var isVOD: Bool { activeVOD != nil }

  /// The VOD currently being played, whichever source it came from. `nil` while
  /// playing live.
  var activeVOD: VODContext? {
    if let vod { return vod }
    if let handoff = liveVODHandoff, handoff.isActive {
      return VODContext(id: handoff.broadcast.id, title: handoff.title)
    }
    return nil
  }

  /// True when this player was launched on a live channel (as opposed to a
  /// recorded-broadcast session from the channel page). Only live sessions can
  /// hand off to — and return from — the in-progress broadcast VOD.
  var isLiveSession: Bool { vod == nil }

  /// VODs always expose the transport bar (seek is essential); live exposes it
  /// only when the user has Stream Rewind enabled.
  var rewindAvailable: Bool { isVOD || streamRewindEnabled }

  /// The focus target that "holds" chat while the viewer scrolls it. Live keeps
  /// focus on the composer (tvOS can't reliably focus a ScrollView); VODs have no
  /// composer, so a dedicated invisible scroller target stands in.
  var chatFocusAnchor: Focusable { isVOD ? .chatScroller : .chatInput }

  /// Where focus lands when the viewer leaves an active chat scroll via Back:
  /// the live composer (so they can immediately type) or, on a VOD (no
  /// composer), the collapse-chat button. Never `.chatScroller`, which would
  /// immediately re-pause the replay.
  var chatScrollExitFocus: Focusable { isVOD ? .chatToggle : .chatInput }

  /// The seek bar is reachable ONLY by an explicit up-press from a control-row
  /// button (`requestSeekBarFocus`, which sets `seekBarRequested`). It is
  /// focusable only while it actually holds focus or has just been requested,
  /// which means it never sits in the focus engine as a silent neighbour above
  /// the control row — so a horizontal swipe that carries a little upward drift
  /// can't fling focus onto it, and from rest/chat it isn't a magnet either.
  var scrubberFocusable: Bool {
    focus == .rewindScrubber || seekBarRequested
  }

  /// Control-row buttons in left-to-right visual order. Drives the row-membership
  /// check below.
  var controlOrder: [Focusable] { [.streamInfo, .quality, .chatSettingsButton, .chatToggle] }

  func isControlRowButton(_ f: Focusable?) -> Bool {
    guard let f else { return false }
    return controlOrder.contains(f)
  }

  /// Whether `button` is dropped from the focus engine right now. All four control
  /// buttons are natively focusable together so tvOS's focus engine moves focus
  /// between them instantly and reliably on every press (no programmatic stepping,
  /// no throttle, no dropped or delayed moves). They are removed *only* while chat
  /// is being scrolled, when focus is trapped on the composer. The row is wrapped
  /// in a `.focusSection()` so a swipe can roam the buttons but can't escape to the
  /// chat pane; the seek bar and composer keep their own gates. Expressed as
  /// "removed" so we apply `.focusable(false)` (never `.focusable(true)`, which
  /// hijacks a Button's Select press on tvOS).
  func controlButtonRemoved(_ button: Focusable) -> Bool {
    isChatScrolling
  }

  /// Whether the chat composer (and its send button) should be dropped from the
  /// focus engine. Besides the rewind-bar case, we remove it whenever focus sits
  /// on a control button UNLESS we've just armed a deliberate hop into it
  /// (`chatInputArmed`). Because the other control buttons are pulled out of the
  /// engine during a swipe, the composer would otherwise be the nearest focusable
  /// view to the right of the row, so a swipe would fling onto it (or sail past
  /// the collapse button into chat). Keeping it out until an armed, throttled hop
  /// makes collapse→chat as deliberate as every other step.
  func chatInputFocusBlocked() -> Bool {
    if focus == .rewindScrubber { return true }
    if isControlRowButton(focus) { return !chatInputArmed }
    return false
  }

  /// Jump focus straight to `button`. Used for reveals and deliberate cross-section
  /// jumps (e.g. dropping from the seek bar).
  func activateControl(_ button: Focusable) {
    focus = button
  }

  /// The deliberate hop from the collapse button into the chat input. The composer
  /// is otherwise kept out of the focus engine while focus sits on a control button
  /// (see `chatInputFocusBlocked`), so a swipe roaming the control row can't sail
  /// into chat; only this explicit right-press arms it and moves focus there.
  func stepToChatInput(from source: Focusable) {
    guard showChat else { return }
    chatInputArmed = true
    focus = chatFocusAnchor
  }

  /// Handle an up-press from a control button: reveal the seek bar. Setting
  /// `seekBarRequested` makes the bar focusable for this assignment (it's
  /// otherwise kept out of the engine so it can't be a vertical magnet).
  func requestSeekBarFocus() {
    guard rewindAvailable else { return }
    seekBarRequested = true
    focus = .rewindScrubber
  }

  /// Spoken value for the rewind/seek bar's `accessibilityValue`: VODs read
  /// "elapsed of total", live reads "Live" at the edge or "N behind live".
  var rewindAccessibilityValue: String {
    func spoken(_ seconds: Double) -> String {
      let total = max(0, Int(seconds.rounded()))
      let m = total / 60
      let s = total % 60
      if m > 0 { return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")" }
      return "\(s) second\(s == 1 ? "" : "s")"
    }
    if rewindReadout.isVOD {
      return "\(spoken(rewindReadout.elapsedSeconds)) of \(spoken(rewindReadout.totalSeconds))"
    }
    if rewindReadout.isAtLiveEdge { return "Live" }
    return "\(spoken(rewindReadout.behindLiveSeconds)) behind live"
  }

  /// Selectable VOD playback rates, cycled by the speed control.
  var vodSpeedOptions: [Float] { [0.5, 1.0, 1.25, 1.5, 2.0] }

  /// Compact label for the current VOD rate, e.g. "1×", "1.5×", "0.5×".
  var vodSpeedLabel: String { String(format: "%g×", Double(vodPlaybackRate)) }


  /// The currently-active channel, which can change if the user follows a raid.
  @State var activeChannel: String = ""

  @Environment(\.dismiss) var dismiss
  @Environment(\.themePalette) var palette
  @Environment(\.glassDisabled) var glassDisabled
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @AppStorage("preferredQuality") var preferredQuality = "Auto"
  /// Latency-vs-quality profile for the adaptive ("Auto") stream, surfaced as the
  /// two Auto rows in the quality picker. Stored as the enum raw value; read it
  /// through `livePlaybackProfile`.
  @AppStorage("livePlaybackProfile") var livePlaybackProfileRaw = LivePlaybackProfile.default
    .rawValue
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
  @AppStorage("chatShowPlatformBadges") var chatShowPlatformBadges = ChatAppearance
    .defaultShowPlatformBadges
  /// Global on/off for highlighting chat lines that mention the signed-in user
  /// (and any user keywords below). On by default.
  @AppStorage("chatHighlightMentionsEnabled") var chatHighlightMentionsEnabled = true
  /// User-defined extra highlight keywords (other handles, "giveaway", a game
  /// name…), stored as a single comma/newline-separated string and parsed into a
  /// normalized list by `chatHighlightKeywordList`.
  @AppStorage("chatHighlightKeywords") var chatHighlightKeywords = ""
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
  @AppStorage("experimentalKickMergeEnabled") var experimentalKickMergeEnabled = false
  /// Optional manual override for the Kick merge target. Per-channel and
  /// non-persistent for the same reason as the YouTube override, so a handle
  /// entered for one streamer never leaks into another.
  @State var experimentalKickMergeChannelOrURL = ""
  /// Best-effort Kick target derived from the active Twitch channel (its social
  /// links, then description, then a name-based guess).
  @State var kickAutoResolvedTarget = ""
  @AppStorage(LowLatencyHLSProxy.settingsKey) var lowLatencyProxyEnabled = true
  @AppStorage(LowLatencyHLSProxy.rewindSettingsKey) var streamRewindEnabled = true
  @AppStorage("showLatencyDiagnostics") var showLatencyDiagnostics = false
  /// On-device live captions toggle (beta). See `captionController`.
  @AppStorage("captionsEnabled") var captionsEnabled = false
  /// Caption appearance + timing controls (the Captions settings sub-page).
  /// Font multiplier on the base caption size (0.7…1.6).
  @AppStorage("captionsFontScale") var captionsFontScale = 1.0
  /// Vertical placement, 0 = bottom of safe area, 1 = top.
  @AppStorage("captionsVerticalPosition") var captionsVerticalPosition = 0.0
  /// User timing fine-tune in seconds (+ = captions appear earlier/faster).
  @AppStorage("captionsTimingOffset") var captionsTimingOffset = 0.0
  /// Slab background style (`CaptionBackgroundStyle` raw value).
  @AppStorage("captionsBackgroundStyle") var captionsBackgroundStyleRaw = CaptionBackgroundStyle.blur.rawValue
  /// Draw a dark outline around caption glyphs for legibility.
  @AppStorage("captionsOutline") var captionsOutline = false
  /// Caption text color (`CaptionTextColor` raw value).
  @AppStorage("captionsTextColor") var captionsTextColorRaw = CaptionTextColor.white.rawValue
  /// Caption text opacity, 0.3…1.0.
  @AppStorage("captionsTextOpacity") var captionsTextOpacity = 1.0
  /// Live viewer count badge in the top-left HUD. On by default — a glanceable,
  /// non-diagnostic stat most viewers want while watching.
  @AppStorage("showViewerCount") var showViewerCount = true
  /// Latency readout in the top-left HUD chip. Off by default and independent of
  /// the full Diagnostics Overlay, so viewers who just want the latency number
  /// can enable it without the developer event log.
  @AppStorage("showLatencyBadge") var showLatencyBadge = false

  // Per-event visibility for the passive, read-only event banners (Events
  // sub-page of chat settings). All on by default — they mirror what Twitch
  // shows every viewer — but each can be hidden independently.
  @AppStorage("showRaidEvents") var showRaidEvents = true
  @AppStorage("showHypeTrainEvents") var showHypeTrainEvents = true
  @AppStorage("showPollEvents") var showPollEvents = true
  @AppStorage("showPredictionEvents") var showPredictionEvents = true
  @AppStorage("showGoalEvents") var showGoalEvents = true

  /// Owns the playback engine + chat/events/captions services and the per-frame
  /// monitoring boxes. The engine members are reached by their original names via
  /// the forwarding accessors in `PlayerModel.swift`.
  @State var model = PlayerModel()
  /// Periodic player time observer used in VOD mode to sync chat replay + the
  /// seek readout to the playhead.
  @State var vodTimeObserver: Any?
  /// Debug-only cursor for the "Simulate Interactive Moment" cycle button.
  @State var debugMomentIndex = 0
  @State var showChat: Bool =
    UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool ?? true
  @State var chatReplayStartMessageID: ChatMessage.ID?
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
  @State var kickInputActivationToken: Int = 0
  @State var highlightKeywordsActivationToken: Int = 0
  // Chat send/sync state now lives in PlayerModel.
  @State var hideTask: Task<Void, Never>?
  @State var focusRecoveryTask: Task<Void, Never>?
  @State var isQualityMenuPresented = false
  @State var latencyTask: Task<Void, Never>?
  @State var playbackWatchdogTask: Task<Void, Never>?
  /// Drives the adaptive playback-rate controller at a sub-second cadence — far
  /// faster than the 1 Hz latency monitor — so the anti-stall slow-down can react
  /// to a draining buffer before it empties into a hard stall.
  @State var rateControlTask: Task<Void, Never>?
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
  var lastLiveEdgeSnapAt: Date {
    get { mon.lastLiveEdgeSnapAt }
    nonmutating set { mon.lastLiveEdgeSnapAt = newValue }
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
  /// When the viewer returns to the live edge but the seekable window AVPlayer
  /// holds trails the true broadcast by at least this much, a same-window seek
  /// can't reach real live — so we force a fresh load that lands at the true edge.
  /// Measured as wall-clock behind-live minus the in-window edge gap, so it only
  /// fires when the cached playlist is genuinely stale (not for normal latency).
  let staleLiveWindowSnapThresholdSeconds: Double = 10
  /// Minimum spacing between snap-to-true-live reloads, so a single return-to-live
  /// can never loop into repeated reloads.
  let liveEdgeSnapCooldownSeconds: Double = 6
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
    case simulateRaidButton
    case simulateIncomingRaidButton
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
    /// Main-page drill-in row that opens the Captions sub-page.
    case chatCaptionsButton
    case chatWidthOption(Int)
    case chatLayoutOption(Int)
    case chatSyncToggle
    case chatLowLatencyToggle
    case chatAltSourceToggle
    case chatRewindToggle
    case chatViewerCountToggle
    case chatLatencyToggle
    case chatDiagnosticsToggle
    case chatCaptionsToggle
    case chatCaptionsBackgroundOption(Int)
    case chatCaptionsColorOption(Int)
    case chatCaptionsOutlineToggle
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
    /// Top-level: presets, layout, and drill-in rows.
    case main
    /// Fine-grained version of the Size preset (text/emote/line/spacing).
    case appearance
    /// Playback, stream sync, diagnostics, and experimental toggles.
    case playback
    /// Per-event visibility toggles (raids, hype trains, polls, etc.).
    case events
    /// On-device live captions ("Captions (beta)").
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
    .onChange(of: audioOnlyPlaylistURL) { _, _ in syncCaptions() }
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

  /// Reconcile the on-device caption engine with current playback state. Cheap
  /// to call from multiple hooks — the controller no-ops on unchanged inputs.
  /// Live-only: captioning rides the audio-only side-channel, which doesn't
  /// exist for VOD/clip playback.
  func syncCaptions() {
    captionController.sync(
      enabled: captionsEnabled,
      playlistURL: audioOnlyPlaylistURL,
      headers: PlaybackService.streamHeaders,
      isLive: !isVOD,
      isReady: !isLoading && errorMessage == nil && !isOffline,
      timingOffset: captionsTimingOffset,
      playerClock: { [weak player] in player?.currentItem?.currentDate() }
    )
  }

  var videoColumn: some View {
    ZStack(alignment: .bottom) {
      VideoSurface(player: player)
        .ignoresSafeArea()
        // Shared loading surface: the stream's frame behind the channel's
        // avatar, name, and a native spinner. Anchored as an overlay on the
        // video so it tracks the *exact* video frame in every chat layout — the
        // shrunken column in side mode, full-bleed in overlay/glass — instead of
        // escaping to fullscreen. Cross-fades to live video once playback
        // starts, so opening a stream reads as a quick sharpen instead of a
        // black "Loading…" gap.
        .overlay {
          StreamLoadingView(
            posterURL: posterURL,
            avatarURL: channelAvatarURL,
            title: isVOD ? activeVOD?.title : offlineDisplayName
          )
          .padding(.trailing, loadingChatInset)
          .opacity(isLoading && errorMessage == nil && !isOffline ? 1 : 0)
          .allowsHitTesting(false)
          .animation(.easeOut(duration: 0.45), value: isLoading)
        }

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

      if captionsEnabled, !isVOD, errorMessage == nil, !isOffline {
        CaptionOverlayView(
          controller: captionController,
          controlsVisible: showControls,
          fontScale: captionsFontScale,
          verticalPosition: captionsVerticalPosition,
          backgroundStyle: CaptionBackgroundStyle.from(captionsBackgroundStyleRaw),
          outline: captionsOutline,
          textColor: CaptionTextColor.from(captionsTextColorRaw).color,
          textOpacity: captionsTextOpacity
        )
        .transition(.opacity)
      }

      if showControls, !isLoading,
        errorMessage == nil, !isOffline
      {
        VStack {
          HStack(alignment: .top) {
            PlayerTitleHeader(
              title: streamTitle.isEmpty ? channelDisplayName : streamTitle,
              latency: latencyReadout,
              hermes: hermes,
              showSubheader: !isVOD,
              showLatency: showLatencyBadge,
              showViewerCount: showViewerCount
            )
            Spacer(minLength: 24)
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
        .padding(.trailing, controlsTrailingInset)
        .background(
          LinearGradient(
            stops: [
              .init(color: .black.opacity(1.0), location: 0.0),
              .init(color: .black.opacity(0.72), location: 0.44),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(maxWidth: .infinity)
          .frame(height: 280)
          .allowsHitTesting(false),
          alignment: .top
        )
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

  var bottomOverlay: some View {
    VStack(spacing: 18) {
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
        .accessibilityLabel(rewindReadout.isVOD ? "Timeline" : "Live timeline")
        .accessibilityValue(rewindAccessibilityValue)
        .accessibilityHint("Swipe up or down to seek ten seconds")
        .accessibilityAdjustableAction { direction in
          guard !isScrubbing else { return }
          switch direction {
          case .increment: rewindStep(rewindStepSeconds)
          case .decrement: rewindStep(-rewindStepSeconds)
          @unknown default: break
          }
        }
        .onMoveCommand { direction in
          // Left/right step the timeline. Down drops to the control row (the bar
          // now sits *above* the buttons); up is left to the focus engine.
          switch direction {
          case .left:
            if !isScrubbing { rewindStep(-rewindStepSeconds) }
          case .right:
            if !isScrubbing { rewindStep(rewindStepSeconds) }
          case .down:
            activateControl(.quality)
          default:
            break
          }
        }
        .focusSection()
        .frame(maxWidth: .infinity)
      }

      HStack(alignment: .center, spacing: 24) {
        Button {
          presentChannelPage()
        } label: {
          HStack(spacing: 12) {
            Group {
              if let channelAvatarURL {
                CachedAsyncImage(url: channelAvatarURL) { image in
                  image
                    .resizable()
                    .scaledToFill()
                } placeholder: {
                  ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Icon(glyph: .userCircle, size: 44)
                      .foregroundStyle(.white.opacity(0.85))
                  }
                }
              } else {
                ZStack {
                  Circle().fill(.white.opacity(0.16))
                  Icon(glyph: .userCircle, size: 44)
                    .foregroundStyle(.white.opacity(0.85))
                }
              }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            // Tuck the avatar toward the pill's leading cap so the rounded-left
            // corner stays a crisp, near-equidistant inset around the circle.
            .padding(.leading, -6)

            Text(channelDisplayName.isEmpty ? activeChannel : channelDisplayName)
              .font(.headline)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .TwizzControlButtonStyle()
        .accessibilityLabel("Channel info")
        .accessibilityHint("Opens the channel page")
        // While the viewer is scrolling chat, lift every control-row button out
        // of the focus engine (the scrubber does the same via its
        // `scrubberFocusable` gate). Focus is held on the composer; without this
        // the engine treats these as neighbors and a left press jumps here —
        // flashing a focused button and an audible tick — before our trap reverts
        // it. We remove rather than `.focusable(false/true)`-toggle so the button
        // keeps its own native focus styling when it IS reachable. Exit via Back
        // or by scrolling to the live bottom, which re-enables the row.
        .focusRemoved(controlButtonRemoved(.streamInfo))
        .focused($focus, equals: .streamInfo)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
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
          selectedOption: selectedQualityOption,
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
          sourceAvailable: youtubeSourceAvailable,
          sourceOptions: streamSourceOptions,
          sourceSelectedIndex: selectedStreamSourceIndex,
          onSelectSource: { selectStreamSource(at: $0) },
          sleepOptions: sleepTimerOptionLabels,
          sleepSelectedIndex: sleepSelectionIndex,
          sleepIsArmed: sleepTimerIsArmed,
          onSelectSleep: { selectSleepTimer(at: $0) }
        )
        .equatable()
        .focusRemoved(controlButtonRemoved(.quality))
        .focused($focus, equals: .quality)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
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
          .focusRemoved(controlButtonRemoved(.quality))
          .focused($focus, equals: .quality)
          .onMoveCommand { direction in
            if direction == .up { requestSeekBarFocus() }
          }
        }

        Button {
          openChatSettingsFromControlBar()
        } label: {
          Icon(glyph: showChatSettings ? .x : .adjustmentsHorizontal)
            .accessibilityLabel("Chat Settings")
        }
        .focusRemoved(controlButtonRemoved(.chatSettingsButton))
        .focused($focus, equals: .chatSettingsButton)
        .onMoveCommand { direction in
          if direction == .up { requestSeekBarFocus() }
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
        .focusRemoved(controlButtonRemoved(.chatToggle))
        .focused($focus, equals: .chatToggle)
        .onMoveCommand { direction in
          switch direction {
          case .right:
            stepToChatInput(from: .chatToggle)
          case .up:
            requestSeekBarFocus()
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
    // Direct the row's initial focus when the chrome is revealed. Because the
    // row is rebuilt on each reveal, this is what actually makes a reveal land
    // on the intended button (set via `pendingControlFocus`) instead of tvOS
    // auto-picking the leftmost control. Dormant when focus is sent into chat.
    .defaultFocus($focus, pendingControlFocus)
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

    let mode: String
    if lowLatencyProxyEnabled {
      mode = isStreamUnstable ? "LL proxy auto-off (unstable)" : "LL proxy ON"
    } else {
      mode = "LL proxy off"
    }
    let pin = preferredQuality == "Auto" ? "Auto/adaptive" : "\(preferredQuality) (pinned)"
    lines.append("Mode: \(mode) · \(pin)")

    // Stream source readout (moved here from the settings panel). When the
    // YouTube simulcast is active, surface the detailed alt-source proof
    // (real asset host + frame-decode status) so it's visible on the overlay.
    if isUsingAltSource {
      lines.append("Source: YouTube simulcast")
      if let altSourceStatus {
        lines.append("  \(altSourceStatus)")
      }
    } else {
      let avail = youtubeSourceAvailable ? " (YouTube available)" : ""
      lines.append("Source: Twitch\(avail)")
    }
    if isStreamUnstable {
      let trigger = streamUnstableWasPredicted ? "predictive" : "observed"
      lines.append(
        "⚠︎ STABILITY MODE [\(trigger)] (proxy off, deep buffer, riding behind edge)")
    }
    // Surface the predictive instability score whenever the proxy is engaged —
    // both before a trip (watch it climb) and after (the score it had reached when
    // it tripped, so a near-miss "observed" trip is still visible for tuning).
    if lowLatencyProxyEnabled, !isVOD {
      let snap = lowLatencyProxy.instabilityDiagnostics
      if snap.refreshes > 0 {
        var line =
          "Predict: score \(diagFormat(snap.score, decimals: 1))"
          + "/\(diagFormat(LowLatencyHLSProxy.predictedUnstableScoreThreshold, decimals: 1))"
          + " · \(snap.refreshes) refresh\(snap.refreshes == 1 ? "" : "es")"
        if !snap.detail.isEmpty { line += " · \(snap.detail)" }
        lines.append(line)
      }
    }

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
    if diagIsFrozen || videoDecodeFrozenSince != nil {
      let since = [diagFrozenSince, videoDecodeFrozenSince].compactMap { $0 }.min()
      let frozenFor =
        since.map { max(0, Int(Date().timeIntervalSince($0).rounded())) } ?? 0
      let kind = videoDecodeFrozenSince != nil ? "FROZEN video" : "FROZEN"
      lines.append("State: \(kind) (\(frozenFor)s) · Waiting: \(diagWaitingReasonDescription())")
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
    // While actively scrolling, the chat list traps focus on the composer
    // (see the `isChatScrolling` focus guard in the body's onChange(of: focus)).
    // A left press here would briefly fling focus to the collapse button —
    // playing a focus tick and flashing the chrome — before the trap snaps it
    // back. Swallow it: the only ways out of an active scroll are Back (Menu)
    // or scrolling down to the live bottom, which returns focus to the composer.
    if isChatScrolling { return }
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

  // FOCUS CONTRACT (tvOS focus here is managed explicitly, not automatically):
  // Every focusable control in the player/chat-settings panel must
  //   (1) have a unique `Focusable` case,
  //   (2) pass it as the control's `focusTag`, and
  //   (3) be registered in this allow-list.
  // A control missing from this switch is unreachable — the focus engine cannot
  // land on it and traps focus on the nearest registered neighbor. When you add
  // a new settings pill, update ALL THREE places (enum case, focusTag, here).
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
      .chatAltSourceToggle,
      .chatRewindToggle,
      .chatViewerCountToggle,
      .chatLatencyToggle,
      .chatDiagnosticsToggle,
      .chatCaptionsButton,
      .chatCaptionsToggle,
      .chatCaptionsBackgroundOption,
      .chatCaptionsColorOption,
      .chatCaptionsOutlineToggle,
      .chatEventsButton,
      .chatRaidEventToggle,
      .chatHypeTrainEventToggle,
      .chatPollEventToggle,
      .chatPredictionEventToggle,
      .chatGoalEventToggle,
      .simulateRaidButton,
      .simulateIncomingRaidButton,
      .simulateOfflineButton,
      .simulateMomentButton,
      .simulateGoLiveButton,
      .youtubeMergeToggle,
      .youtubeMergeURL,
      .kickMergeToggle,
      .kickMergeURL,
      .chatAdvancedBack,
      .chatStepperDec,
      .chatStepperInc,
      .chatEmoteAutoToggle,
      .chatAnimatedToggle,
      .chatFontOption,
      .chatBadgesToggle,
      .chatPlatformBadgesToggle,
      .chatHighlightToggle,
      .chatHighlightKeywords,
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
        frozenMessages: chatFrozenMessages,
        textSize: chatTextSize,
        emoteSize: chatEmoteSize,
        messageSpacing: chatMessageSpacing,
        lineHeight: chatLineHeight,
        letterSpacing: chatLetterSpacing,
        animatedEmotes: chatAnimatedEmotes,
        fontStyle: chatFontStyle,
        showBadges: chatShowBadges,
        showPlatformBadges: chatShowPlatformBadges,
        highlightEnabled: chatHighlightMentionsEnabled,
        viewerLogin: auth.userLogin,
        viewerDisplayName: auth.userDisplayName,
        highlightKeywords: chatHighlightKeywordList,
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
        if let moment = hermes.currentMoment, !isSleeping, isEventEnabled(moment) {
          dockedInteractiveMoment(moment, style: momentDockStyle(isGlass: isGlass))
            .transition(.motionAware(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
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
  /// Bottom inset for the control cluster. Lifts the row 16pt off the very bottom
  /// edge, and in floating Glass chat mode adds the pane's edge inset so the
  /// buttons line up with the floating chat's bottom margin.
  var controlsBottomPadding: CGFloat {
    let glassLift = (chatLayoutMode == .glass && showChat) ? GlassChatPaneStyle.edgeInset : 0
    return 24 + glassLift
  }
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
                  : palette.chromeOnOpaque.opacity(chatDraft.isEmpty ? 0.5 : 1.0)
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
          .disabled(chatInputFocusBlocked())
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
            .TwizzControlButtonStyle(shape: .circle)
            .frame(width: chatComposerRowHeight, height: chatComposerRowHeight)
            // `.disabled` also doubles as the rewind-bar focus gate; see the
            // composer button above for why we avoid `.focusable` on a Button.
            .disabled(isSendingChat || chatInputFocusBlocked())
            .accessibilityLabel("Send message")
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
                : palette.chromeOnOpaque.opacity(0.45)
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
        .disabled(chatInputFocusBlocked())
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
    // Lift the composer off the pane's bottom edge: the base 16pt even inset plus
    // an extra 16pt of breathing room so it doesn't crowd the bottom of the page.
    .padding(.bottom, 32)
    .background(
      // In Glass mode the composer shares the chat message list's exact wash
      // (`chromeGlassTint(0.22)`) over the pane's glass, so "Send a message" reads
      // as the same surface as the chat above it instead of a distinct lighter
      // band. Overlay/side modes keep their own opaque, theme-aware fills.
      chatLayoutMode == .glass
        ? AnyShapeStyle(palette.chromeGlassTint(0.22))
        : (palette.isLight
          ? (chatLayoutMode == .overlay
            ? AnyShapeStyle(Color(white: 0.97).opacity(0.92))
            : AnyShapeStyle(Color(white: 0.99).opacity(0.96)))
          : (chatLayoutMode == .overlay
            ? AnyShapeStyle(Color(white: 0.13).opacity(0.90))
            : AnyShapeStyle(palette.chatSideSurface)))
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

  /// Placeholder/value shown in the highlight-keywords settings field.
  var highlightKeywordsDisplayText: String {
    let trimmed = chatHighlightKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Add keywords (optional)" : trimmed
  }

  /// The effective YouTube merge target shown in the settings input: the manual
  /// entry when present, otherwise the resolved default handle for the channel.
  var youtubeMergeDisplayText: String {    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(
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

  // MARK: - Experimental Kick merge

  /// Placeholder/value shown in the Kick merge settings input: the manual entry
  /// when present, otherwise the resolved default slug for the channel.
  var kickMergeDisplayText: String {
    let manual = experimentalKickMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    return kickMergeDefaultTarget.isEmpty
      ? "Kick handle or channel URL" : kickMergeDefaultTarget
  }

  /// The slug the merge falls back to when no manual value is entered. Prefers
  /// the Kick channel discovered from the Twitch channel's social links /
  /// description, and only guesses `<twitch-login>` when nothing better exists.
  var kickMergeDefaultTarget: String {
    let auto = kickAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if !auto.isEmpty { return auto }
    let base = activeChannel.isEmpty ? channel : activeChannel
    return base.isEmpty ? "" : base
  }

  func applyExperimentalKickSettings() {
    let manual = experimentalKickMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTarget = manual.isEmpty ? kickMergeDefaultTarget : manual

    chat.configureExperimentalKickMerge(
      enabled: experimentalKickMergeEnabled,
      channelOrURL: resolvedTarget
    )
  }

  /// Resolves the best Kick target for the active channel and pushes it to the
  /// chat service. Runs whenever the active channel changes.
  func refreshKickAutoTarget() async {
    let login = activeChannel
    guard !login.isEmpty else { return }
    await kickAliases.refreshIfNeeded()
    let alias = kickAliases.kickSlug(forTwitchLogin: login)
    let resolved = await Self.resolveKickTarget(forTwitchLogin: login, aliasSlug: alias)
    guard login == activeChannel else { return }
    kickAutoResolvedTarget = resolved
    applyExperimentalKickSettings()
  }

  /// Makes an educated guess at a channel's Kick source from its Twitch profile.
  ///
  /// Twitch surfaces YouTube links but routinely strips Kick (competitor) links,
  /// so we can't rely on an explicit Kick link being present. Instead we gather
  /// candidate slugs — an explicit Kick link if any, then the streamer's
  /// *consensus* handle reused across their other socials + display name, then
  /// the Twitch login — and verify each against Kick's channel API, preferring a
  /// channel that actually exists (and is live) over a blind login guess. This
  /// is what lets e.g. Twitch `zackrawrr` resolve to Kick `asmongold`.
  static func resolveKickTarget(forTwitchLogin login: String, aliasSlug: String?) async -> String {
    let fallback = login

    // A curated/CI-validated alias is authoritative for streamers whose Kick
    // name shares nothing with their Twitch identity (e.g. zackrawrr ->
    // asmongold), which profile-based guessing can't derive. Use it whenever the
    // aliased channel still exists.
    if let aliasSlug, !aliasSlug.isEmpty {
      if let info = try? await ChatService.fetchKickChannelInfo(slug: aliasSlug) {
        return info.slug
      }
    }

    guard let profile = await ChannelProfileService.fetch(login: login) else {
      return fallback
    }

    var candidates = kickSlugCandidates(
      login: login,
      displayName: profile.displayName,
      socialLinks: profile.socialLinks,
      description: profile.description
    )

    // Broaden coverage for streamers who neither reuse their name nor link Kick:
    // ask Kick's own search for their display name and login, folding in any
    // matches to be verified below.
    for term in [profile.displayName, login] {
      for slug in await ChatService.searchKickChannels(term: term) where !candidates.contains(slug) {
        candidates.append(slug)
      }
    }

    var firstExisting: String?
    for slug in candidates {
      let info: ChatService.KickChannelInfo?
      do {
        info = try await ChatService.fetchKickChannelInfo(slug: slug)
      } catch {
        continue
      }
      guard let info else { continue }
      if info.isLive { return info.slug }
      if firstExisting == nil { firstExisting = info.slug }
    }
    return firstExisting ?? fallback
  }

  /// Builds an ordered, de-duplicated list of Kick slug guesses for a streamer,
  /// strongest first: an explicit Kick link, then the handle they reuse most
  /// across their other social links and display name, then their Twitch login.
  static func kickSlugCandidates(
    login: String,
    displayName: String,
    socialLinks: [ChannelSocialLink],
    description: String?
  ) -> [String] {
    var ordered: [String] = []
    func add(_ raw: String?) {
      guard let raw else { return }
      let slug = normalizeKickSlug(raw)
      guard slug.count >= 2, !ordered.contains(slug) else { return }
      ordered.append(slug)
    }

    // 1. An explicit Kick link (profile panel or bio) is the strongest signal.
    if let kickURL = bestKickChannelURL(
      among: socialLinks, twitchLogin: login, displayName: displayName)
      ?? firstKickChannelURL(in: description ?? ""),
      let handle = kickHandle(from: kickURL)
    {
      add(handle)
    }

    // 2. Consensus handle: the brand name reused across the streamer's socials.
    var counts: [String: Int] = [:]
    var seen: [String] = []
    func tally(_ raw: String?) {
      guard let raw else { return }
      let key = normalizeKickSlug(raw)
      guard key.count >= 2 else { return }
      if counts[key] == nil { seen.append(key) }
      counts[key, default: 0] += 1
    }
    for link in socialLinks { tally(socialHandle(from: link.url)) }
    tally(displayName)
    for key in seen.sorted(by: { (counts[$0] ?? 0) > (counts[$1] ?? 0) }) { add(key) }

    // 3. The Twitch login as a final fall-back.
    add(login)

    return ordered
  }

  /// Extracts a likely account handle from an arbitrary social URL (X, YouTube,
  /// Instagram, TikTok, …) so it can be compared across platforms.
  static func socialHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    let parts = comps.path.split(separator: "/").map(String.init)
    if let at = parts.first(where: { $0.hasPrefix("@") }) {
      return String(at.dropFirst())
    }
    let skip: Set<String> = ["channel", "c", "user", "invite", "intent", "watch", "playlist"]
    guard let first = parts.first else { return nil }
    if skip.contains(first.lowercased()), parts.count >= 2 { return parts[1] }
    return first
  }

  /// Lowercases and keeps only characters valid in a Kick slug.
  static func normalizeKickSlug(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
    return String(raw.lowercased().filter { allowed.contains($0) })
  }

  /// Picks the Kick channel link most likely to be the streamer's primary live
  /// channel. Returns nil when no candidate looks confident enough, so the
  /// caller can fall back rather than merge with the wrong channel.
  static func bestKickChannelURL(
    among links: [ChannelSocialLink],
    twitchLogin: String,
    displayName: String
  ) -> String? {
    let candidates = links.filter { isKickChannelURL($0.url) }
    guard !candidates.isEmpty else { return nil }

    let loginKey = normalizeIdentity(twitchLogin)
    let nameKey = normalizeIdentity(displayName)
    let secondaryMarkers = [
      "clip", "clips", "vod", "vods", "archive", "replay", "replays",
      "highlight", "highlights", "fan", "second",
    ]

    func score(_ link: ChannelSocialLink) -> Int {
      var score = 0
      let handle = normalizeIdentity(kickHandle(from: link.url) ?? "")
      let label = link.title.lowercased()
      let haystack = "\(label) \(handle)"

      if !handle.isEmpty {
        if handle == loginKey || (!nameKey.isEmpty && handle == nameKey) {
          score += 100
        } else if !loginKey.isEmpty, handle.contains(loginKey) {
          score += 60
        } else if nameKey.count >= 3, handle.contains(nameKey) {
          score += 50
        }
      }

      if ["kick", "kick channel", "main", "main channel", "live"].contains(label) {
        score += 20
      }
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

  /// True for URLs that point at a Kick channel, e.g. `kick.com/<slug>`.
  static func isKickChannelURL(_ string: String) -> Bool {
    let lower = string.lowercased()
    guard lower.contains("kick.com") else { return false }
    let normalized = lower.contains("://") ? lower : "https://\(lower)"
    guard let comps = URLComponents(string: normalized) else { return false }
    return !comps.path.split(separator: "/").isEmpty
  }

  /// Extracts the channel slug from a Kick channel URL.
  static func kickHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    return comps.path.split(separator: "/").map(String.init).first
  }

  static func firstKickChannelURL(in text: String) -> String? {
    let separators = CharacterSet(charactersIn: " \n\t\r,;|()<>[]\"'")
    for raw in text.components(separatedBy: separators) {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, isKickChannelURL(token) else { continue }
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

/// Shape of an opaque player-control pill in the glass-disabled path.
enum TwizzControlShape: Equatable {
  case capsule
  case circle
}

extension View {
  @ViewBuilder
  fileprivate func TwizzControlButtonStyle(shape: TwizzControlShape = .capsule) -> some View {
    modifier(TwizzControlButtonStyleModifier(shape: shape))
  }

  /// Removes the view from the focus engine while `removed` is true, leaving it
  /// completely untouched otherwise. Used to lift the control row out of focus
  /// while the viewer scrolls chat. Unlike an always-on `.focusable(true)` this
  /// doesn't suppress a Button's own focus styling (which reads the environment
  /// `isFocused` / the system focus effect), and unlike `.disabled` it never
  /// dims the native-glass buttons.
  @ViewBuilder
  fileprivate func focusRemoved(_ removed: Bool) -> some View {
    if removed {
      self.focusable(false)
    } else {
      self
    }
  }

  /// Native Liquid Glass for the compact chat-settings controls: the exact same
  /// `.glass` / `.glassProminent` button styles the app's main SettingsView
  /// uses, so these pills/rows look and focus identically to the rest of the
  /// app (and to the playback controls on the player bar) instead of a custom
  /// imitation. Selected options render prominent; everything else is plain
  /// glass. Falls back to bordered styles before tvOS 26.
  @ViewBuilder
  func chatSettingsGlassButton(isSelected: Bool = false, shape: TwizzControlShape = .capsule) -> some View {
    modifier(ChatSettingsGlassButtonModifier(isSelected: isSelected, shape: shape))
  }
}

/// Chat-settings popover pills: native Liquid Glass when glass is enabled, or a
/// theme-aware opaque pill when glass is disabled — so the popover stays legible
/// and on-theme (light pills + dark text in Light mode) once its surface goes
/// opaque, matching the player's control pills.
private struct ChatSettingsGlassButtonModifier: ViewModifier {
  var isSelected: Bool
  var shape: TwizzControlShape
  @Environment(\.glassDisabled) private var glassDisabled

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .buttonStyle(TwizzOpaquePillButtonStyle(isSelected: isSelected, shape: shape))
        .focusEffectDisabled()
    } else if #available(tvOS 26.0, *) {
      if isSelected {
        // Active state mirrors the main SettingsView pills: native prominent
        // glass plus a trailing checkmark (added by the caller). No tint — the
        // prominent fill + checkmark is the established app pattern.
        content.buttonStyle(.glassProminent)
      } else {
        content.buttonStyle(.glass)
      }
    } else {
      if isSelected {
        content.buttonStyle(.borderedProminent)
      } else {
        content.buttonStyle(.bordered)
      }
    }
  }
}

/// Opaque, theme-aware pill for the chat-settings popover. Like the control-pill
/// style it flips to the standard tvOS focused look (white fill + dark label),
/// and marks the selected option with a prominent brand fill + light label
/// (the caller still adds the trailing checkmark) so selection reads in both
/// light and dark themes.
private struct TwizzOpaquePillButtonStyle: ButtonStyle {
  var isSelected: Bool
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, isSelected: isSelected, shape: shape)
  }

  private struct PillBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    private var fill: Color {
      if isFocused { return .white }
      if isSelected { return ThemePalette.brandPurple }
      return palette.chromeOpaqueSurface
    }
    private var foreground: Color {
      if isFocused { return .black }
      if isSelected { return .white }
      return palette.chromeOnOpaque
    }
    private var border: Color {
      (isFocused || isSelected) ? .clear : palette.chromeOpaqueBorder
    }

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(foreground)
        .padding(.horizontal, isCircle ? 12 : 22)
        .padding(.vertical, isCircle ? 12 : 14)
        .background(fill, in: s)
        .overlay(s.strokeBorder(border, lineWidth: 1))
        .clipShape(s)
    }
  }
}

/// Player control buttons: native Liquid Glass when glass is enabled, or a
/// theme-aware opaque pill when glass is disabled (OS Reduce Transparency or the
/// in-app Disable Liquid Glass toggle). The opaque pill mirrors the card/chrome
/// surfaces — an opaque themed fill with a contrasting foreground (light fill +
/// dark glyph in Light theme, near-black + light glyph in dark/oled) — and
/// follows the tvOS focus convention of a bright white fill + dark glyph when
/// focused. The native glass path is left untouched when glass is enabled.
private struct TwizzControlButtonStyleModifier: ViewModifier {
  var shape: TwizzControlShape
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .buttonStyle(TwizzOpaqueControlButtonStyle(shape: shape))
        // We draw our own focus treatment (white fill + lift), so suppress the
        // system focus effect that would otherwise layer on top of a custom
        // button style.
        .focusEffectDisabled()
    } else if #available(tvOS 26.0, *) {
      if palette.isLight {
        // Native `.buttonStyle(.glass)` samples the dark video and renders dark,
        // which fights the Light theme. Swap in a light frosted-glass pill (a
        // light wash under real `.glassEffect`) that mirrors the native focus
        // behavior. Dark/OLED keep the untouched native glass below.
        content
          .buttonStyle(TwizzLightGlassControlButtonStyle(shape: shape))
          .focusEffectDisabled()
      } else {
        content.buttonStyle(.glass)
      }
    } else {
      content.buttonStyle(.automatic)
    }
  }
}

/// Opaque, theme-aware control pill used when glass is disabled. Reads the
/// button's own focus state via `@Environment(\.isFocused)` (valid inside a
/// button style's body) so it can flip to the standard tvOS focused look —
/// bright white fill + dark glyph, scaled and shadowed — while the resting state
/// stays an opaque themed surface with the theme's on-opaque foreground.
private struct TwizzOpaqueControlButtonStyle: ButtonStyle {
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    OpaqueControlButtonBody(configuration: configuration, shape: shape)
  }

  private struct OpaqueControlButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    private var fill: Color { isFocused ? .white : palette.chromeOpaqueSurface }
    private var foreground: Color { isFocused ? .black : palette.chromeOnOpaque }
    private var border: Color { isFocused ? .clear : palette.chromeOpaqueBorder }

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(foreground)
        .padding(.horizontal, isCircle ? 10 : 22)
        .padding(.vertical, isCircle ? 10 : 14)
        .background(fill, in: s)
        .overlay(s.strokeBorder(border, lineWidth: 1))
        .clipShape(s)
    }
  }
}

/// Light-theme control pill for the *glass-enabled* path. Native
/// `.buttonStyle(.glass)` samples the dark video frame underneath and renders
/// dark, which clashes with the Light theme's light chrome. This paints the exact
/// same material as the Glass chat pane — a light `chromeGlassTint` wash under a
/// real, refractive `.glassEffect(.regular)` (brightening to white on focus) —
/// while keeping the native focus lift (scale + shadow). Used only for the
/// `.light` palette; dark/OLED keep the untouched native glass. Like the opaque
/// style it reads the button's own focus state via `@Environment(\.isFocused)`.
@available(tvOS 26.0, *)
private struct TwizzLightGlassControlButtonStyle: ButtonStyle {
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    LightGlassControlButtonBody(configuration: configuration, shape: shape)
  }

  private struct LightGlassControlButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(isFocused ? .black : palette.chromeOnOpaque)
        .padding(.horizontal, isCircle ? 10 : 22)
        .padding(.vertical, isCircle ? 10 : 14)
        // Same translucent material as the Glass chat pane, but with the
        // stronger over-video wash so the pill reads as light as the chat even
        // though only dark video (not light chat content) sits behind it.
        .background(palette.chromeOverVideoTint(), in: s)
        .glassEffect(isFocused ? .regular.tint(.white) : .regular, in: s)
        .overlay(s.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.12), lineWidth: 1))
        .clipShape(s)
    }
  }
}
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
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(palette.chromeOpaqueSurface), in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder.opacity(isFocused ? 0.0 : 1.0), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    } else if #available(tvOS 26.0, *) {
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
  /// When non-nil, the viewer is paused/scrolling: render this fixed snapshot
  /// instead of the live buffer so the list can't shift under them. While nil,
  /// `visibleMessages` reads the live buffer inside this wrapper's own body (the
  /// reason this view exists) so PlayerView's body isn't re-run per message.
  var frozenMessages: [ChatMessage]? = nil
  let textSize: CGFloat
  let emoteSize: CGFloat
  let messageSpacing: CGFloat
  let lineHeight: CGFloat
  let letterSpacing: CGFloat
  let animatedEmotes: Bool
  let fontStyle: ChatFontStyle
  let showBadges: Bool
  let showPlatformBadges: Bool
  /// Highlight (mention) inputs, passed straight through to `ChatView`.
  var highlightEnabled: Bool = true
  var viewerLogin: String? = nil
  var viewerDisplayName: String? = nil
  var highlightKeywords: [String] = []
  let useGlassBackground: Bool
  let useLighterOverlayBackground: Bool
  let autoScroll: Bool
  let softPauseRemaining: Int?
  let softPauseTotal: Int
  let scrollTarget: ChatScrollTarget?

  private var visibleMessages: [ChatMessage] {
    if let frozenMessages { return frozenMessages }
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
      showPlatformBadges: showPlatformBadges,
      highlightEnabled: highlightEnabled,
      viewerLogin: viewerLogin,
      viewerDisplayName: viewerDisplayName,
      highlightKeywords: highlightKeywords,
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
  // Stream source, nested as a submenu (Twitch / YouTube simulcast). Only shown
  // when the channel actually has a resolvable YouTube simulcast.
  let sourceAvailable: Bool
  let sourceOptions: [String]
  let sourceSelectedIndex: Int
  let onSelectSource: (Int) -> Void
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
      && lhs.sourceAvailable == rhs.sourceAvailable
      && lhs.sourceOptions == rhs.sourceOptions
      && lhs.sourceSelectedIndex == rhs.sourceSelectedIndex
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

  private var sourceSelection: Binding<Int> {
    Binding(
      get: { sourceSelectedIndex },
      set: { onSelectSource($0) }
    )
  }

  /// Submenu row label for the nested Quality picker, e.g. "Quality · Auto
  /// (1080p60)", so the current rendition is visible without drilling in.
  private var qualityMenuLabel: String {
    "Quality · \(buttonLabel)"
  }

  /// Submenu row label for the nested Stream Source picker, e.g.
  /// "Source · YouTube".
  private var sourceMenuLabel: String {
    guard sourceOptions.indices.contains(sourceSelectedIndex) else { return "Source" }
    return "Source · \(sourceOptions[sourceSelectedIndex])"
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
        // NOTE (tvOS 27 dev-beta regression, build 24J5289o): on a focused
        // submenu row the white focus pill correctly inverts the row's text and
        // leading icon to dark, but the *system* trailing disclosure chevron does
        // NOT invert — it stays white and disappears on the white pill. Verified
        // fine on the tvOS 26.5 simulator with identical code, so this is an OS
        // bug, not ours. There is no public API to recolor/hide that specific
        // chevron (`.menuIndicator(.hidden)` doesn't affect the nested-submenu
        // indicator, and a hand-drawn chevron just doubles up with the system
        // one). Left as-is intentionally — do not add custom chevrons or color
        // overrides to "fix" it; revisit when the tvOS 27 GA ships.
        //
        // Quality is a nested submenu alongside Stream Source and Sleep timer.
        // The lifecycle hooks live on this submenu's row (a direct child of the
        // top-level menu) so they fire on the top menu's open/close, not when
        // drilling into a sibling submenu.
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
        } label: {
          Label(qualityMenuLabel, systemImage: "rectangle.on.rectangle")
        }
        .onAppear(perform: onMenuPresented)
        .onDisappear(perform: onMenuDismissed)

        // Stream Source: swap the live video between Twitch and the streamer's
        // YouTube simulcast (lower latency). Only offered when a YouTube
        // simulcast actually resolved for this channel.
        if sourceAvailable {
          Menu {
            Picker("Source", selection: sourceSelection) {
              ForEach(Array(sourceOptions.enumerated()), id: \.element) { index, option in
                Text(option).tag(index)
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label(sourceMenuLabel, systemImage: "dot.radiowaves.left.and.right")
          }
        }

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
    // Match the sibling control buttons' height. Those (chat settings, chat
    // toggle) wrap a 40pt `Icon.controlButtonSize` glyph, so reserve that same
    // content height for the quality label. Without it the much shorter text
    // line (even at regular `.subheadline`, and more so the compact "Auto
    // (1080p60)" form) makes this button's platter sit a few px shorter than its
    // neighbors. `minHeight` only affects height, so the variable width is
    // untouched.
    .frame(minHeight: Icon.controlButtonSize)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if reduceMotion {
        // Reduce Motion: step the countdown once a second (no smooth 60fps
        // progress fill) and drop the animated bar.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          indicator(now: context.date)
        }
      } else {
        TimelineView(.animation) { context in
          indicator(now: context.date)
        }
      }
    }
  }

  private func indicator(now: Date) -> some View {
    let remaining = max(0, deadline.timeIntervalSince(now))
    let progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 1
    return HStack(spacing: 10) {
      Icon(glyph: .clock, size: 16)
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(
          remaining > 0.5
            ? "Sent — appears in \(Int(remaining.rounded()))s"
            : "Appearing now…"
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.82))
        if !reduceMotion {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(.purple)
            .accessibilityHidden(true)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// Styles the chat pane as a floating, rounded Liquid Glass panel when enabled,
/// otherwise leaves it as a full-height docked panel.
private struct GlassChatPaneStyle: ViewModifier {
  let enabled: Bool
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

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
    if glassDisabled {
      content
        .frame(maxHeight: .infinity)
        .background(palette.chromeOpaqueSurface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
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
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 40, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(palette.chromeOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
      content
        // Same darkening scrim the Glass chat pane paints over its glass
        // (ChatView uses Color.black.opacity(0.22)); without it the panel's bare
        // glass read noticeably lighter than the chat beside it. Flips to a white
        // scrim in the Light theme so it lightens rather than darkens the glass.
        .background(palette.chromeGlassTint(0.22), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(palette.chromeGlassTint(0.22), in: shape)
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
  /// Consecutive samples deviating from the smoothed value by an outlier margin,
  /// used to hold back a transient latency spike until it is corroborated.
  var latencyOutlierStreak = 0
  var isPlaybackActive = false
  var didRequestPlayback = false
  var edgeLatencyLowConfidenceStreak = 0
  var wallClockLowConfidenceStreak = 0
  var lastPlaybackDateSample: Date?
  var lastPlaybackTimeSampleSeconds: Double?
  var lastObservedPlaybackTimeSeconds: Double?
  var stalledPlaybackSamples = 0
  var isRecoveringPlayback = false
  var lastRecoveryAttemptAt = Date.distantPast
  /// Throttle + escalation state for the lightweight live-edge resync that pulls
  /// the playhead back when AVPlayer involuntarily drifts far behind live (the
  /// "rewound 120s and never recovered" failure). Escalates to a full reload only
  /// after repeated resyncs fail to stick.
  var lastLiveResyncAt = Date.distantPast
  var liveResyncAttempts = 0
  /// Throttles the snap-to-true-live reload that fires when the viewer returns to
  /// the live edge atop a stale seekable window.
  var lastLiveEdgeSnapAt = Date.distantPast
  /// When the player first entered a sustained "waiting with a starved buffer"
  /// state. Drives the authoritative end-of-stream (offline) probe.
  var liveStallWaitingSince: Date?
  /// Highest live seekable-edge position seen, and when it stopped advancing.
  /// An ended broadcast freezes the edge, which is a cleaner end-of-stream signal
  /// than the waiting/stall state the anti-stall slow-down keeps flickering.
  var lastLiveEdgeSeconds: Double?
  var liveEdgeFrozenSince: Date?
  /// Guards against overlapping offline probes and rate-limits them.
  var offlineProbeInFlight = false
  var lastOfflineProbeAt = Date.distantPast
  /// Timestamps of recent counted stalls, pruned to a rolling window, used to
  /// detect a chronically-unstable stream (a struggling broadcaster encoder).
  var recentInstabilityEvents: [Date] = []
  /// Set when the stream-stability watchdog has switched into deep-buffer
  /// stability mode; `nil` while the stream is behaving. Latched (sticky) for the
  /// rest of the channel session.
  var streamUnstableSince: Date?
  /// When the most recent stall/jump was counted.
  var lastStallAt: Date?
  /// Set when the stability trip came from the proxy's predictive (manifest)
  /// signal rather than from observed stalls/jumps. Drives the overlay readout.
  var streamUnstableWasPredicted = false
  /// When playback first started advancing for this stream session, used to apply
  /// a more sensitive (single-event) instability trip during the opening seconds.
  var streamPlaybackStartedAt: Date?
  /// Soft-stall deadlock state: when AVPlayer first parked in "waiting despite a
  /// healthy buffer", and when we last issued a play nudge to break it.
  var softStallSince: Date?
  var lastSoftStallNudgeAt = Date.distantPast
  /// When we last nudged a buffer-agnostic frozen playhead (the `toMinimizeStalls`
  /// deadlock that satisfies neither the hard- nor soft-stall buffer signatures).
  var lastFrozenPlayheadNudgeAt = Date.distantPast
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

/// Top-left player header: the stream title in a large, left-aligned style with a
/// theme-respecting scrim behind it (applied by the caller), plus a plain
/// text + icon subheader holding the live viewer count and/or latency readout.
/// Reads `hermes.viewerCount` and `latency` here (not in the player body) so this
/// leaf re-renders in isolation as those values tick.
private struct PlayerTitleHeader: View {
  let title: String
  @Bindable var latency: LatencyReadout
  let hermes: HermesEventService
  /// Whether the viewer/latency subheader may appear at all (live only).
  let showSubheader: Bool
  let showLatency: Bool
  let showViewerCount: Bool

  /// Title/subheader foreground. The header sits on the always-dark top scrim
  /// (matching the bottom scrim), so white reads in every theme.
  private var foreground: Color { .white }

  /// Brick red from the requested reference, kept legible over the scrim.
  private static let viewerTint = Color(red: 0.86, green: 0.26, blue: 0.22)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.title3.weight(.bold))
        .foregroundStyle(foreground)
        .lineLimit(2)
        .minimumScaleFactor(0.6)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

      if showSubheader {
        let viewers = showViewerCount ? hermes.viewerCount : nil
        if viewers != nil || showLatency {
          HStack(spacing: 16) {
            if let viewers {
              HStack(spacing: 8) {
                Icon(glyph: .user, size: 24)
                  .foregroundStyle(Self.viewerTint)
                Text(viewers.formatted(.number))
                  .font(.footnote)
                  .fontWeight(.semibold)
                  .foregroundStyle(foreground)
                  .monospacedDigit()
                  .contentTransition(.numericText())
              }
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(viewers.formatted(.number)) watching")
            }

            if showLatency {
              HStack(spacing: 8) {
                Circle()
                  .fill(latency.color)
                  .frame(width: 8, height: 8)
                Text(latency.label)
                  .font(.caption)
                  .fontWeight(.semibold)
                  .foregroundStyle(foreground)
              }
            }
          }
          .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
          .animation(.easeInOut(duration: 0.25), value: viewers)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Shared frosted Liquid-Glass treatment for the player's small passive HUD chips
/// (viewer/latency readout, sleep countdown). Matches the interactive-moment
/// banner, chat pane, and settings panel: a real `.glassEffect(.regular)` over a
/// subtle black scrim on tvOS 26+, with an `.ultraThinMaterial` fallback, plus
/// the standard white hairline. Keeps every chip reading at the same darkness
/// instead of the lighter bare-material look they had before.
private struct HUDChipGlassStyle: ViewModifier {
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette
  func body(content: Content) -> some View {
    let shape = Capsule(style: .continuous)
    if glassDisabled {
      content
        .background(palette.chromeOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
        .clipShape(shape)
    } else if #available(tvOS 26.0, *) {
      content
        .background(palette.chromeOverVideoTint(), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(palette.chromeOverVideoTint(), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
    }
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
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  /// Foreground for the track/orb/label. The bar is now chrome-less and floats
  /// directly on the player's (always-dark) bottom scrim, so white reads in every
  /// theme.
  private var chromeForeground: Color {
    .white
  }

  private func behindLabel() -> String {
    if readout.isVOD {
      return "\(Self.clock(readout.elapsedSeconds)) / \(Self.clock(readout.totalSeconds))"
    }
    if readout.isAtLiveEdge { return "LIVE" }
    let total = Int(readout.behindLiveSeconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "-%d:%02d:%02d", h, m, s) }
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
    let trackHeight: CGFloat = 6
    let orbSize: CGFloat = isFocused ? 30 : 16
    let fillColor = (readout.isAtLiveEdge && !readout.isVOD) ? Color.red : chromeForeground

    return HStack(spacing: 18) {
      GeometryReader { geo in
        let width = geo.size.width
        let x = max(0, min(width, width * readout.positionFraction))
        ZStack(alignment: .leading) {
          // Full track (retained window).
          Capsule()
            .fill(chromeForeground.opacity(0.20))
            .frame(height: trackHeight)
          // Played / behind-to-live portion.
          Capsule()
            .fill(fillColor)
            .frame(width: x, height: trackHeight)
          // Seek orb — the focus target. Grows and glows when focused.
          ZStack {
            Circle()
              .fill(chromeForeground)
              .frame(width: orbSize, height: orbSize)
              .shadow(
                color: .white.opacity(isFocused ? 0.7 : 0.0),
                radius: isFocused ? 10 : 0)
              .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            if readout.isPaused, isFocused {
              Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(glassDisabled ? palette.chromeOpaqueSurface : .black)
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
          .foregroundStyle(chromeForeground)
          .monospacedDigit()
      }
      .frame(minWidth: 72, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
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
      // A new finger-down during the coast means the viewer is continuing to
      // scrub. Cancel the momentum tail and pick the live swipe back up
      // immediately rather than swallowing it until the coast decays — that
      // dropped-second-swipe is what felt unresponsive.
      if sample.touching {
        phase = .tracking
        lastX = sample.x
        velocity = 0
        break
      }
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
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var chipForeground: Color {
    palette.chromeOnOpaque
  }

  static func format(seconds: Int) -> String {
    let clamped = max(0, seconds)
    return String(format: "%d:%02d", clamped / 60, clamped % 60)
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "moon.zzz.fill")
        .font(.caption)
        .foregroundStyle(chipForeground)

      Text(text)
        .font(.caption)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(chipForeground)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .modifier(HUDChipGlassStyle())
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

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if reduceMotion {
        // Reduce Motion: render a single static frame — no twinkle, drift,
        // shooting stars, or logo pulse.
        scene(t: 0)
      } else {
        TimelineView(.animation) { timeline in
          scene(t: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .environment(\.colorScheme, .dark)
  }

  private func scene(t: Double) -> some View {
    // Slowly drifting glow centers give the scene a gentle, living motion.
    let driftA = UnitPoint(x: 0.30 + 0.14 * sin(t * 0.043),
                           y: 0.34 + 0.10 * cos(t * 0.037))
    let driftB = UnitPoint(x: 0.72 + 0.12 * cos(t * 0.031),
                           y: 0.64 + 0.13 * sin(t * 0.049))
    return ZStack {
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
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var fg: Color { palette.chromeOnOpaque }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text("DIAGNOSTICS")
        .font(.system(size: 13, weight: .heavy).monospaced())
        .foregroundStyle(fg.opacity(0.6))

      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.system(size: 14, weight: .semibold).monospaced())
          .foregroundStyle(fg)
      }

      if !events.isEmpty {
        Divider().overlay(fg.opacity(0.2)).padding(.vertical, 2)
        ForEach(events) { event in
          Text(Self.eventLine(event))
            .font(.system(size: 13, weight: .regular).monospaced())
            .foregroundStyle(fg.opacity(0.8))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 520, alignment: .leading)
    .background(glassDisabled ? AnyShapeStyle(palette.chromeOpaqueSurface) : AnyShapeStyle(palette.chromeGlassTint(0.55)), in: shape)
    .overlay(shape.strokeBorder(glassDisabled ? palette.chromeOpaqueBorder : .white.opacity(0.12), lineWidth: 1))
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
