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
    TwitchConfig.webPublicClientID
  ]

  /// How often we re-poll followed streams. ~60s keeps "the moment it starts"
  /// honest without hammering Helix.
  private static let pollInterval: Duration = .seconds(60)

  /// Ceiling for the exponential backoff applied after consecutive poll
  /// failures, so a sustained Helix/network outage doesn't retry every 60s.
  private static let maxPollBackoff: Double = 600

  /// Consecutive failed polls, for exponential backoff. Reset on any successful
  /// (or idle / signed-out) poll.
  private var consecutivePollFailures = 0

  /// Reused across poll iterations so the 60s loop doesn't build a decoder per
  /// request.
  private nonisolated(unsafe) static let decoder = JSONDecoder()

  /// How long a toast stays up before it auto-dismisses, unless the viewer
  /// focuses its button (which pauses the countdown).
  private static let toastSeconds = 15

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

  /// Viewer's go-live alert preferences (master switch + per-channel mutes). When
  /// unset, every go-live alerts (the default). Owned by `HomeView`.
  weak var notificationSettings: GoLiveNotificationSettings?

  /// Whether a toast for `login` is currently allowed: no settings means allow,
  /// otherwise defer to the master switch and per-channel mute list.
  private func isAlerting(login: String) -> Bool {
    notificationSettings?.isAlerting(login: login) ?? true
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

  /// Auth captured by the active watch, so debug helpers can resolve metadata
  /// (e.g. avatars) on demand. Weak: `HomeView` owns the session.
  private weak var auth: TwitchAuthSession?

  /// Begin polling on behalf of `auth`. Replaces any existing watch. A no-op
  /// (after teardown) cadence keeps running and simply skips work while the
  /// viewer is signed out, so it resumes automatically after sign-in.
  ///
  /// The poll loop is intentionally *always on* while the app is foreground —
  /// Home, Browse, and during playback — because a go-live toast must be able to
  /// surface no matter where the viewer is in the app. We deliberately do not
  /// gate it on `scenePhase`: one Helix `streams/followed` request per minute is
  /// negligible, and tvOS suspends the app (and this `Task.sleep` loop) on its
  /// own when it goes to the background, so there's nothing to hand-tune there.
  /// (Per-channel EventSub `stream.online` would avoid polling entirely but caps
  /// subscriptions below a large follow list — see the type doc above.)
  func start(using auth: TwitchAuthSession) {
    stop()
    self.auth = auth
    pollTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let succeeded = await self.poll(using: auth)
        try? await Task.sleep(for: self.nextPollDelay(succeeded: succeeded))
      }
    }
  }

  /// The delay before the next poll. A successful (or idle) poll resumes the
  /// steady 60s cadence; a failure backs off exponentially —
  /// `min(60 * 2^(failures-1), 600)` — with equal jitter so a fleet of devices
  /// hitting an outage don't all retry in lockstep.
  private func nextPollDelay(succeeded: Bool) -> Duration {
    if succeeded {
      consecutivePollFailures = 0
      return Self.pollInterval
    }
    consecutivePollFailures += 1
    let base = min(60.0 * pow(2.0, Double(consecutivePollFailures - 1)), Self.maxPollBackoff)
    let half = base / 2
    return .seconds(half + Double.random(in: 0...half))
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
    consecutivePollFailures = 0
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
    Task { [weak self] in
      guard let self else { return }
      var profileURL: URL?
      if let auth = self.auth, auth.isAuthenticated,
         let token = await self.accessToken(auth: auth),
         let clientID = self.resolveClientID() {
        profileURL = (try? await self.fetchProfileImages(
          clientID: clientID, accessToken: token,
          query: [URLQueryItem(name: "login", value: "monstercat")]))?.values.first
      }
      // Decode the avatar before presenting so it animates in with the toast.
      await ImageMemoryCache.shared.prewarm(profileURL)
      self.enqueue(
        GoLiveEvent(
          login: "monstercat", displayName: "Monstercat", gameName: "Music",
          profileImageURL: profileURL))
    }
  }

  // MARK: - Polling

  /// Runs one poll. Returns `true` when the poll completed (including the idle
  /// signed-out case, which needs no backoff) and `false` on a network/auth
  /// failure so the caller can back off before retrying.
  @discardableResult
  private func poll(using auth: TwitchAuthSession) async -> Bool {
    guard auth.isAuthenticated, let userID = auth.userID,
          let clientID = resolveClientID(),
          !Self.disallowedClientIDs.contains(clientID.lowercased())
    else {
      // Signed out / unusable client: reset the baseline so the next authorized
      // poll doesn't treat the whole live follow list as fresh go-lives.
      hasBaseline = false
      knownLiveLogins = []
      return true
    }

    guard let token = await accessToken(auth: auth) else { return false }

    let streams: [GoLiveStream]
    do {
      streams = try await fetchFollowedStreams(clientID: clientID, accessToken: token, userID: userID)
    } catch let error as GoLiveRequestError where error.status == 401 {
      // Token likely expired mid-session: force a refresh and retry once.
      guard let refreshed = try? await auth.refreshAccessTokenIfNeeded(force: true),
            let retry = try? await fetchFollowedStreams(
              clientID: clientID, accessToken: refreshed, userID: userID)
      else { return false }
      streams = retry
    } catch {
      // Transient failure: keep the last baseline so a blip doesn't spam toasts.
      return false
    }

    let liveStreams = streams.filter { $0.type == "live" }
    let liveLogins = Set(liveStreams.map { $0.userLogin.lowercased() })

    guard hasBaseline else {
      knownLiveLogins = liveLogins
      hasBaseline = true
      return true
    }

    let newlyLive = liveLogins.subtracting(knownLiveLogins)
    knownLiveLogins = liveLogins
    guard !newlyLive.isEmpty else { return true }

    let suppressed = suppressedLogin?.lowercased()
    let freshStreams = liveStreams
      .filter { newlyLive.contains($0.userLogin.lowercased()) }
      .filter { $0.userLogin.lowercased() != suppressed }
      .filter { isAlerting(login: $0.userLogin) }
    guard !freshStreams.isEmpty else { return true }

    // Resolve avatars for just the channels that went live (best-effort).
    let avatars = (try? await fetchProfileImages(
      clientID: clientID, accessToken: token,
      query: freshStreams.map { URLQueryItem(name: "id", value: $0.userID) })) ?? [:]

    let events = freshStreams.map {
      GoLiveEvent(
        login: $0.userLogin.lowercased(),
        displayName: $0.userName.isEmpty ? $0.userLogin : $0.userName,
        gameName: $0.gameName,
        profileImageURL: avatars[$0.userID]
      )
    }

    // Decode avatars before presenting so they animate in with each toast.
    for event in events { await ImageMemoryCache.shared.prewarm(event.profileImageURL) }
    for event in events { enqueue(event) }
    return true
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

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, response) = try await NetworkClient.api.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      throw GoLiveRequestError(status: status)
    }
    return try Self.decoder.decode(GoLiveStreamsEnvelope.self, from: data).data
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

  /// Fetch channel avatars via Helix Get Users. `query` selects the users
  /// (`id` or `login` items, batched ≤100). Returns user id -> avatar URL.
  private func fetchProfileImages(
    clientID: String, accessToken: String, query: [URLQueryItem]
  ) async throws -> [String: URL] {
    guard !query.isEmpty else { return [:] }

    var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
    components.queryItems = Array(query.prefix(100))

    let req = TwitchAPIClient.helixRequest(
      url: components.url!, accessToken: accessToken, clientID: clientID,
      accept: "application/json", userAgent: TwitchConfig.apiUserAgent)

    let (data, response) = try await NetworkClient.api.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { throw GoLiveRequestError(status: status) }

    let payload = try Self.decoder.decode(GoLiveUsersEnvelope.self, from: data)
    return Dictionary(
      uniqueKeysWithValues: payload.data.compactMap { user -> (String, URL)? in
        guard let raw = user.profileImageURL, !raw.isEmpty, let url = URL(string: raw) else {
          return nil
        }
        return (user.id, url)
      })
  }

  // MARK: - Queue / countdown

  private func enqueue(_ event: GoLiveEvent) {
    // Respect the viewer's alert preferences (master switch + per-channel mute).
    // Centralized here so the debug `simulateGoLive` path honors them too.
    guard isAlerting(login: event.login) else { return }

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
  let userID: String
  let userLogin: String
  let userName: String
  let gameName: String
  let type: String

  private enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case userLogin = "user_login"
    case userName = "user_name"
    case gameName = "game_name"
    case type
  }
}

private struct GoLiveUsersEnvelope: Decodable {
  let data: [GoLiveUser]
}

private struct GoLiveUser: Decodable {
  let id: String
  let profileImageURL: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case profileImageURL = "profile_image_url"
  }
}
