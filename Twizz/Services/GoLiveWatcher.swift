import Foundation
import Observation

/// Watches the signed-in viewer's followed channels and emits a `GoLiveEvent`
/// the moment one of them transitions from offline to live.
///
/// Detection is poll-and-diff rather than per-channel EventSub `stream.online`
/// subscriptions: EventSub caps how many subscriptions a session may hold, and a
/// heavy follow list would blow past that. Instead we poll Helix
/// `streams/followed` (one request, up to 100 live follows) on a fixed cadence
/// and compare the live logins against the previous snapshot. Logins that are
/// live now but weren't last time "just went live".
///
/// The service runs app-wide (Home *and* during playback) off a single shared
/// instance, so both surfaces observe the same `pending` toast and the
/// auto-dismiss countdown ticks exactly once.
@MainActor
@Observable
final class GoLiveWatcher {
  /// Public client ids we refuse to use (mirrors `FollowedChannelsService`); the
  /// Twitch web client can't reliably authorize followed-channel endpoints.
  private static let disallowedClientIDs: Set<String> = [
    "kimne78kx3ncx6brgo4mv6wki5h1ko"
  ]

  /// How often we re-poll followed streams. ~60s keeps "the moment it starts"
  /// honest without hammering Helix.
  private static let pollInterval: Duration = .seconds(60)

  /// How long a toast stays up before it auto-dismisses, unless the viewer
  /// focuses its button (which pauses the countdown).
  private static let toastSeconds = 10

  /// The toast currently on screen, or `nil` when nothing is showing.
  private(set) var pending: GoLiveEvent?

  /// Seconds left before `pending` auto-dismisses; drives the countdown label.
  private(set) var secondsRemaining = 0

  /// Channel the viewer is actively watching (lowercased). We never toast it —
  /// you're already there — and we drop a queued toast if you switch onto it.
  var suppressedLogin: String? {
    didSet {
      guard let suppressedLogin else { return }
      let login = suppressedLogin.lowercased()
      queue.removeAll { $0.login == login }
      if pending?.login == login { advance() }
    }
  }

  /// Logins known live as of the last successful poll. Seeded on the first poll
  /// so channels already live at launch don't all toast at once.
  private var knownLiveLogins: Set<String> = []
  private var hasBaseline = false

  /// Pending go-lives not yet shown, so a burst of simultaneous starts surfaces
  /// one toast at a time instead of clobbering each other.
  private var queue: [GoLiveEvent] = []

  private var pollTask: Task<Void, Never>?
  private var dismissTask: Task<Void, Never>?

  /// Begin polling on behalf of `auth`. Replaces any existing watch. A no-op
  /// (after teardown) cadence keeps running and simply skips work while the
  /// viewer is signed out, so it resumes automatically after sign-in.
  func start(using auth: TwitchAuthSession) {
    stop()
    pollTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.poll(using: auth)
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  /// Stop polling and clear all transient state.
  func stop() {
    pollTask?.cancel()
    pollTask = nil
    dismissTask?.cancel()
    dismissTask = nil
    queue.removeAll()
    pending = nil
    secondsRemaining = 0
    knownLiveLogins = []
    hasBaseline = false
  }

  /// The viewer chose to act on the current toast. Returns its login (so the
  /// caller can navigate) and advances to any queued go-live.
  @discardableResult
  func watch() -> String? {
    guard let login = pending?.login else { return nil }
    advance()
    return login
  }

  /// Dismiss the current toast without acting; surfaces the next queued one.
  func dismissCurrent() {
    advance()
  }

  /// Debug-only: inject a simulated go-live so the toast, auto-dismiss, and
  /// "Watch" switch can be exercised without waiting for a real follow to start.
  /// Targets a near-24/7 channel (Monstercat) so "Watch" lands on a genuinely
  /// live stream.
  func simulateGoLive() {
    enqueue(GoLiveEvent(login: "monstercat", displayName: "Monstercat", gameName: "Music"))
  }

  // MARK: - Polling

  private func poll(using auth: TwitchAuthSession) async {
    guard auth.isAuthenticated, let userID = auth.userID,
          let clientID = resolveClientID(),
          !Self.disallowedClientIDs.contains(clientID.lowercased())
    else {
      // Signed out / unusable client: reset the baseline so the next authorized
      // poll doesn't treat the whole live follow list as fresh go-lives.
      hasBaseline = false
      knownLiveLogins = []
      return
    }

    guard let token = await accessToken(auth: auth) else { return }

    let streams: [GoLiveStream]
    do {
      streams = try await fetchFollowedStreams(clientID: clientID, accessToken: token, userID: userID)
    } catch let error as GoLiveRequestError where error.status == 401 {
      // Token likely expired mid-session: force a refresh and retry once.
      guard let refreshed = try? await auth.refreshAccessTokenIfNeeded(force: true),
            let retry = try? await fetchFollowedStreams(
              clientID: clientID, accessToken: refreshed, userID: userID)
      else { return }
      streams = retry
    } catch {
      // Transient failure: keep the last baseline so a blip doesn't spam toasts.
      return
    }

    let liveStreams = streams.filter { $0.type == "live" }
    let liveLogins = Set(liveStreams.map { $0.userLogin.lowercased() })

    guard hasBaseline else {
      knownLiveLogins = liveLogins
      hasBaseline = true
      return
    }

    let newlyLive = liveLogins.subtracting(knownLiveLogins)
    knownLiveLogins = liveLogins
    guard !newlyLive.isEmpty else { return }

    let suppressed = suppressedLogin?.lowercased()
    let events = liveStreams
      .filter { newlyLive.contains($0.userLogin.lowercased()) }
      .filter { $0.userLogin.lowercased() != suppressed }
      .map {
        GoLiveEvent(
          login: $0.userLogin.lowercased(),
          displayName: $0.userName.isEmpty ? $0.userLogin : $0.userName,
          gameName: $0.gameName
        )
      }

    for event in events { enqueue(event) }
  }

  private func accessToken(auth: TwitchAuthSession) async -> String? {
    if let token = auth.accessToken { return token }
    return try? await auth.refreshAccessTokenIfNeeded(force: true)
  }

  private func fetchFollowedStreams(clientID: String, accessToken: String, userID: String)
    async throws -> [GoLiveStream]
  {
    var components = URLComponents(string: "https://api.twitch.tv/helix/streams/followed")!
    components.queryItems = [
      URLQueryItem(name: "user_id", value: userID),
      URLQueryItem(name: "first", value: "100"),
    ]

    var req = URLRequest(url: components.url!)
    req.httpMethod = "GET"
    req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(clientID, forHTTPHeaderField: "Client-Id")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Twizz/0.1 tvOS", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      throw GoLiveRequestError(status: status)
    }
    return try JSONDecoder().decode(GoLiveStreamsEnvelope.self, from: data).data
  }

  private func resolveClientID() -> String? {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_CLIENT_ID") as? String else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !trimmed.contains("TWITCH_CLIENT_ID") else {
      return nil
    }
    return trimmed
  }

  // MARK: - Queue / countdown

  private func enqueue(_ event: GoLiveEvent) {
    // Collapse duplicates: a channel already showing/queued shouldn't stack.
    guard pending?.login != event.login, !queue.contains(where: { $0.login == event.login })
    else { return }

    if pending == nil {
      present(event)
    } else {
      queue.append(event)
    }
  }

  private func advance() {
    dismissTask?.cancel()
    dismissTask = nil
    if queue.isEmpty {
      pending = nil
      secondsRemaining = 0
    } else {
      present(queue.removeFirst())
    }
  }

  private func present(_ event: GoLiveEvent) {
    pending = event
    secondsRemaining = Self.toastSeconds
    startDismissCountdown()
  }

  private func startDismissCountdown() {
    dismissTask?.cancel()
    dismissTask = Task { [weak self] in
      guard let self else { return }
      while self.secondsRemaining > 0 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.secondsRemaining -= 1
      }
      guard !Task.isCancelled else { return }
      self.advance()
    }
  }
}

private struct GoLiveRequestError: Error {
  let status: Int
}

private struct GoLiveStreamsEnvelope: Decodable {
  let data: [GoLiveStream]
}

private struct GoLiveStream: Decodable {
  let userLogin: String
  let userName: String
  let gameName: String
  let type: String

  private enum CodingKeys: String, CodingKey {
    case userLogin = "user_login"
    case userName = "user_name"
    case gameName = "game_name"
    case type
  }
}
