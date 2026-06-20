import Foundation
import Observation

// MARK: - Public moment models

/// A live poll running on the watched channel.
struct LivePoll: Equatable, Identifiable {
  struct Choice: Equatable, Identifiable {
    let id: String
    let title: String
    let votes: Int
  }
  let id: String
  let title: String
  let choices: [Choice]
  let isActive: Bool

  var totalVotes: Int { choices.reduce(0) { $0 + $1.votes } }
  /// Leading choice fraction 0…1 (for a progress bar). Zero when no votes yet.
  func fraction(of choice: Choice) -> Double {
    totalVotes > 0 ? Double(choice.votes) / Double(totalVotes) : 0
  }
}

/// A live Channel-Points prediction on the watched channel.
struct LivePrediction: Equatable, Identifiable {
  enum Status: Equatable { case active, locked, resolved, canceled }
  struct Outcome: Equatable, Identifiable {
    let id: String
    let title: String
    /// Twitch outcome color, "BLUE" or "PINK".
    let color: String
    let points: Int
    let users: Int
  }
  let id: String
  let title: String
  let outcomes: [Outcome]
  let status: Status
  let winningOutcomeID: String?

  var totalPoints: Int { outcomes.reduce(0) { $0 + $1.points } }
  var isActive: Bool { status == .active || status == .locked }
  func fraction(of outcome: Outcome) -> Double {
    totalPoints > 0 ? Double(outcome.points) / Double(totalPoints) : 0
  }
}

/// A creator goal (followers/subs/etc.) on the watched channel.
struct LiveGoal: Equatable, Identifiable {
  let id: String
  let description: String
  /// FOLLOWERS, SUBSCRIPTIONS, NEW_SUBSCRIPTIONS, …
  let contributionType: String
  let current: Int
  let target: Int

  var fraction: Double {
    target > 0 ? min(1, Double(current) / Double(target)) : 0
  }
  /// Human label for the kind of goal, e.g. "Follower goal".
  var kindLabel: String {
    switch contributionType.uppercased() {
    case let t where t.contains("FOLLOW"): return "Follower goal"
    case let t where t.contains("SUB"): return "Sub goal"
    default: return "Goal"
    }
  }
}

/// A live Hype Train on the watched channel.
struct LiveHypeTrain: Equatable, Identifiable {
  /// Where the train is in its lifecycle. `approaching` is the pre-start window
  /// where contributions are building toward kicking the train off; `active` is
  /// a running train climbing levels; `completed` is the brief post-end state.
  enum Phase: Equatable { case approaching, active, completed }

  let id: String
  /// The train's level, when known. Nil when an event (notably the end event)
  /// arrives without a level and we never saw one — we'd rather show no level
  /// than a misleading "Level 1".
  let level: Int?
  /// Points toward the *current* level's goal (not the cumulative train total).
  let progress: Int
  let goal: Int
  let phase: Phase
  /// When the current level (or the approaching window) runs out, if known.
  let expiresAt: Date?

  var isActive: Bool { phase == .active }

  var fraction: Double {
    goal > 0 ? min(1, Double(progress) / Double(goal)) : 0
  }
}

/// The single highest-priority interactive moment to surface right now.
enum InteractiveMoment: Equatable {
  case prediction(LivePrediction)
  case poll(LivePoll)
  case hypeTrain(LiveHypeTrain)
  case goal(LiveGoal)
}

// MARK: - Service

/// Passively surfaces live polls, predictions, hype trains, creator goals and
/// the live viewer count for the channel being watched, so couch viewers don't
/// miss interactive moments and can see how many people are watching alongside
/// them.
///
/// Transport is Twitch's private "Hermes" WebSocket
/// (`wss://hermes.twitch.tv/v1`) — the same undocumented surface
/// `PlaybackService` already uses for playback. These channel-public topics are
/// readable anonymously (the website shows them to every viewer), so this works
/// signed out and for *any* channel — unlike the official EventSub poll/
/// prediction subscriptions, which require the broadcaster's own authorization.
///
/// Read-only: there is no public (or private, low-risk) viewer API to *vote*, so
/// this never writes.
@MainActor
@Observable
final class HermesEventService {
  /// The single moment to display, chosen by priority. Nil when nothing is live.
  private(set) var currentMoment: InteractiveMoment?

  /// Live viewer count for the watched channel, pushed by Twitch's
  /// `video-playback-by-id` topic (~every 20-30s). Nil until the first update
  /// arrives (or after `stop()`); the player seeds an initial value from channel
  /// metadata so a number shows immediately on open.
  private(set) var viewerCount: Int?

  // Per-kind displayable state (drives `currentMoment` via `recompute()`).
  private var poll: LivePoll?
  private var prediction: LivePrediction?
  private var hypeTrain: LiveHypeTrain?
  private var goal: LiveGoal?

  // MARK: Tunables
  private static let endedGrace: Duration = .seconds(8)
  private static let goalDwell: Duration = .seconds(10)

  // MARK: Connection state
  private let endpoint = URL(
    string: "wss://hermes.twitch.tv/v1?clientId=kimne78kx3ncx6brgo4mv6wki5h1ko")!
  private static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  /// Shared WebSocket transport: owns the reused `URLSession`, the socket task,
  /// and the exponential-backoff counter.
  private let connection = WebSocketConnection()
  private var receiveTask: Task<Void, Never>?
  private var channelLogin: String?
  private var broadcasterID: String?
  private var hasSubscribed = false

  // Lifecycle timers.
  private var pollClearTask: Task<Void, Never>?
  private var predictionClearTask: Task<Void, Never>?
  private var hypeTrainClearTask: Task<Void, Never>?
  private var goalClearTask: Task<Void, Never>?
  /// Goal ids already surfaced this session — goals are ambient, so we show each
  /// once briefly rather than pinning it while it streams continuous updates.
  private var shownGoalIDs: Set<String> = []

  // MARK: - Public API

  /// Begin surfacing moments for `login`. Replaces any existing listener.
  func start(forChannel login: String) {
    stop()
    let normalized = login.lowercased()
    channelLogin = normalized

    connection.resetBackoff()
    connection.connect(to: endpoint)

    Task { [weak self] in
      guard let self else { return }
      let resolved = try? await Self.resolveBroadcasterID(login: normalized)
      guard self.channelLogin == normalized else { return }
      self.broadcasterID = resolved
      self.subscribeIfReady()
    }

    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  /// Tear down the connection and clear all surfaced state.
  func stop() {
    receiveTask?.cancel()
    receiveTask = nil
    connection.cancel()

    pollClearTask?.cancel()
    predictionClearTask?.cancel()
    hypeTrainClearTask?.cancel()
    goalClearTask?.cancel()

    channelLogin = nil
    broadcasterID = nil
    hasSubscribed = false
    shownGoalIDs.removeAll()
    poll = nil
    prediction = nil
    hypeTrain = nil
    goal = nil
    viewerCount = nil
    currentMoment = nil
  }

  /// Seed an initial viewer count from channel metadata so the player shows a
  /// number immediately on open. Ignored once a live pubsub `viewcount` update
  /// has arrived, so the authoritative live value is never overwritten.
  func seedViewerCount(_ count: Int?) {
    guard let count, viewerCount == nil else { return }
    viewerCount = count
  }

  // MARK: - Receive loop

  private func receiveLoop() async {
    while !Task.isCancelled {
      guard let currentSocket = connection.currentTask else { break }
      do {
        let frame = try await currentSocket.receive()
        connection.resetBackoff()
        switch frame {
        case .string(let text): handle(text)
        case .data(let data): handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        guard !Task.isCancelled, let login = channelLogin else { break }
        let delay = connection.nextBackoffDelay()
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, channelLogin == login else { break }

        connection.connect(to: endpoint)
        hasSubscribed = false
        // Re-subscribe once the new connection's welcome arrives.
      }
    }
  }

  private func handle(_ raw: String) {
    guard let data = raw.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String
    else { return }

    switch type {
    case "welcome":
      subscribeIfReady()
    case "reconnect":
      reconnect()
    case "notification":
      guard let pubsub = (obj["notification"] as? [String: Any])?["pubsub"] as? String,
        let payloadData = pubsub.data(using: .utf8),
        let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
      else { return }
      route(payload)
    default:
      break  // keepalive, subscribeResponse, authenticateResponse
    }
  }

  private func reconnect() {
    receiveTask?.cancel()
    connection.connect(to: endpoint)
    hasSubscribed = false
    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  // MARK: - Subscriptions

  private static let topicTemplates: [String] = [
    "polls.%@",
    "predictions-channel-v1.%@",
    "hype-train-events-v2.%@",
    "creator-goals-events-v1.%@",
    "video-playback-by-id.%@",
  ]

  private func subscribeIfReady() {
    guard !hasSubscribed, connection.isOpen, let id = broadcasterID else { return }
    hasSubscribed = true
    for template in Self.topicTemplates {
      let topic = template.replacingOccurrences(of: "%@", with: id)
      let frame: [String: Any] = [
        "type": "subscribe",
        "id": "twizz-\(Self.randomID())",
        "subscribe": [
          "id": "twizz-\(Self.randomID())",
          "type": "pubsub",
          "pubsub": ["topic": topic],
        ],
        "timestamp": Self.isoFractional.string(from: Date()),
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: frame),
        let text = String(data: data, encoding: .utf8)
      else { continue }
      connection.send(.string(text))
    }
  }

  // MARK: - Payload routing

  private func route(_ payload: [String: Any]) {
    // `video-playback-by-id` pushes top-level typed messages (viewcount,
    // stream-up/down, commercial); we only surface the live viewer count.
    if let type = payload["type"] as? String, type == "viewcount" {
      applyViewCount(payload)
      return
    }
    let data = payload["data"] as? [String: Any]
    if let pollDict = data?["poll"] as? [String: Any] {
      applyPoll(pollDict)
    } else if let eventDict = data?["event"] as? [String: Any],
      eventDict["outcomes"] != nil
    {
      applyPrediction(eventDict)
    } else if let goalDict = data?["goal"] as? [String: Any] {
      applyGoal(goalDict)
    } else if let type = payload["type"] as? String, type.contains("hype-train") {
      applyHypeTrain(payload)
    }
  }

  // MARK: Viewer count

  private func applyViewCount(_ payload: [String: Any]) {
    guard let viewers = Self.intValue(payload["viewers"]) else { return }
    viewerCount = viewers
  }

  // MARK: Poll

  private func applyPoll(_ dict: [String: Any]) {
    let id = (dict["poll_id"] as? String) ?? (dict["id"] as? String) ?? ""
    let title = (dict["title"] as? String) ?? "Poll"
    let status = ((dict["status"] as? String) ?? "ACTIVE").uppercased()
    let choices: [LivePoll.Choice] = (dict["choices"] as? [[String: Any]] ?? []).map { c in
      let cid = (c["choice_id"] as? String) ?? (c["id"] as? String) ?? UUID().uuidString
      let ctitle = (c["title"] as? String) ?? ""
      let votes = Self.intValue((c["votes"] as? [String: Any])?["total"]) ?? Self.intValue(c["total_voters"]) ?? 0
      return LivePoll.Choice(id: cid, title: ctitle, votes: votes)
    }
    let active = status == "ACTIVE" || status == "STARTED"
    poll = LivePoll(id: id, title: title, choices: choices, isActive: active)

    pollClearTask?.cancel()
    if active {
      pollClearTask = nil
    } else {
      pollClearTask = Task { [weak self] in
        try? await Task.sleep(for: Self.endedGrace)
        guard !Task.isCancelled else { return }
        self?.poll = nil
        self?.recompute()
      }
    }
    recompute()
  }

  // MARK: Prediction

  private func applyPrediction(_ dict: [String: Any]) {
    let id = (dict["id"] as? String) ?? ""
    let title = (dict["title"] as? String) ?? "Prediction"
    let rawStatus = ((dict["status"] as? String) ?? "ACTIVE").uppercased()
    let status: LivePrediction.Status
    switch rawStatus {
    case "LOCKED": status = .locked
    case "RESOLVED", "RESOLVE_PENDING": status = .resolved
    case "CANCELED", "CANCEL_PENDING": status = .canceled
    default: status = .active
    }
    let winning = dict["winning_outcome_id"] as? String
    let outcomes: [LivePrediction.Outcome] = (dict["outcomes"] as? [[String: Any]] ?? []).map { o in
      LivePrediction.Outcome(
        id: (o["id"] as? String) ?? UUID().uuidString,
        title: (o["title"] as? String) ?? "",
        color: ((o["color"] as? String) ?? "BLUE").uppercased(),
        points: Self.intValue(o["total_points"]) ?? 0,
        users: Self.intValue(o["total_users"]) ?? 0)
    }
    let value = LivePrediction(
      id: id, title: title, outcomes: outcomes, status: status, winningOutcomeID: winning)
    prediction = value

    predictionClearTask?.cancel()
    if value.isActive {
      predictionClearTask = nil
    } else {
      predictionClearTask = Task { [weak self] in
        try? await Task.sleep(for: Self.endedGrace)
        guard !Task.isCancelled else { return }
        self?.prediction = nil
        self?.recompute()
      }
    }
    recompute()
  }

  // MARK: Goal (ambient: surface each id once, briefly)

  private func applyGoal(_ dict: [String: Any]) {
    let id = (dict["id"] as? String) ?? ""
    let state = ((dict["state"] as? String) ?? "ACTIVE").uppercased()
    guard state == "ACTIVE", !id.isEmpty, !shownGoalIDs.contains(id) else { return }
    shownGoalIDs.insert(id)

    let current = Self.intValue(dict["currentContributions"]) ?? Self.intValue(dict["current_contributions"]) ?? 0
    let target = Self.intValue(dict["targetContributions"]) ?? Self.intValue(dict["target_contributions"]) ?? 0
    guard target > 0 else { return }
    goal = LiveGoal(
      id: id,
      description: (dict["description"] as? String) ?? "",
      contributionType: (dict["contributionType"] as? String) ?? (dict["contribution_type"] as? String) ?? "",
      current: current,
      target: target)
    recompute()

    goalClearTask?.cancel()
    goalClearTask = Task { [weak self] in
      try? await Task.sleep(for: Self.goalDwell)
      guard !Task.isCancelled else { return }
      self?.goal = nil
      self?.recompute()
    }
  }

  // MARK: Hype train (best-effort; tolerant of v2 schema variance)

  private func applyHypeTrain(_ payload: [String: Any]) {
    let type = (payload["type"] as? String ?? "").lowercased()
    let data = payload["data"] as? [String: Any] ?? payload

    // v2 nests progress under various keys; probe the common ones.
    let progressDict =
      (data["progress"] as? [String: Any]) ?? (data["hype_train"] as? [String: Any]) ?? data
    let levelDict = progressDict["level"] as? [String: Any]

    // The end event doesn't carry the progress/level block that progression
    // events do, so fall back to the level we last saw. Stays nil if we never
    // saw one, so a completed train reads plainly "ended" rather than a
    // misleading "Level 1".
    let level = Self.intValue(progressDict["level"]) ?? Self.intValue(levelDict?["value"]) ?? hypeTrain?.level
    // Progress toward the *current level* — `value` (v2 nested) or `progress`
    // (v1 flat). Deliberately NOT `total`, which is the cumulative train score
    // and would peg the bar at 100% once past level one.
    let levelProgress =
      Self.intValue(progressDict["value"]) ?? Self.intValue(progressDict["progress"]) ?? 0
    let goalValue =
      Self.intValue(progressDict["goal"]) ?? Self.intValue(levelDict?["goal"]) ?? 0
    let id = (data["id"] as? String) ?? "hype-train"

    let approaching = type.contains("approach")
    let ended = type.contains("end") || type.contains("complete")

    let expiresAt =
      Self.parseDate(progressDict["expires_at"] ?? data["expires_at"])
      ?? Self.remainingDate(progressDict["remaining_seconds"] ?? data["remaining_seconds"])

    guard goalValue > 0 || ended || approaching else { return }

    let phase: LiveHypeTrain.Phase = ended ? .completed : (approaching ? .approaching : .active)
    hypeTrain = LiveHypeTrain(
      id: id,
      level: level,
      progress: levelProgress,
      goal: max(goalValue, levelProgress),
      phase: phase,
      expiresAt: ended ? nil : expiresAt)

    hypeTrainClearTask?.cancel()
    switch phase {
    case .completed:
      hypeTrainClearTask = Task { [weak self] in
        try? await Task.sleep(for: Self.endedGrace)
        guard !Task.isCancelled else { return }
        self?.hypeTrain = nil
        self?.recompute()
      }
    case .approaching:
      // An approaching train that never starts should dismiss itself once its
      // window lapses, rather than hang as a permanent "incoming" banner.
      if let expiresAt {
        let delay = max(0, expiresAt.timeIntervalSinceNow) + Double(Self.endedGrace.components.seconds)
        hypeTrainClearTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(delay))
          guard !Task.isCancelled else { return }
          self?.hypeTrain = nil
          self?.recompute()
        }
      } else {
        hypeTrainClearTask = nil
      }
    case .active:
      hypeTrainClearTask = nil
    }
    recompute()
  }

  // MARK: - Priority

  /// Choose the single highest-priority moment: an active prediction or poll is
  /// the most time-sensitive, then hype train, then an ambient goal.
  private func recompute() {
    let next: InteractiveMoment?
    if let prediction {
      next = .prediction(prediction)
    } else if let poll {
      next = .poll(poll)
    } else if let hypeTrain {
      next = .hypeTrain(hypeTrain)
    } else if let goal {
      next = .goal(goal)
    } else {
      next = nil
    }
    if next != currentMoment { currentMoment = next }
  }

  // MARK: - Helpers

  private static func intValue(_ any: Any?) -> Int? {
    switch any {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let s as String: return Int(s)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
  }

  private static let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// Parse an ISO8601 timestamp. Twitch sends up to nine fractional-second
  /// digits, which `ISO8601DateFormatter` rejects, so we cap them to three.
  private static func parseDate(_ any: Any?) -> Date? {
    guard let raw = any as? String, !raw.isEmpty else { return nil }
    let s = capFractionalSeconds(raw)
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
  }

  private static func capFractionalSeconds(_ s: String) -> String {
    guard let dot = s.firstIndex(of: ".") else { return s }
    let firstFraction = s.index(after: dot)
    var end = firstFraction
    while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
    let capped = s[firstFraction..<end].prefix(3)
    return String(s[..<firstFraction]) + capped + String(s[end...])
  }

  /// Turn a `remaining_seconds` countdown into an absolute expiry instant.
  private static func remainingDate(_ any: Any?) -> Date? {
    guard let secs = intValue(any), secs > 0 else { return nil }
    return Date().addingTimeInterval(TimeInterval(secs))
  }

  private static func randomID(_ length: Int = 20) -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<length).map { _ in chars.randomElement()! })
  }

  /// Resolve a channel login to its numeric id anonymously via Twitch's private
  /// GraphQL (works signed out, same surface as playback).
  private static func resolveBroadcasterID(login: String) async throws -> String {
    var req = TwitchAPIClient.graphQLRequest(
      clientID: webClientID, clientIDField: "Client-ID", userAgent: userAgent)
    req.httpBody = try JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(
        query: "query($login:String!){user(login:$login){id}}", variables: ["login": login]))

    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dataObj = json["data"] as? [String: Any],
      let user = dataObj["user"] as? [String: Any],
      let id = user["id"] as? String
    else { throw HermesError.resolveFailed }
    return id
  }
}

private enum HermesError: Error { case resolveFailed }

extension HermesEventService {
  /// Debug-only: force a sample moment so the overlay can be exercised on-device
  /// without waiting for a broadcaster to run a real poll/prediction. Pass `nil`
  /// to clear. Stops the live listener so a real event can't immediately replace
  /// the sample.
  func debugInject(_ moment: InteractiveMoment?) {
    stop()
    currentMoment = moment
  }
}
