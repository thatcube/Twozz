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
@MainActor
@Observable
final class ChatService {
  /// Rolling buffer of the most recent messages (oldest first).
  private(set) var messages: [ChatMessage] = []
  private(set) var isConnected = false
  private(set) var emoteURLs: [String: URL] = [:]
  private(set) var badgeURLs: [String: URL] = [:]
  private(set) var cheermotes: [Cheermote] = []
  private(set) var condensedMessagesCount = 0
  private(set) var youtubeStatusMessage: String?
  /// Set when a raid USERNOTICE arrives. Cleared by the consumer after handling.
  var pendingRaid: RaidEvent?

  /// Number of messages currently held back by stream-sync delay (not yet shown).
  private(set) var pendingSyncMessageCount = 0

  /// When true, incoming messages are held for `chatSyncDelaySeconds` before
  /// becoming visible, so chat aligns with the delayed video stream.
  private var chatSyncEnabled = false
  /// How long (seconds) to hold incoming messages when sync is active.
  private var chatSyncDelaySeconds: Double = 0
  /// Minimum delay for sync to actually hold messages; below this it's a no-op.
  private let chatSyncMinDelaySeconds: Double = 0.75
  /// On a fresh connect the effective sync delay eases from 0 up to the full
  /// `chatSyncDelaySeconds` over this window, so live Twitch + YouTube messages
  /// surface almost immediately at the start and gradually settle into sync.
  private let chatSyncWarmupSeconds: Double = 30
  /// Wall-clock anchor for the warm-up ramp, set on each fresh `connect`.
  private var syncWarmupStart: Date?
  /// Hard ceiling on how many already-behind-the-playhead backlog messages we
  /// dump immediately on connect, so the panel seeds with recent context
  /// instead of a wall of history.
  private let maxImmediateBacklogMessages = 8
  /// When a single batch would surface more than this many messages at once
  /// (e.g. the connect-time YouTube backlog + in-window fill), trickle them in
  /// over `immediateTrickleWindowSeconds` instead of dumping them all at once,
  /// so the opening reads like live chat scrolling in rather than a wall.
  private let immediateTrickleThreshold = 4
  private let immediateTrickleWindowSeconds: Double = 1.5
  private let immediateTrickleMinIntervalSeconds: Double = 0.06

  private struct PendingChatMessage {
    let message: ChatMessage
    let releaseAt: Date
  }

  /// Messages waiting out their sync delay before being shown (arrival order).
  private var syncBuffer: [PendingChatMessage] = []
  private var syncDrainTask: Task<Void, Never>?

  private let endpoint = URL(string: "wss://irc-ws.chat.twitch.tv:443")!

  private var socket: URLSessionWebSocketTask?
  /// One reusable session for the chat socket. Creating a fresh `URLSession` per
  /// (re)connect leaks the old one (it is never invalidated); reusing a single
  /// session avoids that accumulation over long viewing sessions.
  private let urlSession = URLSession(configuration: .default)
  /// Consecutive failed reconnects, for exponential backoff. Reset on a healthy
  /// receive.
  private var reconnectAttempts = 0
  private var receiveTask: Task<Void, Never>?
  private var channel: String?
  private var hasSentJoin = false
  private var hasCapAck = false
  private var youtubeMergeEnabled = false
  private var youtubeChannelOrURL = ""
  private var youtubeReceiveTask: Task<Void, Never>?
  private var youtubeSeenMessageIDs: Set<String> = []
  private var youtubeSeenMessageOrder: [String] = []
  private let youtubePollFallbackDelayMs: UInt64 = 1800
  private let youtubePollMinDelayMs: UInt64 = 900
  private let youtubeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
  private let maxBufferedMessages = 1800

  func configureExperimentalYouTubeMerge(enabled: Bool, channelOrURL: String) {
    youtubeMergeEnabled = enabled
    youtubeChannelOrURL = channelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    restartYouTubeLoopIfNeeded()
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
    syncWarmupStart = Date()
    reconnectAttempts = 0

    let task = urlSession.webSocketTask(with: endpoint)
    socket = task
    task.resume()

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
  }

  /// Tear down the connection and clear the buffer.
  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    stopYouTubeLoop(clearStatus: true)
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
    channel = nil
    hasSentJoin = false
    hasCapAck = false
  }

  private func sendJoinIfNeeded() {
    guard !hasSentJoin, let channel else { return }
    send("JOIN #\(channel)")
    hasSentJoin = true
  }

  private func send(_ command: String) {
    socket?.send(.string(command + "\r\n")) { _ in }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      guard let currentSocket = socket else { break }
      do {
        let frame = try await currentSocket.receive()
        reconnectAttempts = 0
        switch frame {
        case .string(let text): handle(text)
        case .data(let data): handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        guard !Task.isCancelled else { break }
        isConnected = false

        // Reconnect with exponential backoff (3s, 6s, 12s… capped at 30s),
        // preserving the message buffer.
        guard let channelToRejoin = channel else { break }
        let delay = min(3.0 * pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, channel == channelToRejoin else { break }

        socket?.cancel(with: .goingAway, reason: nil)
        let newTask = urlSession.webSocketTask(with: endpoint)
        socket = newTask
        hasSentJoin = false
        hasCapAck = false
        newTask.resume()
        send("PASS SCHMOOPIIE")
        send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
        send("CAP REQ :twitch.tv/tags twitch.tv/commands")
        // Loop continues — next iteration receives on the new socket.
      }
    }
  }

  private func handle(_ raw: String) {
    // A single frame can batch multiple IRC lines.
    var parsedMessages: [ChatMessage] = []
    for piece in raw.components(separatedBy: "\r\n") where !piece.isEmpty {
      if piece.hasPrefix("PING") {
        send("PONG :tmi.twitch.tv")
        continue
      }
      if piece.contains(" CAP ") && piece.contains(" ACK ") && piece.contains("twitch.tv/tags") {
        hasCapAck = true
        sendJoinIfNeeded()
        continue
      }
      if piece.contains(" 366 ") {  // end-of-NAMES => join confirmed
        isConnected = true
        continue
      }
      if let raid = parseRaidEvent(from: piece) {
        pendingRaid = raid
        continue
      }
      if let subMessage = ChatMessage(subscriptionUSERNOTICE: piece) {
        parsedMessages.append(subMessage)
        continue
      }
      if let message = ChatMessage(ircLine: piece) {
        parsedMessages.append(message)
      }
    }

    guard !parsedMessages.isEmpty else { return }
    enqueue(parsedMessages)
  }

  /// Parse a Twitch USERNOTICE line for `msg-id=raid` and return a `RaidEvent`.
  private func parseRaidEvent(from line: String) -> RaidEvent? {
    // Line format:
    //   @tags :tmi.twitch.tv USERNOTICE #channel [:message]
    guard line.contains(" USERNOTICE ") else { return nil }

    // Extract tags section.
    var tags: [String: String] = [:]
    if line.first == "@", let spaceIdx = line.firstIndex(of: " ") {
      let tagString = line[line.index(after: line.startIndex)..<spaceIdx]
      for pair in tagString.split(separator: ";") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if kv.count == 2 { tags[String(kv[0])] = String(kv[1]) }
        else if kv.count == 1 { tags[String(kv[0])] = "" }
      }
    }

    guard tags["msg-id"] == "raid" else { return nil }

    let login = tags["msg-param-login"] ?? ""
    let displayName = tags["msg-param-displayName"] ?? login
    let viewerCount = Int(tags["msg-param-viewerCount"] ?? "0") ?? 0
    guard !login.isEmpty else { return nil }

    return RaidEvent(login: login, displayName: displayName, viewerCount: viewerCount)
  }

  private func restartYouTubeLoopIfNeeded() {
    stopYouTubeLoop(clearStatus: false)

    guard youtubeMergeEnabled else {
      youtubeStatusMessage = nil
      return
    }

    let target = youtubeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      youtubeStatusMessage = "Enter a YouTube handle, URL, or video ID."
      return
    }

    youtubeStatusMessage = "Resolving YouTube live stream…"
    youtubeReceiveTask = Task { [weak self] in
      await self?.runYouTubeLoop(target: target)
    }
  }

  private func stopYouTubeLoop(clearStatus: Bool) {
    youtubeReceiveTask?.cancel()
    youtubeReceiveTask = nil
    if clearStatus {
      youtubeStatusMessage = nil
    }
  }

  private func runYouTubeLoop(target: String) async {
    var videoID: String?
    var continuationToken: String?
    var apiKey: String?
    var clientVersion: String?
    var isFirstPoll = true

    while !Task.isCancelled {
      do {
        if videoID == nil {
          videoID = await resolveYouTubeVideoID(from: target)
          guard let currentVideoID = videoID else {
            youtubeStatusMessage = "No live YouTube stream found for \(target)."
            try? await Task.sleep(for: .seconds(10))
            continue
          }
          youtubeStatusMessage = "Connecting YouTube chat…"
          continuationToken = nil
          apiKey = nil
          clientVersion = nil
          _ = currentVideoID
        }

        if continuationToken == nil || apiKey == nil || clientVersion == nil {
          guard let currentVideoID = videoID else {
            throw YouTubeScrapeError.bootstrapUnavailable
          }

          let bootstrap = try await fetchYouTubeBootstrap(videoID: currentVideoID)
          continuationToken = bootstrap.continuation
          apiKey = bootstrap.apiKey
          clientVersion = bootstrap.clientVersion
          youtubeStatusMessage = "YouTube chat connected."
        }

        guard let currentContinuation = continuationToken,
          let currentAPIKey = apiKey,
          let currentClientVersion = clientVersion
        else {
          throw YouTubeScrapeError.bootstrapUnavailable
        }

        let pollResult = try await fetchYouTubeChatBatch(
          continuation: currentContinuation,
          apiKey: currentAPIKey,
          clientVersion: currentClientVersion
        )

        continuationToken = pollResult.continuation ?? continuationToken
        let freshMessages = filterAndRememberYouTubeMessages(pollResult.entries)

        let delay = pollResult.timeoutMs ?? youtubePollFallbackDelayMs
        let clampedDelay = max(youtubePollMinDelayMs, delay)

        if isFirstPoll {
          // First load: enqueue normally. The playhead + warm-up rule shows
          // recent backlog right away (capped) and eases live messages in,
          // so the panel fills instantly instead of waiting out the full delay.
          if !freshMessages.isEmpty { enqueue(freshMessages) }
          isFirstPoll = false
          try? await Task.sleep(for: .milliseconds(Int(clampedDelay)))
        } else if freshMessages.count > 1 {
          // Trickle messages evenly across the polling interval so they arrive
          // one-by-one rather than all at once.
          let perMs = clampedDelay / UInt64(freshMessages.count)
          for msg in freshMessages {
            enqueue([msg])
            try? await Task.sleep(for: .milliseconds(Int(perMs)))
          }
        } else {
          if !freshMessages.isEmpty { enqueue(freshMessages) }
          try? await Task.sleep(for: .milliseconds(Int(clampedDelay)))
        }
      } catch {
        if Task.isCancelled { break }
        youtubeStatusMessage = "YouTube chat unavailable right now."

        // Re-bootstrap after failures because continuation tokens can expire.
        videoID = nil
        continuationToken = nil
        apiKey = nil
        clientVersion = nil
        try? await Task.sleep(for: .seconds(4))
      }
    }
  }

  private func resolveYouTubeVideoID(from input: String) async -> String? {
    if let direct = Self.extractYouTubeVideoID(from: input) {
      return direct
    }

    guard let liveURL = Self.makeYouTubeLiveLookupURL(from: input) else {
      return nil
    }

    var request = URLRequest(url: liveURL)
    request.timeoutInterval = 20
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200...299).contains(http.statusCode)
      else {
        return nil
      }

      if let finalURL = http.url?.absoluteString,
        let id = Self.extractYouTubeVideoID(from: finalURL)
      {
        return id
      }

      let html = String(decoding: data, as: UTF8.self)
      if let canonical = Self.extractQuotedValue(after: "\"canonicalUrl\":\"", in: html) {
        let decodedCanonical = Self.decodeEscapedJSONString(canonical)
        if let id = Self.extractYouTubeVideoID(from: decodedCanonical) {
          return id
        }
      }

      if let id = Self.extractQuotedValue(after: "\"videoId\":\"", in: html)
        .flatMap(Self.sanitizedYouTubeVideoID)
      {
        return id
      }
    } catch {
      return nil
    }

    return nil
  }

  private func filterAndRememberYouTubeMessages(_ entries: [YouTubePollEntry]) -> [ChatMessage] {
    guard !entries.isEmpty else { return [] }

    var out: [ChatMessage] = []
    for entry in entries {
      guard !youtubeSeenMessageIDs.contains(entry.id) else { continue }
      youtubeSeenMessageIDs.insert(entry.id)
      youtubeSeenMessageOrder.append(entry.id)
      out.append(entry.message)
    }

    let maxSeen = 4000
    if youtubeSeenMessageOrder.count > maxSeen {
      let overflow = youtubeSeenMessageOrder.count - maxSeen
      let toRemove = youtubeSeenMessageOrder.prefix(overflow)
      for id in toRemove {
        youtubeSeenMessageIDs.remove(id)
      }
      youtubeSeenMessageOrder.removeFirst(overflow)
    }

    return out
  }

  private struct YouTubeBootstrap {
    let apiKey: String
    let clientVersion: String
    let continuation: String
  }

  private struct YouTubePollEntry {
    let id: String
    let message: ChatMessage
  }

  private struct YouTubePollResult {
    let entries: [YouTubePollEntry]
    let continuation: String?
    let timeoutMs: UInt64?
  }

  private enum YouTubeScrapeError: LocalizedError {
    case bootstrapUnavailable
    case invalidResponse
    case httpFailure(Int)

    var errorDescription: String? {
      switch self {
      case .bootstrapUnavailable:
        return "Could not initialize YouTube live chat."
      case .invalidResponse:
        return "YouTube live chat response could not be parsed."
      case .httpFailure(let statusCode):
        return "YouTube request failed (HTTP \(statusCode))."
      }
    }
  }

  private func fetchYouTubeBootstrap(videoID: String) async throws -> YouTubeBootstrap {
    guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
      throw YouTubeScrapeError.bootstrapUnavailable
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeScrapeError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      throw YouTubeScrapeError.httpFailure(http.statusCode)
    }

    let html = String(decoding: data, as: UTF8.self)
    guard
      let apiKey = Self.extractQuotedValue(after: "\"INNERTUBE_API_KEY\":\"", in: html),
      let clientVersion = Self.extractQuotedValue(after: "\"INNERTUBE_CLIENT_VERSION\":\"", in: html),
      let continuation = Self.extractInitialYouTubeContinuation(in: html)
    else {
      throw YouTubeScrapeError.bootstrapUnavailable
    }

    return YouTubeBootstrap(
      apiKey: Self.decodeEscapedJSONString(apiKey),
      clientVersion: Self.decodeEscapedJSONString(clientVersion),
      continuation: Self.decodeEscapedJSONString(continuation)
    )
  }

  private func fetchYouTubeChatBatch(
    continuation: String,
    apiKey: String,
    clientVersion: String
  ) async throws -> YouTubePollResult {
    guard
      let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let endpoint = URL(
        string: "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?key=\(encodedKey)")
    else {
      throw YouTubeScrapeError.invalidResponse
    }

    let payload: [String: Any] = [
      "context": [
        "client": [
          "clientName": "WEB",
          "clientVersion": clientVersion,
        ]
      ],
      "continuation": continuation,
      "webClientInfo": [
        "isDocumentHidden": false,
      ],
    ]

    let body = try JSONSerialization.data(withJSONObject: payload, options: [])

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeScrapeError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      throw YouTubeScrapeError.httpFailure(http.statusCode)
    }

    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let continuationContents = root["continuationContents"] as? [String: Any],
      let liveChatContinuation = continuationContents["liveChatContinuation"] as? [String: Any]
    else {
      throw YouTubeScrapeError.invalidResponse
    }

    let entries = parseYouTubeEntries(from: liveChatContinuation)
    let (nextContinuation, timeoutMs) = parseYouTubeContinuation(from: liveChatContinuation)
    return YouTubePollResult(entries: entries, continuation: nextContinuation, timeoutMs: timeoutMs)
  }

  private func parseYouTubeEntries(from liveChatContinuation: [String: Any]) -> [YouTubePollEntry] {
    guard let actions = liveChatContinuation["actions"] as? [[String: Any]] else { return [] }
    var out: [YouTubePollEntry] = []

    for action in actions {
      guard
        let addChatItem = action["addChatItemAction"] as? [String: Any],
        let item = addChatItem["item"] as? [String: Any],
        let renderer = Self.findLiveChatRenderer(in: item)
      else {
        continue
      }

      guard
        let id = renderer["id"] as? String,
        let author = Self.extractSimpleOrRunsText(from: renderer["authorName"]),
        let payload = Self.extractMessagePayload(from: renderer),
        !author.isEmpty,
        !payload.text.isEmpty
      else {
        continue
      }

      let timestamp: Date
      if let tsUsec = renderer["timestampUsec"] as? String,
        let tsInt = Double(tsUsec)
      {
        timestamp = Date(timeIntervalSince1970: tsInt / 1_000_000)
      } else {
        timestamp = Date()
      }

      let message = ChatMessage(
        youtubeAuthor: author,
        text: payload.text,
        youtubeEmoteURLs: payload.emotes,
        timestamp: timestamp
      )
      out.append(YouTubePollEntry(id: id, message: message))
    }

    return out
  }

  private func parseYouTubeContinuation(from liveChatContinuation: [String: Any]) -> (
    continuation: String?, timeoutMs: UInt64?
  ) {
    guard let continuations = liveChatContinuation["continuations"] as? [[String: Any]] else {
      return (nil, nil)
    }

    for candidate in continuations {
      if let timed = candidate["timedContinuationData"] as? [String: Any] {
        let token = timed["continuation"] as? String
        let timeout = timed["timeoutMs"] as? UInt64
        return (token, timeout)
      }
      if let invalidation = candidate["invalidationContinuationData"] as? [String: Any] {
        let token = invalidation["continuation"] as? String
        let timeout = invalidation["timeoutMs"] as? UInt64
        return (token, timeout)
      }
      if let reload = candidate["reloadContinuationData"] as? [String: Any] {
        let token = reload["continuation"] as? String
        return (token, youtubePollFallbackDelayMs)
      }
    }

    return (nil, nil)
  }

  private static func findLiveChatRenderer(in item: [String: Any]) -> [String: Any]? {
    let keys = [
      "liveChatTextMessageRenderer",
      "liveChatPaidMessageRenderer",
      "liveChatMembershipItemRenderer",
    ]
    for key in keys {
      if let renderer = item[key] as? [String: Any] {
        return renderer
      }
    }
    return nil
  }

  private static func extractMessagePayload(from renderer: [String: Any]) -> (
    text: String, emotes: [String: URL]
  )? {
    if let message = extractMessageAndEmotes(from: renderer["message"]), !message.text.isEmpty {
      return message
    }

    if let amount = extractSimpleOrRunsText(from: renderer["purchaseAmountText"]), !amount.isEmpty {
      return (amount, [:])
    }

    if let header = extractSimpleOrRunsText(from: renderer["headerSubtext"]), !header.isEmpty {
      return (header, [:])
    }

    return nil
  }

  private static func extractMessageAndEmotes(from value: Any?) -> (text: String, emotes: [String: URL])? {
    guard let dictionary = value as? [String: Any] else { return nil }

    if let simple = dictionary["simpleText"] as? String {
      return simple.isEmpty ? nil : (simple, [:])
    }

    guard let runs = dictionary["runs"] as? [[String: Any]] else { return nil }

    var parts: [String] = []
    var emotes: [String: URL] = [:]

    for run in runs {
      if let runText = run["text"] as? String {
        parts.append(runText)
        continue
      }

      guard let emoji = run["emoji"] as? [String: Any] else { continue }
      let token = (emoji["shortcuts"] as? [String])?.first(where: { !$0.isEmpty })
        ?? (emoji["emojiId"] as? String)
        ?? ""
      guard !token.isEmpty else { continue }

      parts.append(token)
      if let url = extractYouTubeEmojiURL(from: emoji) {
        emotes[token] = url
      }
    }

    let text = parts.joined()
    return text.isEmpty ? nil : (text, emotes)
  }

  private static func extractYouTubeEmojiURL(from emoji: [String: Any]) -> URL? {
    guard
      let image = emoji["image"] as? [String: Any],
      let thumbnails = image["thumbnails"] as? [[String: Any]],
      !thumbnails.isEmpty
    else {
      return nil
    }

    let best = thumbnails.max { lhs, rhs in
      let lw = lhs["width"] as? Int ?? 0
      let rw = rhs["width"] as? Int ?? 0
      return lw < rw
    }

    if let bestURL = best?["url"] as? String, let url = URL(string: bestURL) {
      return url
    }

    if let firstURL = thumbnails.first?["url"] as? String, let url = URL(string: firstURL) {
      return url
    }

    return nil
  }

  private static func extractSimpleOrRunsText(from value: Any?) -> String? {
    guard let dictionary = value as? [String: Any] else { return nil }

    if let simple = dictionary["simpleText"] as? String {
      return simple
    }

    if let runs = dictionary["runs"] as? [[String: Any]] {
      let text = runs.compactMap { run -> String? in
        if let runText = run["text"] as? String {
          return runText
        }
        if let emoji = run["emoji"] as? [String: Any],
          let shortcuts = emoji["shortcuts"] as? [String],
          let first = shortcuts.first
        {
          return first
        }
        return nil
      }
      .joined()
      return text.isEmpty ? nil : text
    }

    return nil
  }

  private static func extractInitialYouTubeContinuation(in html: String) -> String? {
    if let liveIndex = html.range(of: "\"liveChatRenderer\"") {
      let tail = String(html[liveIndex.lowerBound...])
      if let continuation = extractQuotedValue(after: "\"continuation\":\"", in: tail) {
        return continuation
      }
    }
    return extractQuotedValue(after: "\"continuation\":\"", in: html)
  }

  private static func extractQuotedValue(after marker: String, in text: String) -> String? {
    guard let markerRange = text.range(of: marker) else { return nil }

    var index = markerRange.upperBound
    var out = ""
    var escaped = false

    while index < text.endIndex {
      let char = text[index]
      text.formIndex(after: &index)

      if escaped {
        out.append(char)
        escaped = false
        continue
      }

      if char == "\\" {
        escaped = true
        continue
      }

      if char == "\"" {
        return out
      }

      out.append(char)
    }

    return nil
  }

  private static func decodeEscapedJSONString(_ input: String) -> String {
    input
      .replacingOccurrences(of: "\\u0026", with: "&")
      .replacingOccurrences(of: "\\u003d", with: "=")
      .replacingOccurrences(of: "\\/", with: "/")
  }

  private static func makeYouTubeLiveLookupURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("@") {
      return URL(string: "https://www.youtube.com/\(trimmed)/live")
    }

    if !trimmed.contains("://") && !trimmed.contains("/") && !trimmed.contains("?") {
      return URL(string: "https://www.youtube.com/@\(trimmed)/live")
    }

    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: normalized),
      let host = components.host?.lowercased(),
      host.contains("youtube.com")
    else {
      return nil
    }

    let parts = components.path.split(separator: "/")
    if let handle = parts.first(where: { $0.hasPrefix("@") }) {
      return URL(string: "https://www.youtube.com/\(handle)/live")
    }

    if parts.count >= 2 {
      let root = parts[0]
      if root == "channel" || root == "c" || root == "user" {
        return URL(string: "https://www.youtube.com/\(root)/\(parts[1])/live")
      }
    }

    return nil
  }

  private static func extractYouTubeVideoID(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let direct = Self.sanitizedYouTubeVideoID(trimmed) {
      return direct
    }

    let normalized: String
    if trimmed.contains("://") {
      normalized = trimmed
    } else {
      normalized = "https://\(trimmed)"
    }

    guard let components = URLComponents(string: normalized),
      let host = components.host?.lowercased()
    else {
      return nil
    }

    if host.contains("youtu.be") {
      let pathComponent = components.path.split(separator: "/").first.map(String.init) ?? ""
      return sanitizedYouTubeVideoID(pathComponent)
    }

    if host.contains("youtube.com") {
      if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
        let id = sanitizedYouTubeVideoID(v)
      {
        return id
      }

      let parts = components.path.split(separator: "/")
      if parts.count >= 2 {
        if parts[0] == "live" {
          return sanitizedYouTubeVideoID(String(parts[1]))
        }
        if parts[0] == "embed" {
          return sanitizedYouTubeVideoID(String(parts[1]))
        }
      }
    }

    return nil
  }

  private static func sanitizedYouTubeVideoID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 11 else { return nil }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed
  }

  /// Sync delay actually applied right now. Eases from 0 up to the full
  /// `chatSyncDelaySeconds` over `chatSyncWarmupSeconds` after a fresh connect,
  /// so live messages from both platforms surface almost immediately at the
  /// start and gradually settle into video-sync.
  private func effectiveSyncDelay(now: Date) -> Double {
    guard chatSyncEnabled else { return 0 }
    let full = chatSyncDelaySeconds
    guard let start = syncWarmupStart, chatSyncWarmupSeconds > 0 else { return full }
    let progress = min(max(now.timeIntervalSince(start) / chatSyncWarmupSeconds, 0), 1)
    return full * progress
  }

  private func enqueue(_ incoming: [ChatMessage]) {
    let sorted = incoming.sorted { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.timestamp < rhs.timestamp
    }

    guard chatSyncEnabled, chatSyncDelaySeconds >= chatSyncMinDelaySeconds else {
      appendVisible(sorted)
      return
    }

    let now = Date()
    let delay = effectiveSyncDelay(now: now)
    // The synced playhead at full delay; anything older is true scrollback.
    let fullPlayhead = now.addingTimeInterval(-chatSyncDelaySeconds)

    var immediate: [ChatMessage] = []
    var backlog: [ChatMessage] = []
    // Never hold a message longer than the (effective) delay: a future clock
    // skew on a server timestamp must not push a genuinely-live message past
    // the playhead. (Past/old timestamps already fall through to immediate.)
    let maxReleaseAt = now.addingTimeInterval(delay)
    for message in sorted {
      let releaseAt = min(message.timestamp.addingTimeInterval(delay), maxReleaseAt)
      if releaseAt > now {
        syncBuffer.append(PendingChatMessage(message: message, releaseAt: releaseAt))
      } else if message.timestamp < fullPlayhead {
        // Behind the synced playhead: old scrollback, subject to the cap.
        backlog.append(message)
      } else {
        // In-window or live but releasable now (e.g. during warm-up): always show.
        immediate.append(message)
      }
    }

    // Cap the scrollback dump to the most recent few so the panel seeds with
    // recent context instead of a wall of history.
    if backlog.count > maxImmediateBacklogMessages {
      backlog.removeFirst(backlog.count - maxImmediateBacklogMessages)
    }

    let visibleNow = (backlog + immediate).sorted { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.timestamp < rhs.timestamp
    }
    scheduleImmediate(visibleNow, now: now)

    if !syncBuffer.isEmpty {
      // Keep release order correct even when immediate + delayed messages
      // interleave across enqueue calls.
      syncBuffer.sort { lhs, rhs in
        if lhs.releaseAt == rhs.releaseAt {
          if lhs.message.timestamp == rhs.message.timestamp {
            return lhs.message.id.uuidString < rhs.message.id.uuidString
          }
          return lhs.message.timestamp < rhs.message.timestamp
        }
        return lhs.releaseAt < rhs.releaseAt
      }
      pendingSyncMessageCount = syncBuffer.count
      startSyncDrainIfNeeded()
    }
  }

  /// Surfaces a batch that is releasable right now. Small batches appear
  /// instantly; a large fill (typically the connect-time backlog + in-window
  /// burst while the warm-up delay is still ~0) is trickled in over a short
  /// window via the sync buffer so it reads like live chat instead of a wall.
  private func scheduleImmediate(_ messages: [ChatMessage], now: Date) {
    guard !messages.isEmpty else { return }
    if messages.count <= immediateTrickleThreshold {
      appendVisible(messages)
      return
    }
    let perMessage = max(
      immediateTrickleWindowSeconds / Double(messages.count),
      immediateTrickleMinIntervalSeconds
    )
    for (index, message) in messages.enumerated() {
      let releaseAt = now.addingTimeInterval(perMessage * Double(index))
      syncBuffer.append(PendingChatMessage(message: message, releaseAt: releaseAt))
    }
  }

  private func appendVisible(_ sorted: [ChatMessage]) {
    guard !sorted.isEmpty else { return }
    var tokenized = sorted
    for index in tokenized.indices {
      tokenized[index].segments = computeSegments(for: tokenized[index])
    }
    messages.append(contentsOf: tokenized)
    if messages.count > maxBufferedMessages {
      messages.removeFirst(messages.count - maxBufferedMessages)
    }
  }

  /// Tokenize a message against the currently-loaded emote/cheermote catalogs.
  /// Live chat gates cheermote rendering on a real bits count.
  private func computeSegments(for message: ChatMessage) -> [ChatLineSegment] {
    let shouldRenderCheers = !cheermotes.isEmpty && message.bits > 0
    return ChatLineTokenizer.segments(
      text: message.text,
      twitchEmoteURLs: message.twitchEmoteURLs,
      youtubeEmoteURLs: message.youtubeEmoteURLs,
      globalEmoteURLs: emoteURLs,
      cheermotes: cheermotes,
      shouldRenderCheers: shouldRenderCheers
    )
  }

  /// Re-tokenize the visible buffer after an emote or cheermote catalog loads,
  /// so messages that arrived before the catalog resolve their emotes/cheers.
  private func retokenizeVisibleBuffer() {
    guard !messages.isEmpty else { return }
    for index in messages.indices {
      messages[index].segments = computeSegments(for: messages[index])
    }
  }

  private func startSyncDrainIfNeeded() {
    guard syncDrainTask == nil else { return }
    syncDrainTask = Task { [weak self] in
      await self?.drainSyncBuffer()
    }
  }

  /// Releases held messages to the visible buffer as each one's delay elapses,
  /// preserving arrival order.
  private func drainSyncBuffer() async {
    while !Task.isCancelled {
      guard let next = syncBuffer.first else { break }

      let now = Date()
      if next.releaseAt > now {
        try? await Task.sleep(for: .seconds(next.releaseAt.timeIntervalSince(now)))
        if Task.isCancelled { return }
        continue
      }

      var released: [ChatMessage] = []
      while let first = syncBuffer.first, first.releaseAt <= now {
        released.append(first.message)
        syncBuffer.removeFirst()
      }
      appendVisible(released)
      pendingSyncMessageCount = syncBuffer.count
    }
    syncDrainTask = nil
  }

  /// Immediately surfaces every held message (used when sync is turned off or
  /// the connection tears down) so no message is dropped.
  private func flushSyncBuffer() {
    syncDrainTask?.cancel()
    syncDrainTask = nil
    guard !syncBuffer.isEmpty else {
      pendingSyncMessageCount = 0
      return
    }
    let pending = syncBuffer.map(\.message)
    syncBuffer.removeAll()
    pendingSyncMessageCount = 0
    appendVisible(pending)
  }
}

actor BadgeCatalogService {
  static let shared = BadgeCatalogService()

  private let clientID = TwitchConfig.webPublicClientID
  private let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  private var cache: [String: [String: URL]] = [:]

  func catalog(for channel: String) async -> [String: URL] {
    let key = channel.lowercased()
    if let cached = cache[key] { return cached }

    let userID = await twitchUserID(for: key)

    async let global = fetchGlobalBadges()
    async let channelBadges = fetchChannelBadges(twitchUserID: userID)

    let merged = (await global).merging(await channelBadges) { _, new in new }
    cache[key] = merged
    return merged
  }

  private func fetchGlobalBadges() async -> [String: URL] {
    guard let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/global") else { return [:] }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func fetchChannelBadges(twitchUserID: String?) async -> [String: URL] {
    guard let twitchUserID,
      let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/channel?id=\(twitchUserID)")
    else {
      return [:]
    }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func parseBadgeJSON(_ json: Any) -> [String: URL] {
    if let dict = json as? [String: Any] {
      return parseLegacyBadgeDisplayJSON(dict)
    }
    if let array = json as? [[String: Any]] {
      return parseIVRBadgeArray(array)
    }
    return [:]
  }

  private func parseLegacyBadgeDisplayJSON(_ json: [String: Any]) -> [String: URL] {
    guard let sets = json["badge_sets"] as? [String: Any] else { return [:] }
    var out: [String: URL] = [:]

    for (setName, setValue) in sets {
      guard let set = setValue as? [String: Any],
        let versions = set["versions"] as? [String: Any]
      else { continue }

      for (version, versionValue) in versions {
        guard let meta = versionValue as? [String: Any] else { continue }
        let urlString =
          (meta["image_url_2x"] as? String)
          ?? (meta["image_url_4x"] as? String)
          ?? (meta["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setName)/\(version)"] = url
      }
    }

    return out
  }

  private func parseIVRBadgeArray(_ sets: [[String: Any]]) -> [String: URL] {
    var out: [String: URL] = [:]

    for set in sets {
      guard let setID = set["set_id"] as? String,
        let versions = set["versions"] as? [[String: Any]]
      else { continue }

      for version in versions {
        guard let versionID = version["id"] as? String else { continue }
        let urlString =
          (version["image_url_2x"] as? String)
          ?? (version["image_url_4x"] as? String)
          ?? (version["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setID)/\(versionID)"] = url
      }
    }

    return out
  }

  private func twitchUserID(for login: String) async -> String? {
    if let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let ivrURL = URL(string: "https://api.ivr.fi/v2/twitch/user?login=\(encoded)"),
      let payload = await fetchJSON(url: ivrURL) as? [[String: Any]],
      let id = payload.first?["id"] as? String,
      !id.isEmpty
    {
      return id
    }

    var req = TwitchAPIClient.graphQLRequest(
      clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)

    let query = "query UserID($login: String!) { user(login: $login) { id } }"
    req.httpBody = try? JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["login": login]))

    guard let json = await fetchJSON(request: req) as? [String: Any] else { return nil }
    guard let data = json["data"] as? [String: Any] else { return nil }
    guard let user = data["user"] as? [String: Any] else { return nil }
    return user["id"] as? String
  }

  private func fetchJSON(url: URL) async -> Any? {
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private func fetchJSON(request: URLRequest) async -> Any? {
    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
