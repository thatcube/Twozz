import Foundation

/// Experimental Kick live-chat merge path for `ChatService`: resolves a Kick
/// channel slug to its chatroom id, rides Kick's public Pusher WebSocket, and
/// converts `ChatMessageEvent`s into `ChatMessage`s. Entirely separate from the
/// Twitch IRC path and the YouTube poll path; failures degrade gracefully via
/// `kickStatusMessage`.
///
/// Kick fronts its chat on the same Pusher infrastructure the web client uses,
/// so once the chatroom id is known (from the public `/api/v2/channels/<slug>`
/// endpoint) we can subscribe anonymously — no auth token required, mirroring
/// the anonymous Twitch and YouTube reads elsewhere in this service.
extension ChatService {
  /// Kick's public Pusher app key + cluster, as used by the web chat client.
  private static let kickPusherAppKey = "32cbd69e4b950bf97679"
  private static let kickPusherURL = URL(
    string:
      "wss://ws-us2.pusher.com/app/\(kickPusherAppKey)?protocol=7&client=js&version=8.4.0&flash=false"
  )!

  func restartKickLoopIfNeeded() {
    stopKickLoop(clearStatus: false)

    guard kickMergeEnabled else {
      kickStatusMessage = nil
      return
    }

    let target = kickChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      kickStatusMessage = "Enter a Kick handle or channel URL."
      return
    }

    kickStatusMessage = "Resolving Kick channel…"
    kickReceiveTask = Task { [weak self] in
      await self?.runKickLoop(target: target)
    }
  }

  func stopKickLoop(clearStatus: Bool) {
    kickReceiveTask?.cancel()
    kickReceiveTask = nil
    kickConnection.cancel()
    kickChatroomID = nil
    kickSubscribedChannel = nil
    kickResolvedSlug = nil
    kickResolvedIsLive = false
    if clearStatus {
      kickStatusMessage = nil
    }
  }

  private func runKickLoop(target: String) async {
    while !Task.isCancelled {
      do {
        if kickChatroomID == nil {
          guard let slug = Self.extractKickSlug(from: target) else {
            kickStatusMessage = "Enter a valid Kick handle or URL."
            try? await Task.sleep(for: .seconds(10))
            continue
          }

          guard let info = try await Self.fetchKickChannelInfo(slug: slug) else {
            kickStatusMessage = "No Kick channel found for \(slug)."
            try? await Task.sleep(for: .seconds(10))
            continue
          }

          kickChatroomID = info.chatroomID
          kickResolvedSlug = info.slug
          kickResolvedIsLive = info.isLive
          kickStatusMessage = "Connecting to kick.com/\(info.slug)…"
        }

        guard let chatroomID = kickChatroomID else {
          throw KickScrapeError.invalidResponse
        }

        kickConnection.connect(to: Self.kickPusherURL)
        kickSubscribedChannel = nil

        try await runKickReceive(chatroomID: chatroomID)
      } catch {
        if Task.isCancelled { break }
        kickStatusMessage = "Kick chat unavailable right now."
        kickConnection.cancel()
        kickSubscribedChannel = nil

        // Reconnect the Pusher socket with exponential backoff, preserving the
        // resolved chatroom id so reconnects don't re-hit the channel API.
        let delay = kickConnection.nextBackoffDelay()
        try? await Task.sleep(for: .seconds(delay))
      }
    }
  }

  private func runKickReceive(chatroomID: Int) async throws {
    guard let socket = kickConnection.currentTask else { return }

    while !Task.isCancelled {
      let frame = try await socket.receive()
      kickConnection.resetBackoff()

      let text: String
      switch frame {
      case .string(let string): text = string
      case .data(let data): text = String(decoding: data, as: UTF8.self)
      @unknown default: continue
      }

      handleKickFrame(text, chatroomID: chatroomID)

      // A reconnect (or teardown) replaces the socket; stop reading the old one
      // so the next loop iteration receives on the fresh task instead.
      guard kickConnection.currentTask === socket else { return }
    }
  }

  private func handleKickFrame(_ text: String, chatroomID: Int) {
    guard let data = text.data(using: .utf8),
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let event = envelope["event"] as? String
    else {
      return
    }

    switch event {
    case "pusher:connection_established":
      sendKickSubscribe(chatroomID: chatroomID)
    case "pusher:ping":
      kickConnection.send(.string("{\"event\":\"pusher:pong\",\"data\":{}}"))
    case "pusher_internal:subscription_succeeded":
      kickStatusMessage = kickConnectedStatus()
    case let event where event.contains("ChatMessageEvent"):
      // Pusher nests the event payload as a JSON-encoded string in `data`.
      guard let payload = envelope["data"] as? String,
        let entry = parseKickMessage(payload)
      else {
        return
      }
      // A live chat message means the channel is active even if it was offline
      // when we resolved it, so promote the status to reflect that.
      if !kickResolvedIsLive {
        kickResolvedIsLive = true
        kickStatusMessage = kickConnectedStatus()
      }
      let fresh = filterAndRememberKickMessages([entry])
      if !fresh.isEmpty { enqueue(fresh) }
    default:
      break
    }
  }

  /// Status line shown once subscribed: names the resolved channel (so a wrong
  /// guess is visible) and whether it's live.
  private func kickConnectedStatus() -> String {
    let slug = kickResolvedSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let channelRef = slug.isEmpty ? "Kick chat" : "kick.com/\(slug)"
    if kickResolvedIsLive {
      return "Connected to \(channelRef) — live now."
    }
    return "Connected to \(channelRef) — currently offline."
  }

  private func sendKickSubscribe(chatroomID: Int) {
    let channel = "chatrooms.\(chatroomID).v2"
    let payload = "{\"event\":\"pusher:subscribe\",\"data\":{\"auth\":\"\",\"channel\":\"\(channel)\"}}"
    kickConnection.send(.string(payload))
    kickSubscribedChannel = channel
  }

  struct KickChannelInfo {
    let chatroomID: Int
    let slug: String
    let username: String
    let isLive: Bool
  }

  /// Fetches a Kick channel's public profile: chatroom id (needed to subscribe),
  /// the canonical slug, the display username, and whether it's currently live.
  /// Returns nil for a missing channel (HTTP 404) so callers can try the next
  /// candidate instead of spinning on backoff.
  static func fetchKickChannelInfo(slug: String) async throws -> KickChannelInfo? {
    guard let url = URL(string: "https://kick.com/api/v2/channels/\(slug)") else {
      return nil
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(kickAPIUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw KickScrapeError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      // 404 simply means there's no such channel; surface that as "not found"
      // (nil) rather than an error so we don't spin on backoff for a typo.
      if http.statusCode == 404 { return nil }
      throw KickScrapeError.httpFailure(http.statusCode)
    }

    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let chatroom = root["chatroom"] as? [String: Any],
      let id = chatroom["id"] as? Int
    else {
      return nil
    }

    let canonicalSlug = (root["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
    let username = ((root["user"] as? [String: Any])?["username"] as? String)
      .flatMap { $0.isEmpty ? nil : $0 } ?? canonicalSlug
    // `livestream` is a non-null object only while the channel is broadcasting.
    let isLive = root["livestream"] is [String: Any]

    return KickChannelInfo(
      chatroomID: id, slug: canonicalSlug, username: username, isLive: isLive)
  }

  private static let kickAPIUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

  private func filterAndRememberKickMessages(_ entries: [KickEntry]) -> [ChatMessage] {
    guard !entries.isEmpty else { return [] }

    var out: [ChatMessage] = []
    for entry in entries {
      guard !kickSeenMessageIDs.contains(entry.id) else { continue }
      kickSeenMessageIDs.insert(entry.id)
      kickSeenMessageOrder.append(entry.id)
      out.append(entry.message)
    }

    let maxSeen = 4000
    if kickSeenMessageOrder.count > maxSeen {
      let overflow = kickSeenMessageOrder.count - maxSeen
      let toRemove = kickSeenMessageOrder.prefix(overflow)
      for id in toRemove {
        kickSeenMessageIDs.remove(id)
      }
      kickSeenMessageOrder.removeFirst(overflow)
    }

    return out
  }

  private struct KickEntry {
    let id: String
    let message: ChatMessage
  }

  private enum KickScrapeError: LocalizedError {
    case invalidResponse
    case httpFailure(Int)

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        return "Kick chat response could not be parsed."
      case .httpFailure(let statusCode):
        return "Kick request failed (HTTP \(statusCode))."
      }
    }
  }

  private func parseKickMessage(_ payload: String) -> KickEntry? {
    guard let data = payload.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = root["id"] as? String,
      let rawContent = root["content"] as? String,
      let sender = root["sender"] as? [String: Any],
      let username = sender["username"] as? String,
      !username.isEmpty
    else {
      return nil
    }

    let identity = sender["identity"] as? [String: Any]
    let color = (identity?["color"] as? String).flatMap { $0.isEmpty ? nil : $0 }

    let parsed = Self.parseKickEmotes(in: rawContent)
    guard !parsed.text.isEmpty else { return nil }

    let timestamp: Date
    if let created = root["created_at"] as? String,
      let date = Self.kickDateFormatter.date(from: created)
    {
      timestamp = date
    } else {
      timestamp = Date()
    }

    let message = ChatMessage(
      kickAuthor: username,
      colorHex: color,
      text: parsed.text,
      kickEmoteURLs: parsed.emotes,
      timestamp: timestamp
    )
    return KickEntry(id: id, message: message)
  }

  /// Replace Kick's inline `[emote:<id>:<name>]` tokens with the bare `<name>`
  /// so the shared tokenizer can render them, collecting the name→CDN URL map
  /// the renderer uses (`https://files.kick.com/emotes/<id>/fullsize`).
  private static func parseKickEmotes(in content: String) -> (text: String, emotes: [String: URL]) {
    guard content.contains("[emote:") else { return (content, [:]) }

    let ns = content as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    let matches = kickEmoteRegex.matches(in: content, range: fullRange)
    guard !matches.isEmpty else { return (content, [:]) }

    var result = ""
    var emotes: [String: URL] = [:]
    var cursor = 0

    for match in matches {
      let whole = match.range
      if whole.location > cursor {
        result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
      }

      let emoteID = ns.substring(with: match.range(at: 1))
      let name = ns.substring(with: match.range(at: 2))
      result += name
      if let url = URL(string: "https://files.kick.com/emotes/\(emoteID)/fullsize") {
        emotes[name] = url
      }

      cursor = whole.location + whole.length
    }

    if cursor < ns.length {
      result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    }

    return (result, emotes)
  }

  private static let kickEmoteRegex = try! NSRegularExpression(
    pattern: "\\[emote:(\\d+):([^\\]]+)\\]")

  private static let kickDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static func extractKickSlug(from input: String) -> String? {
    var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("@") { trimmed.removeFirst() }

    // A bare handle (no scheme, path, or dot) is the slug itself.
    if !trimmed.contains("/"), !trimmed.contains("://"), !trimmed.contains(".") {
      return sanitizeKickSlug(trimmed)
    }

    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: normalized),
      let host = components.host?.lowercased(),
      host.contains("kick.com")
    else {
      return sanitizeKickSlug(trimmed)
    }

    let parts = components.path.split(separator: "/").map(String.init)
    guard let first = parts.first else { return nil }
    return sanitizeKickSlug(first)
  }

  private static func sanitizeKickSlug(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed.lowercased()
  }
}
