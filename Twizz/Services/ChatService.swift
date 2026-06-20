import Foundation
import Observation

enum ChatReadabilityMode: String, CaseIterable {
  case comfortable
  case balanced
  case compact

  var title: String {
    switch self {
    case .comfortable: return "Comfortable"
    case .balanced: return "Balanced"
    case .compact: return "Compact"
    }
  }
}

/// User-adjustable width of the docked chat panel.
enum ChatWidthMode: String, CaseIterable {
  case narrow
  case medium
  case wide
  case extraWide

  var title: String {
    switch self {
    case .narrow: return "Narrow"
    case .medium: return "Medium"
    case .wide: return "Wide"
    case .extraWide: return "Extra Wide"
    }
  }

  var width: CGFloat {
    switch self {
    case .narrow: return 380
    case .medium: return 460
    case .wide: return 560
    case .extraWide: return 680
    }
  }
}

/// Where the chat panel is positioned relative to the video.
enum ChatLayoutMode: String, CaseIterable {
  /// Chat docks beside the video; the video shrinks to make room.
  case side
  /// Chat floats translucently on top of a full-width video.
  case overlay
  /// Chat floats on top of a full-width video as a rounded Liquid Glass panel.
  case glass

  var title: String {
    switch self {
    case .side: return "Side"
    case .overlay: return "Overlay"
    case .glass: return "Glass"
    }
  }

  /// Whether the chat floats on top of a full-width video (vs. docking beside it).
  var isOverlay: Bool {
    switch self {
    case .side: return false
    case .overlay, .glass: return true
    }
  }
}

/// Carries the info from a Twitch raid USERNOTICE.
struct RaidEvent: Equatable {
  let login: String
  let displayName: String
  let viewerCount: Int
}

/// Reads a Twitch channel's chat anonymously over IRC-via-WebSocket.
///
/// No login or token required: we connect as a `justinfan` guest, request the
/// `twitch.tv/tags` capability (for display names + colors), and parse PRIVMSG
/// lines into `ChatMessage`s. Sending messages is intentionally out of scope.
///
/// The concerns are split across sibling files: IRC transport + line parsing
/// (`ChatService+IRC`), the experimental YouTube merge path
/// (`ChatService+YouTube`), stream-sync buffering (`ChatService+Sync`), and
/// emote/cheermote tokenization (`ChatService+Catalog`). This file owns the
/// observable state and the connect/disconnect/configuration lifecycle.
@MainActor
@Observable
final class ChatService {
  /// Rolling buffer of the most recent messages (oldest first).
  var messages: [ChatMessage] = []
  var isConnected = false
  private(set) var emoteURLs: [String: URL] = [:]
  private(set) var badgeURLs: [String: URL] = [:]
  private(set) var cheermotes: [Cheermote] = []
  private(set) var condensedMessagesCount = 0
  var youtubeStatusMessage: String?
  var kickStatusMessage: String?
  /// Set when a raid USERNOTICE arrives. Cleared by the consumer after handling.
  var pendingRaid: RaidEvent?

  /// Number of messages currently held back by stream-sync delay (not yet shown).
  var pendingSyncMessageCount = 0

  /// When true, incoming messages are held for `chatSyncDelaySeconds` before
  /// becoming visible, so chat aligns with the delayed video stream.
  var chatSyncEnabled = false
  /// How long (seconds) to hold incoming messages when sync is active.
  var chatSyncDelaySeconds: Double = 0
  /// Minimum delay for sync to actually hold messages; below this it's a no-op.
  let chatSyncMinDelaySeconds: Double = 0.75
  /// On a fresh connect the effective sync delay eases from 0 up to the full
  /// `chatSyncDelaySeconds` over this window, so live Twitch + YouTube messages
  /// surface almost immediately at the start and gradually settle into sync.
  let chatSyncWarmupSeconds: Double = 30
  /// Wall-clock anchor for the warm-up ramp, set on each fresh `connect`.
  var syncWarmupStart: Date?
  /// Hard ceiling on how many already-behind-the-playhead backlog messages we
  /// dump immediately on connect, so the panel seeds with recent context
  /// instead of a wall of history.
  let maxImmediateBacklogMessages = 8
  /// When a single batch would surface more than this many messages at once
  /// (e.g. the connect-time YouTube backlog + in-window fill), trickle them in
  /// over `immediateTrickleWindowSeconds` instead of dumping them all at once,
  /// so the opening reads like live chat scrolling in rather than a wall.
  let immediateTrickleThreshold = 4
  let immediateTrickleWindowSeconds: Double = 1.5
  let immediateTrickleMinIntervalSeconds: Double = 0.06

  /// Messages waiting out their sync delay before being shown (arrival order).
  var syncBuffer: [PendingChatMessage] = []
  var syncDrainTask: Task<Void, Never>?

  let endpoint = URL(string: "wss://irc-ws.chat.twitch.tv:443")!

  /// Shared WebSocket transport: owns the reused `URLSession`, the socket task,
  /// and the exponential-backoff counter.
  let connection = WebSocketConnection()
  private var receiveTask: Task<Void, Never>?
  var channel: String?
  var hasSentJoin = false
  var hasCapAck = false
  var youtubeMergeEnabled = false
  var youtubeChannelOrURL = ""
  var youtubeReceiveTask: Task<Void, Never>?
  var youtubeSeenMessageIDs: Set<String> = []
  var youtubeSeenMessageOrder: [String] = []
  let youtubePollFallbackDelayMs: UInt64 = 1800
  let youtubePollMinDelayMs: UInt64 = 900
  let youtubeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
  /// Experimental Kick live-chat merge state. Mirrors the YouTube merge path but
  /// rides Kick's Pusher WebSocket instead of polling. Owns its own socket so a
  /// Kick reconnect never disturbs the Twitch IRC connection.
  var kickMergeEnabled = false
  var kickChannelOrURL = ""
  let kickConnection = WebSocketConnection()
  var kickReceiveTask: Task<Void, Never>?
  var kickChatroomID: Int?
  var kickSubscribedChannel: String?
  /// Canonical slug + liveness captured when the channel API last resolved, so
  /// the status line can show *which* Kick channel we joined and whether it's
  /// actually live (rather than just "connected").
  var kickResolvedSlug: String?
  var kickResolvedIsLive = false
  var kickSeenMessageIDs: Set<String> = []
  var kickSeenMessageOrder: [String] = []
  /// Rolling cap on retained chat lines. The live list backs a `LazyVStack`
  /// whose `ForEach` is diffed on every append, and both `visibleChatMessages`
  /// and the gesture scroll loop scan/copy this array (the loop does so up to
  /// 60×/sec while swiping). All of that scales with the count, so on a busy or
  /// raided channel a large buffer is a steady scroll-cost tax. 500 keeps a
  /// generous scrollback window (~3× Twitch web's ~150) while staying light on
  /// the Apple TV's modest CPU.
  let maxBufferedMessages = 500

  func configureExperimentalYouTubeMerge(enabled: Bool, channelOrURL: String) {
    youtubeMergeEnabled = enabled
    youtubeChannelOrURL = channelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    restartYouTubeLoopIfNeeded()
  }

  func configureExperimentalKickMerge(enabled: Bool, channelOrURL: String) {
    kickMergeEnabled = enabled
    kickChannelOrURL = channelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    restartKickLoopIfNeeded()
  }

  /// Configure stream-sync chat delay. When `enabled` and `delaySeconds` is
  /// meaningful, incoming messages are held back so chat lines up with the
  /// delayed video. Disabling (or a negligible delay) flushes any held
  /// messages immediately so nothing is lost.
  func configureChatSync(enabled: Bool, delaySeconds: Double) {
    let clamped = max(0, delaySeconds)
    let shouldHold = enabled && clamped >= chatSyncMinDelaySeconds

    chatSyncDelaySeconds = clamped

    if shouldHold {
      chatSyncEnabled = true
    } else if chatSyncEnabled || !syncBuffer.isEmpty {
      chatSyncEnabled = false
      flushSyncBuffer()
    }
  }

  func applyReadabilitySettings(
    mode: ChatReadabilityMode,
    smartFilteringEnabled: Bool,
    collapseRepeatsEnabled: Bool
  ) {
    _ = mode
    _ = smartFilteringEnabled
    _ = collapseRepeatsEnabled
    // This streamlined chat path currently renders messages directly.
    // Keep compatibility with existing settings UI while preserving behavior.
  }

  /// Connect and join `channel` (case-insensitive). Replaces any existing connection.
  func connect(to channel: String) {
    disconnect()
    let normalized = channel.lowercased()
    self.channel = normalized
    hasSentJoin = false
    hasCapAck = false
    emoteURLs = [:]
    badgeURLs = [:]
    cheermotes = []
    youtubeSeenMessageIDs.removeAll()
    youtubeSeenMessageOrder.removeAll()
    youtubeStatusMessage = nil
    kickSeenMessageIDs.removeAll()
    kickSeenMessageOrder.removeAll()
    kickStatusMessage = nil
    syncWarmupStart = Date()
    connection.resetBackoff()

    connection.connect(to: endpoint)

    send("PASS SCHMOOPIIE")
    send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
    send("CAP REQ :twitch.tv/tags twitch.tv/commands")

    Task { [weak self] in
      guard let self else { return }
      let catalog = await EmoteCatalogService.shared.catalog(for: normalized)
      guard self.channel == normalized else { return }
      self.emoteURLs = catalog
      self.retokenizeVisibleBuffer()
    }

    Task { [weak self] in
      guard let self else { return }
      let catalog = await BadgeCatalogService.shared.catalog(for: normalized)
      guard self.channel == normalized else { return }
      self.badgeURLs = catalog
    }

    Task { [weak self] in
      guard let self else { return }
      let catalog = await CheermoteCatalogService.shared.catalog(for: normalized)
      guard self.channel == normalized else { return }
      self.cheermotes = catalog
      self.retokenizeVisibleBuffer()
    }

    receiveTask = Task { [weak self] in await self?.receiveLoop() }
    restartYouTubeLoopIfNeeded()
    restartKickLoopIfNeeded()
  }

  /// Tear down the connection and clear the buffer.
  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    connection.cancel()
    stopYouTubeLoop(clearStatus: true)
    stopKickLoop(clearStatus: true)
    isConnected = false
    messages.removeAll()
    syncDrainTask?.cancel()
    syncDrainTask = nil
    syncBuffer.removeAll()
    pendingSyncMessageCount = 0
    syncWarmupStart = nil
    emoteURLs.removeAll()
    badgeURLs.removeAll()
    cheermotes.removeAll()
    youtubeSeenMessageIDs.removeAll()
    youtubeSeenMessageOrder.removeAll()
    kickSeenMessageIDs.removeAll()
    kickSeenMessageOrder.removeAll()
    channel = nil
    hasSentJoin = false
    hasCapAck = false
  }
}
