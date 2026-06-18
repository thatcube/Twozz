import Foundation
import Observation

/// An *outgoing* raid: the channel the user is currently watching is raiding
/// `toLogin`. Detected via EventSub `channel.raid` (never delivered over IRC to
/// the source channel), so it drives the "follow the raid" redirect.
struct OutgoingRaidEvent: Equatable {
  let toLogin: String
  let toDisplayName: String
  let toBroadcasterID: String
  let viewerCount: Int
}

/// Listens for *outgoing* raids from the channel being watched via Twitch
/// EventSub over a WebSocket.
///
/// Twitch only delivers the `channel.raid` USERNOTICE to the raid *target* over
/// IRC, so the source channel's chat shows nothing when it raids away. To learn
/// that the channel you're watching is raiding someone, we open the EventSub
/// WebSocket (`wss://eventsub.wss.twitch.tv/ws`), and on `session_welcome`
/// create a `channel.raid` subscription filtered by `from_broadcaster_user_id`.
/// This needs a signed-in user access token (no special scope); when signed out
/// the service is a no-op.
@MainActor
@Observable
final class EventSubService {
  /// Set when an outgoing raid notification arrives. The consumer follows it and
  /// then clears this value.
  var pendingOutgoingRaid: OutgoingRaidEvent?

  private let endpoint = URL(string: "wss://eventsub.wss.twitch.tv/ws")!

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  /// Login of the broadcaster we're currently subscribed to (lowercased).
  private var channelLogin: String?
  /// Numeric id of that broadcaster, resolved lazily.
  private var fromBroadcasterID: String?
  /// EventSub websocket session id from `session_welcome`.
  private var sessionID: String?
  /// Id of the `channel.raid` subscription we created, for cleanup.
  private var subscriptionID: String?
  /// Credentials captured for the active session (cleared on stop).
  private var credentials: TwitchEventSubCredentials?

  /// Whether a `channel.raid` subscription has been created for the current
  /// session. Reset across reconnects, since a brand-new session needs it again
  /// only when the welcome arrives on a fresh (non-reconnect) connection.
  private var hasCreatedSubscription = false

  /// Begin listening for outgoing raids from `login`. Replaces any existing
  /// listener. No-ops (after teardown) when the user isn't signed in.
  func start(forChannel login: String, auth: TwitchAuthSession) {
    stop()

    guard let creds = auth.eventSubCredentials else {
      // Not signed in: EventSub requires a user token. Stay a no-op.
      return
    }

    let normalized = login.lowercased()
    channelLogin = normalized
    credentials = creds

    let task = URLSession(configuration: .default).webSocketTask(with: endpoint)
    socket = task
    task.resume()

    // Resolve the numeric broadcaster id up front so the subscription can be
    // created immediately when the welcome frame arrives.
    Task { [weak self] in
      guard let self else { return }
      let resolved = try? await auth.broadcasterID(forLogin: normalized)
      guard self.channelLogin == normalized else { return }
      self.fromBroadcasterID = resolved
      await self.createSubscriptionIfReady()
    }

    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  /// Tear down the connection and best-effort delete the subscription.
  func stop() {
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil

    // Best-effort: drop the subscription so Twitch doesn't keep a dangling one.
    if let subscriptionID, let credentials {
      let id = subscriptionID
      let creds = credentials
      Task { await Self.deleteSubscription(id: id, credentials: creds) }
    }

    channelLogin = nil
    fromBroadcasterID = nil
    sessionID = nil
    subscriptionID = nil
    credentials = nil
    hasCreatedSubscription = false
    pendingOutgoingRaid = nil
  }

  // MARK: - Receive loop

  private func receiveLoop() async {
    while !Task.isCancelled {
      guard let currentSocket = socket else { break }
      do {
        let frame = try await currentSocket.receive()
        switch frame {
        case .string(let text): handle(text)
        case .data(let data): handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        guard !Task.isCancelled else { break }
        // Reconnect after a brief pause, preserving the target channel. A fresh
        // session requires recreating the subscription on the next welcome.
        guard let login = channelLogin else { break }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, channelLogin == login else { break }

        socket?.cancel(with: .goingAway, reason: nil)
        let newTask = URLSession(configuration: .default).webSocketTask(with: endpoint)
        socket = newTask
        sessionID = nil
        subscriptionID = nil
        hasCreatedSubscription = false
        newTask.resume()
        // Loop continues — next iteration receives on the new socket.
      }
    }
  }

  private func handle(_ raw: String) {
    guard let data = raw.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(EventSubEnvelope.self, from: data) else {
      return
    }

    switch envelope.metadata.messageType {
    case "session_welcome":
      guard let session = envelope.payload?.session else { return }
      sessionID = session.id
      Task { [weak self] in await self?.createSubscriptionIfReady() }

    case "session_reconnect":
      // Twitch hands us a new URL; the existing subscriptions carry over, so we
      // only need to re-open the socket — no re-subscription.
      guard let urlString = envelope.payload?.session?.reconnectURL,
            let url = URL(string: urlString) else { return }
      reconnect(to: url)

    case "session_keepalive":
      break

    case "revocation":
      // Subscription was revoked (e.g. token invalidated); drop our handle.
      subscriptionID = nil
      hasCreatedSubscription = false

    case "notification":
      guard envelope.metadata.subscriptionType == "channel.raid",
            let raid = envelope.payload?.event else { return }
      // Guard against stray events: only react to raids *from* the channel we're
      // watching.
      if let from = fromBroadcasterID,
         let eventFrom = raid.fromBroadcasterUserID,
         eventFrom != from {
        return
      }
      guard let toLogin = raid.toBroadcasterUserLogin, !toLogin.isEmpty else { return }
      pendingOutgoingRaid = OutgoingRaidEvent(
        toLogin: toLogin,
        toDisplayName: raid.toBroadcasterUserName ?? toLogin,
        toBroadcasterID: raid.toBroadcasterUserID ?? "",
        viewerCount: raid.viewers ?? 0
      )

    default:
      break
    }
  }

  private func reconnect(to url: URL) {
    receiveTask?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    let newTask = URLSession(configuration: .default).webSocketTask(with: url)
    socket = newTask
    newTask.resume()
    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  // MARK: - Subscription management

  /// Create the `channel.raid` subscription once both the welcome session id and
  /// the resolved broadcaster id are available.
  private func createSubscriptionIfReady() async {
    guard !hasCreatedSubscription,
          let sessionID,
          let fromBroadcasterID,
          let credentials else {
      return
    }
    hasCreatedSubscription = true

    do {
      let id = try await Self.createRaidSubscription(
        fromBroadcasterID: fromBroadcasterID,
        sessionID: sessionID,
        credentials: credentials
      )
      // The channel may have changed while the request was in flight.
      if hasCreatedSubscription {
        subscriptionID = id
      } else {
        await Self.deleteSubscription(id: id, credentials: credentials)
      }
    } catch {
      // Allow a later welcome/reconnect to retry.
      hasCreatedSubscription = false
    }
  }

  private nonisolated static func createRaidSubscription(
    fromBroadcasterID: String,
    sessionID: String,
    credentials: TwitchEventSubCredentials
  ) async throws -> String {
    var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/eventsub/subscriptions")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(credentials.clientID, forHTTPHeaderField: "Client-Id")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
      "type": "channel.raid",
      "version": "1",
      "condition": ["from_broadcaster_user_id": fromBroadcasterID],
      "transport": ["method": "websocket", "session_id": sessionID],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      throw EventSubError.subscriptionFailed(status: status)
    }

    let payload = try JSONDecoder().decode(EventSubSubscriptionEnvelope.self, from: data)
    guard let id = payload.data.first?.id else {
      throw EventSubError.subscriptionFailed(status: status)
    }
    return id
  }

  private nonisolated static func deleteSubscription(
    id: String,
    credentials: TwitchEventSubCredentials
  ) async {
    var components = URLComponents(string: "https://api.twitch.tv/helix/eventsub/subscriptions")!
    components.queryItems = [URLQueryItem(name: "id", value: id)]
    guard let url = components.url else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(credentials.clientID, forHTTPHeaderField: "Client-Id")
    _ = try? await URLSession.shared.data(for: req)
  }
}

private enum EventSubError: Error {
  case subscriptionFailed(status: Int)
}

// MARK: - Wire models

private struct EventSubEnvelope: Decodable {
  let metadata: Metadata
  let payload: Payload?

  struct Metadata: Decodable {
    let messageType: String
    let subscriptionType: String?

    private enum CodingKeys: String, CodingKey {
      case messageType = "message_type"
      case subscriptionType = "subscription_type"
    }
  }

  struct Payload: Decodable {
    let session: Session?
    let event: RaidEventPayload?
  }

  struct Session: Decodable {
    let id: String?
    let reconnectURL: String?

    private enum CodingKeys: String, CodingKey {
      case id
      case reconnectURL = "reconnect_url"
    }
  }

  struct RaidEventPayload: Decodable {
    let fromBroadcasterUserID: String?
    let toBroadcasterUserID: String?
    let toBroadcasterUserLogin: String?
    let toBroadcasterUserName: String?
    let viewers: Int?

    private enum CodingKeys: String, CodingKey {
      case fromBroadcasterUserID = "from_broadcaster_user_id"
      case toBroadcasterUserID = "to_broadcaster_user_id"
      case toBroadcasterUserLogin = "to_broadcaster_user_login"
      case toBroadcasterUserName = "to_broadcaster_user_name"
      case viewers
    }
  }
}

private struct EventSubSubscriptionEnvelope: Decodable {
  let data: [Subscription]

  struct Subscription: Decodable {
    let id: String
  }
}
