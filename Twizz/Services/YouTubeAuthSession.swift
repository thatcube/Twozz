import Foundation
import Observation

/// Google OAuth 2.0 **device flow** sign-in for reading the viewer's YouTube
/// subscriptions (`youtube.readonly`). Mirrors `TwitchAuthSession`'s shape so the
/// sign-in UI can be reused, but talks to Google's endpoints (which, unlike the
/// standard device flow, also require the client *secret* when exchanging codes).
///
/// Tokens persist in the shared App Group suite under `youtube.auth.*`. Google
/// access tokens are short-lived (~1h), so we store the expiry and refresh on
/// demand using the long-lived refresh token.
@MainActor
@Observable
final class YouTubeAuthSession {
  var isAuthenticated = false
  var accessToken: String?
  var refreshToken: String?
  /// Absolute time the current access token stops being valid.
  var accessTokenExpiry: Date?

  var isAuthenticating = false
  var activationCode: String?
  var verificationURI: String?
  var statusMessage: String?
  var errorMessage: String?

  /// The signed-in viewer's channel title and avatar, fetched once after sign-in
  /// via `channels.list(mine=true)` (1 quota unit). Optional — the UI falls back
  /// to the YouTube logo when these aren't available.
  var userDisplayName: String?
  var profileImageURL: URL?

  private let userDefaults: UserDefaults =
    UserDefaults(suiteName: TopShelf.appGroupID) ?? .standard
  private var pollTask: Task<Void, Never>?
  private var refreshInFlight: Task<String, Error>?

  enum StorageKey {
    static let accessToken = PersistenceKey.youTubeAccessToken
    static let refreshToken = PersistenceKey.youTubeRefreshToken
    static let expiry = PersistenceKey.youTubeTokenExpiry
    static let displayName = "youtube.auth.displayName"
    static let profileImage = "youtube.auth.profileImageURL"
  }

  /// Whether the OAuth client credentials are present (so the UI can hide the
  /// YouTube sign-in entry entirely when the app wasn't built with them).
  var isConfigured: Bool { YouTubeConfig.isConfigured }

  // MARK: - Persistence

  func restore() {
    guard isConfigured else {
      clearStoredAuthState()
      return
    }
    accessToken = userDefaults.string(forKey: StorageKey.accessToken)
    refreshToken = userDefaults.string(forKey: StorageKey.refreshToken)
    accessTokenExpiry = userDefaults.object(forKey: StorageKey.expiry) as? Date
    userDisplayName = userDefaults.string(forKey: StorageKey.displayName)
    profileImageURL = userDefaults.string(forKey: StorageKey.profileImage).flatMap(URL.init(string:))
    // A usable session needs a refresh token; the access token may already be
    // stale and will be refreshed on first use.
    isAuthenticated = refreshToken != nil
    statusMessage = nil
    errorMessage = nil
    if isAuthenticated {
      Task { await fetchProfile() }
    }
  }

  func signOut() {
    pollTask?.cancel()
    pollTask = nil
    clearStoredAuthState()
    activationCode = nil
    verificationURI = nil
    statusMessage = nil
    errorMessage = nil
  }

  private func clearStoredAuthState() {
    isAuthenticated = false
    isAuthenticating = false
    accessToken = nil
    refreshToken = nil
    accessTokenExpiry = nil
    userDisplayName = nil
    profileImageURL = nil
    userDefaults.removeObject(forKey: StorageKey.accessToken)
    userDefaults.removeObject(forKey: StorageKey.refreshToken)
    userDefaults.removeObject(forKey: StorageKey.expiry)
    userDefaults.removeObject(forKey: StorageKey.displayName)
    userDefaults.removeObject(forKey: StorageKey.profileImage)
  }

  private func persistTokens(
    accessToken: String, refreshToken: String?, expiresIn: Int?
  ) {
    self.accessToken = accessToken
    userDefaults.set(accessToken, forKey: StorageKey.accessToken)

    if let refreshToken, !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      self.refreshToken = refreshToken
      userDefaults.set(refreshToken, forKey: StorageKey.refreshToken)
    }

    if let expiresIn {
      // Refresh a minute early to avoid racing the expiry on a slow request.
      let expiry = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 30)))
      accessTokenExpiry = expiry
      userDefaults.set(expiry, forKey: StorageKey.expiry)
    }
  }

  // MARK: - Token access

  /// Returns a valid access token, refreshing first if it's missing or expired.
  func validAccessToken() async throws -> String {
    if let accessToken, let expiry = accessTokenExpiry, expiry > Date() {
      return accessToken
    }
    return try await refreshAccessToken()
  }

  private func refreshAccessToken() async throws -> String {
    if let refreshInFlight { return try await refreshInFlight.value }

    let task = Task { () throws -> String in
      guard let clientID = YouTubeConfig.clientID,
        let clientSecret = YouTubeConfig.clientSecret
      else { throw YouTubeAuthError.notConfigured }
      guard let refreshToken else { throw YouTubeAuthError.sessionExpired }

      do {
        let token = try await requestRefresh(
          clientID: clientID, clientSecret: clientSecret, refreshToken: refreshToken)
        persistTokens(
          accessToken: token.accessToken,
          refreshToken: token.refreshToken,
          expiresIn: token.expiresIn)
        return token.accessToken
      } catch let error as YouTubeAuthHTTPError where error.isInvalidGrant {
        clearStoredAuthState()
        errorMessage = "YouTube session expired. Sign in again."
        throw YouTubeAuthError.sessionExpired
      }
    }
    refreshInFlight = task
    defer { refreshInFlight = nil }
    return try await task.value
  }

  // MARK: - Device flow

  func beginDeviceCodeSignIn() async {
    errorMessage = nil
    guard !isAuthenticating else { return }
    guard let clientID = YouTubeConfig.clientID else {
      errorMessage = "YouTube sign-in isn't configured in this build."
      return
    }

    isAuthenticating = true
    statusMessage = "Requesting YouTube sign-in code…"

    do {
      let response = try await requestDeviceCode(clientID: clientID)
      activationCode = response.userCode
      verificationURI = response.verificationURI
      statusMessage = "Open the link and enter the code to finish sign-in."

      pollTask?.cancel()
      pollTask = Task { [weak self] in
        await self?.pollForToken(
          deviceCode: response.deviceCode,
          interval: max(response.interval, 5),
          expiresIn: response.expiresIn)
      }
    } catch {
      isAuthenticating = false
      errorMessage = "Could not start YouTube sign-in: \(describe(error))"
      statusMessage = nil
    }
  }

  func cancelSignIn() {
    pollTask?.cancel()
    pollTask = nil
    isAuthenticating = false
    statusMessage = nil
  }

  private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async {
    guard let clientID = YouTubeConfig.clientID,
      let clientSecret = YouTubeConfig.clientSecret
    else {
      errorMessage = "YouTube sign-in isn't configured in this build."
      isAuthenticating = false
      return
    }

    let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
    var pollSeconds = interval

    while Date() < expiryDate && !Task.isCancelled {
      do {
        let token = try await requestToken(
          clientID: clientID, clientSecret: clientSecret, deviceCode: deviceCode)
        persistTokens(
          accessToken: token.accessToken,
          refreshToken: token.refreshToken,
          expiresIn: token.expiresIn)
        isAuthenticated = true
        isAuthenticating = false
        activationCode = nil
        statusMessage = "Signed in to YouTube."
        errorMessage = nil
        Task { await fetchProfile() }
        return
      } catch let error as YouTubePollingError {
        switch error {
        case .authorizationPending:
          statusMessage = "Waiting on you…"
        case .slowDown:
          pollSeconds += 5
          statusMessage = "Waiting on you…"
        case .accessDenied:
          errorMessage = "YouTube sign-in was canceled."
          isAuthenticating = false
          return
        case .expiredToken:
          errorMessage = "YouTube sign-in code expired. Try again."
          isAuthenticating = false
          return
        }
      } catch {
        errorMessage = "Sign-in failed: \(describe(error))"
        isAuthenticating = false
        return
      }

      do {
        try await Task.sleep(for: .seconds(pollSeconds))
      } catch {
        isAuthenticating = false
        return
      }
    }

    if !Task.isCancelled {
      errorMessage = "YouTube sign-in timed out."
      isAuthenticating = false
    }
  }

  // MARK: - Profile

  /// Fetches the signed-in viewer's own channel (title + avatar) via
  /// `channels.list(part=snippet, mine=true)` — 1 quota unit, OAuth-gated. Best
  /// effort: failures are swallowed so the UI just keeps showing the logo.
  func fetchProfile() async {
    guard isAuthenticated else { return }
    do {
      let token = try await validAccessToken()
      var components = URLComponents(
        url: YouTubeConfig.apiBaseURL.appendingPathComponent("channels"),
        resolvingAgainstBaseURL: false)!
      components.queryItems = [
        URLQueryItem(name: "part", value: "snippet"),
        URLQueryItem(name: "mine", value: "true"),
      ]

      var request = URLRequest(url: components.url!)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 20

      let (data, response) = try await NetworkClient.api.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      guard (200...299).contains(status) else { return }

      let decoded = try YouTubeConfig.sharedDecoder.decode(ChannelsResponse.self, from: data)
      guard let snippet = decoded.items.first?.snippet else { return }

      userDisplayName = snippet.title
      userDefaults.set(snippet.title, forKey: StorageKey.displayName)

      if let url = snippet.thumbnails?.bestURL {
        profileImageURL = url
        userDefaults.set(url.absoluteString, forKey: StorageKey.profileImage)
      }
    } catch {
      // Non-fatal: the signed-in UI falls back to the YouTube logo.
    }
  }

  // MARK: - Networking

  private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
    var req = URLRequest(url: YouTubeConfig.deviceCodeURL)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body =
      "client_id=\(percentEncode(clientID))&scope=\(percentEncode(YouTubeConfig.readonlyScope))"
    req.httpBody = body.data(using: .utf8)

    let (data, response) = try await NetworkClient.api.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      throw makeHTTPError(context: "requesting YouTube device code", status: status, data: data)
    }
    return try YouTubeConfig.sharedDecoder.decode(DeviceCodeResponse.self, from: data)
  }

  private func requestToken(
    clientID: String, clientSecret: String, deviceCode: String
  ) async throws -> TokenResponse {
    var req = URLRequest(url: YouTubeConfig.tokenURL)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let grantType = "urn:ietf:params:oauth:grant-type:device_code"
    let body =
      "client_id=\(percentEncode(clientID))&client_secret=\(percentEncode(clientSecret))"
      + "&device_code=\(percentEncode(deviceCode))&grant_type=\(percentEncode(grantType))"
    req.httpBody = body.data(using: .utf8)

    let (data, response) = try await NetworkClient.api.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1

    if status == 400 || status == 428 {
      let payload = try? YouTubeConfig.sharedDecoder.decode(OAuthErrorPayload.self, from: data)
      switch payload?.error {
      case "authorization_pending": throw YouTubePollingError.authorizationPending
      case "slow_down": throw YouTubePollingError.slowDown
      case "access_denied": throw YouTubePollingError.accessDenied
      case "expired_token": throw YouTubePollingError.expiredToken
      default: break
      }
    }

    guard (200...299).contains(status) else {
      throw makeHTTPError(context: "exchanging YouTube device code", status: status, data: data)
    }
    return try YouTubeConfig.sharedDecoder.decode(TokenResponse.self, from: data)
  }

  private func requestRefresh(
    clientID: String, clientSecret: String, refreshToken: String
  ) async throws -> TokenResponse {
    var req = URLRequest(url: YouTubeConfig.tokenURL)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body =
      "client_id=\(percentEncode(clientID))&client_secret=\(percentEncode(clientSecret))"
      + "&refresh_token=\(percentEncode(refreshToken))&grant_type=refresh_token"
    req.httpBody = body.data(using: .utf8)

    let (data, response) = try await NetworkClient.api.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else {
      throw makeHTTPError(context: "refreshing YouTube token", status: status, data: data)
    }
    return try YouTubeConfig.sharedDecoder.decode(TokenResponse.self, from: data)
  }

  // MARK: - Helpers

  private func percentEncode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
  }

  private func makeHTTPError(context: String, status: Int, data: Data) -> YouTubeAuthHTTPError {
    let payload = try? YouTubeConfig.sharedDecoder.decode(OAuthErrorPayload.self, from: data)
    let message = payload?.errorDescription ?? payload?.error ?? String(data: data, encoding: .utf8)
    return YouTubeAuthHTTPError(context: context, status: status, error: payload?.error, message: message)
  }

  private func describe(_ error: Error) -> String {
    if let authError = error as? YouTubeAuthHTTPError { return authError.localizedDescription }
    return error.localizedDescription
  }
}

// MARK: - Wire models

private struct DeviceCodeResponse: Decodable {
  let deviceCode: String
  let userCode: String
  let verificationURI: String
  let expiresIn: Int
  let interval: Int

  private enum CodingKeys: String, CodingKey {
    case deviceCode = "device_code"
    case userCode = "user_code"
    // Google returns `verification_url`; accept the RFC `verification_uri` too.
    case verificationURL = "verification_url"
    case verificationURI = "verification_uri"
    case expiresIn = "expires_in"
    case interval
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    deviceCode = try c.decode(String.self, forKey: .deviceCode)
    userCode = try c.decode(String.self, forKey: .userCode)
    verificationURI =
      (try? c.decode(String.self, forKey: .verificationURL))
      ?? (try? c.decode(String.self, forKey: .verificationURI))
      ?? "https://www.google.com/device"
    expiresIn = (try? c.decode(Int.self, forKey: .expiresIn)) ?? 1800
    interval = (try? c.decode(Int.self, forKey: .interval)) ?? 5
  }
}

private struct TokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  let expiresIn: Int?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}

private struct OAuthErrorPayload: Decodable {
  let error: String?
  let errorDescription: String?

  private enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}

private struct ChannelsResponse: Decodable {
  let items: [Item]

  struct Item: Decodable {
    let snippet: Snippet
  }

  struct Snippet: Decodable {
    let title: String
    let thumbnails: Thumbnails?
  }

  struct Thumbnails: Decodable {
    let `default`: Thumb?
    let medium: Thumb?
    let high: Thumb?

    /// Highest-resolution avatar available.
    var bestURL: URL? {
      (high ?? medium ?? `default`)?.url.flatMap(URL.init(string:))
    }

    struct Thumb: Decodable {
      let url: String?
    }
  }
}

private enum YouTubePollingError: Error {
  case authorizationPending
  case slowDown
  case accessDenied
  case expiredToken
}

enum YouTubeAuthError: LocalizedError {
  case notConfigured
  case sessionExpired

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "YouTube sign-in isn't configured in this build."
    case .sessionExpired:
      return "YouTube session expired. Sign in again."
    }
  }
}

struct YouTubeAuthHTTPError: LocalizedError {
  let context: String
  let status: Int
  let error: String?
  let message: String?

  var isInvalidGrant: Bool {
    (status == 400 || status == 401) && (error == "invalid_grant")
  }

  var errorDescription: String? {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return "\(context): \(trimmed) (HTTP \(status))"
    }
    return "\(context) failed (HTTP \(status))"
  }
}
