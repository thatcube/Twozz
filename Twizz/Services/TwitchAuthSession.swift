import Foundation
import Observation

@MainActor
@Observable
final class TwitchAuthSession {
    private static let disallowedClientIDs: Set<String> = [
        // Twitch web public client. Using this shows "Twilight" on consent
        // and may not reliably authorize Helix followed-channel endpoints.
        "kimne78kx3ncx6brgo4mv6wki5h1ko"
    ]
    private static let twitchGraphQLPublicClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    private(set) var isAuthenticated = false
    private(set) var userID: String?
    private(set) var userLogin: String?
    private(set) var userDisplayName: String?
    private(set) var profileImageURL: URL?
    private(set) var accessToken: String?
    private(set) var refreshToken: String?

    private(set) var isAuthenticating = false
    private(set) var activationCode: String?
    private(set) var verificationURI: String?
    private(set) var verificationURIComplete: String?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let userDefaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var broadcasterIDCache: [String: String] = [:]

    private var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_CLIENT_ID") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("$(") || trimmed.contains("TWITCH_CLIENT_ID") {
            return nil
        }
        return trimmed
    }

    private var clientIDValidationIssue: String? {
        guard let clientID else {
            return "Missing Twitch client ID. Set TWITCH_CLIENT_ID in Config/TwitchSecrets.xcconfig.local."
        }

        if Self.disallowedClientIDs.contains(clientID.lowercased()) {
            return "TWITCH_CLIENT_ID is set to a public Twitch web client ID (shows as \"Twilight\"). Create your own app in the Twitch Developer Console and use that Client ID."
        }

        return nil
    }

    private var requestedScopes: [String] {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_OAUTH_SCOPES") as? String {
            let pieces = raw
                .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !pieces.isEmpty {
                return Array(NSOrderedSet(array: pieces)) as? [String] ?? pieces
            }
        }

        return [
            // Read the signed-in user's followed channels.
            "user:read:follows",
            // Read chat messages (Helix / EventSub) and via IRC.
            "user:read:chat",
            "chat:read",
            // Send chat messages (Helix Send Chat Message) and via IRC.
            "user:write:chat",
            "chat:edit"
        ]
    }

    private enum StorageKey {
        static let accessToken = "twitch.auth.accessToken"
        static let refreshToken = "twitch.auth.refreshToken"
        static let userID = "twitch.auth.userID"
        static let userLogin = "twitch.auth.userLogin"
        static let userDisplayName = "twitch.auth.userDisplayName"
        static let profileImageURL = "twitch.auth.profileImageURL"
    }

    func restore() {
        if let issue = clientIDValidationIssue {
            clearStoredAuthState()
            statusMessage = nil
            errorMessage = issue
            return
        }

        accessToken = userDefaults.string(forKey: StorageKey.accessToken)
        refreshToken = userDefaults.string(forKey: StorageKey.refreshToken)
        userID = userDefaults.string(forKey: StorageKey.userID)
        userLogin = userDefaults.string(forKey: StorageKey.userLogin)
        userDisplayName = userDefaults.string(forKey: StorageKey.userDisplayName)
        profileImageURL = userDefaults.string(forKey: StorageKey.profileImageURL).flatMap(URL.init(string:))
        isAuthenticated = accessToken != nil && userID != nil
        statusMessage = nil
        errorMessage = nil
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil

        isAuthenticated = false
        isAuthenticating = false
        accessToken = nil
        refreshToken = nil
        userID = nil
        userLogin = nil
        userDisplayName = nil
        profileImageURL = nil
        activationCode = nil
        verificationURI = nil
        verificationURIComplete = nil
        statusMessage = nil
        errorMessage = nil

        userDefaults.removeObject(forKey: StorageKey.accessToken)
        userDefaults.removeObject(forKey: StorageKey.refreshToken)
        userDefaults.removeObject(forKey: StorageKey.userID)
        userDefaults.removeObject(forKey: StorageKey.userLogin)
        userDefaults.removeObject(forKey: StorageKey.userDisplayName)
        userDefaults.removeObject(forKey: StorageKey.profileImageURL)
    }

    private func clearStoredAuthState() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        userLogin = nil
        userDisplayName = nil
        profileImageURL = nil
        isAuthenticated = false
        isAuthenticating = false

        userDefaults.removeObject(forKey: StorageKey.accessToken)
        userDefaults.removeObject(forKey: StorageKey.refreshToken)
        userDefaults.removeObject(forKey: StorageKey.userID)
        userDefaults.removeObject(forKey: StorageKey.userLogin)
        userDefaults.removeObject(forKey: StorageKey.userDisplayName)
        userDefaults.removeObject(forKey: StorageKey.profileImageURL)
    }

    /// Refreshes the OAuth access token using the persisted refresh token.
    /// If no refresh token exists, callers should prompt the user to sign in again.
    func refreshAccessTokenIfNeeded(force: Bool = false) async throws -> String {
        if !force, let accessToken {
            return accessToken
        }

        guard let clientID else {
            throw TwitchAuthRefreshError.missingClientID
        }
        guard let refreshToken else {
            throw TwitchAuthRefreshError.missingRefreshToken
        }

        do {
            let token = try await requestRefreshToken(clientID: clientID, refreshToken: refreshToken)
            accessToken = token.accessToken
            userDefaults.set(token.accessToken, forKey: StorageKey.accessToken)

            if let nextRefreshToken = token.refreshToken,
               !nextRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.refreshToken = nextRefreshToken
                userDefaults.set(nextRefreshToken, forKey: StorageKey.refreshToken)
            }

            return token.accessToken
        } catch let error as TwitchAuthHTTPError {
            if isInvalidRefreshError(error) {
                clearStoredAuthState()
                errorMessage = "Session expired. Sign in again to reconnect Twitch."
                throw TwitchAuthRefreshError.sessionExpired
            }
            throw error
        }
    }

    func beginDeviceCodeSignIn() async {
        errorMessage = nil

        guard !isAuthenticating else { return }
        if let issue = clientIDValidationIssue {
            errorMessage = issue
            return
        }
        guard let clientID else { return }

        isAuthenticating = true
        statusMessage = "Requesting Twitch sign-in code..."

        do {
            let response = try await requestDeviceCode(clientID: clientID)
            activationCode = response.userCode
            verificationURI = response.verificationURI
            verificationURIComplete = response.verificationURIComplete
            statusMessage = "Open the link and enter the code to finish sign-in."

            pollTask?.cancel()
            pollTask = Task { [weak self] in
                await self?.pollForAccessToken(
                    deviceCode: response.deviceCode,
                    interval: max(response.interval, 2),
                    expiresIn: response.expiresIn,
                    clientID: clientID
                )
            }
        } catch {
            isAuthenticating = false
            errorMessage = "Could not start Twitch sign-in: \(describe(error))"
            statusMessage = nil
        }
    }

    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        isAuthenticating = false
        statusMessage = nil
    }

    private func pollForAccessToken(deviceCode: String, interval: Int, expiresIn: Int, clientID: String) async {
        let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollSeconds = interval

        while Date() < expiryDate && !Task.isCancelled {
            do {
                let token = try await requestToken(clientID: clientID, deviceCode: deviceCode)
                try await finishSignIn(token: token, clientID: clientID)
                return
            } catch let error as OAuthPollingError {
                switch error {
                case .authorizationPending:
                    statusMessage = "Waiting on you…"
                case .slowDown:
                    pollSeconds += 2
                    statusMessage = "Waiting on you…"
                case .accessDenied:
                    errorMessage = "Twitch sign-in was canceled."
                    isAuthenticating = false
                    return
                case .expiredToken:
                    errorMessage = "Twitch sign-in code expired. Try again."
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
            errorMessage = "Twitch sign-in timed out."
            isAuthenticating = false
        }
    }

    private func finishSignIn(token: DeviceTokenResponse, clientID: String) async throws {
        let identity = try await requestValidatedIdentity(accessToken: token.accessToken)
        let profile = try? await requestUserProfile(accessToken: token.accessToken, clientID: clientID, userID: identity.userID)

        let resolvedLogin = profile?.login ?? identity.login
        let resolvedDisplayName = profile?.displayName ?? identity.login
        let resolvedImageURL = profile?.profileImageURL.flatMap(URL.init(string:))

        self.accessToken = token.accessToken
        self.refreshToken = token.refreshToken
        self.userID = identity.userID
        self.userLogin = resolvedLogin
        self.userDisplayName = resolvedDisplayName
        self.profileImageURL = resolvedImageURL
        self.isAuthenticated = true
        self.isAuthenticating = false
        self.statusMessage = "Signed in as \(resolvedDisplayName)."
        self.errorMessage = nil

        userDefaults.set(token.accessToken, forKey: StorageKey.accessToken)
        if let refreshToken = token.refreshToken,
           !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userDefaults.set(refreshToken, forKey: StorageKey.refreshToken)
        } else {
            userDefaults.removeObject(forKey: StorageKey.refreshToken)
        }
        userDefaults.set(identity.userID, forKey: StorageKey.userID)
        userDefaults.set(resolvedLogin, forKey: StorageKey.userLogin)
        userDefaults.set(resolvedDisplayName, forKey: StorageKey.userDisplayName)
        if let resolvedImageURL {
            userDefaults.set(resolvedImageURL.absoluteString, forKey: StorageKey.profileImageURL)
        } else {
            userDefaults.removeObject(forKey: StorageKey.profileImageURL)
        }
    }

    private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let scope = requestedScopes.joined(separator: " ")
        let body = "client_id=\(percentEncode(clientID))&scopes=\(percentEncode(scope))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "requesting Twitch device code", status: status, data: data)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func requestToken(clientID: String, deviceCode: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "urn:ietf:params:oauth:grant-type:device_code"
        let body = "client_id=\(percentEncode(clientID))&device_code=\(percentEncode(deviceCode))&grant_type=\(percentEncode(grantType))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if status == 400 {
            let payload = (try? JSONDecoder().decode(OAuthErrorPayload.self, from: data))
            switch normalizedOAuthMessage(payload?.message) {
            case "authorization_pending": throw OAuthPollingError.authorizationPending
            case "slow_down": throw OAuthPollingError.slowDown
            case "access_denied": throw OAuthPollingError.accessDenied
            case "expired_token": throw OAuthPollingError.expiredToken
            case "invalid_device_code": throw OAuthPollingError.expiredToken
            default: break
            }
        }

        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "exchanging Twitch device code", status: status, data: data)
        }

        return try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
    }

    private func requestRefreshToken(clientID: String, refreshToken: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "refresh_token"
        let body = "client_id=\(percentEncode(clientID))&grant_type=\(percentEncode(grantType))&refresh_token=\(percentEncode(refreshToken))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "refreshing Twitch token", status: status, data: data)
        }

        return try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
    }

    private func requestValidatedIdentity(accessToken: String) async throws -> OAuthValidateResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        req.httpMethod = "GET"
        req.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "validating Twitch token", status: status, data: data)
        }

        return try JSONDecoder().decode(OAuthValidateResponse.self, from: data)
    }

    private func requestUserProfile(accessToken: String, clientID: String, userID: String) async throws -> UserProfile {
        var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
        components.queryItems = [URLQueryItem(name: "id", value: userID)]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "loading Twitch profile", status: status, data: data)
        }

        let payload = try JSONDecoder().decode(UserProfileEnvelope.self, from: data)
        guard let first = payload.data.first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }

    private func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    private func normalizedOAuthMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        return message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func makeHTTPError(context: String, status: Int, data: Data) -> TwitchAuthHTTPError {
        let payload = try? JSONDecoder().decode(TwitchAuthAPIErrorPayload.self, from: data)
        let message = payload?.message ?? payload?.error ?? String(data: data, encoding: .utf8)
        return TwitchAuthHTTPError(context: context, status: status, message: message)
    }

    private func isInvalidRefreshError(_ error: TwitchAuthHTTPError) -> Bool {
        guard error.status == 400 || error.status == 401 else { return false }
        guard let normalized = normalizedOAuthMessage(error.message) else { return false }
        return normalized.contains("invalid_refresh_token") || normalized.contains("invalid_grant")
    }

    private func isInvalidClientIDError(_ error: TwitchAuthHTTPError) -> Bool {
        guard error.status == 400 else { return false }
        guard let normalized = normalizedOAuthMessage(error.message) else { return false }
        return normalized.contains("client_id") && normalized.contains("invalid")
    }

    private func describe(_ error: Error) -> String {
        if let authError = error as? TwitchAuthHTTPError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - Sending chat

    /// Send a chat message to `channelLogin` on behalf of the signed-in user via
    /// the Helix "Send Chat Message" endpoint. Requires the `user:write:chat`
    /// scope. The message echoes back through the anonymous IRC read connection,
    /// so callers don't need to insert it locally.
    func sendChatMessage(_ rawText: String, toChannel channelLogin: String) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard isAuthenticated,
              let clientID,
              let accessToken,
              let senderID = userID else {
            throw ChatSendError.notSignedIn
        }

        let broadcasterID = try await resolveBroadcasterID(
            forLogin: channelLogin,
            clientID: clientID,
            accessToken: accessToken
        )
        try await postChatMessage(
            text: text,
            broadcasterID: broadcasterID,
            senderID: senderID,
            clientID: clientID,
            accessToken: accessToken
        )
    }

    private func resolveBroadcasterID(
        forLogin login: String,
        clientID: String,
        accessToken: String
    ) async throws -> String {
        let normalized = login.lowercased()
        if let cached = broadcasterIDCache[normalized] {
            return cached
        }

        var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
        components.queryItems = [URLQueryItem(name: "login", value: normalized)]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "resolving channel", status: status, data: data)
        }

        let payload = try JSONDecoder().decode(UserProfileEnvelope.self, from: data)
        guard let id = payload.data.first?.id else {
            throw ChatSendError.channelNotFound
        }
        broadcasterIDCache[normalized] = id
        return id
    }

    private func postChatMessage(
        text: String,
        broadcasterID: String,
        senderID: String,
        clientID: String,
        accessToken: String
    ) async throws {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/chat/messages")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "broadcaster_id": broadcasterID,
            "sender_id": senderID,
            "message": text,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "sending message", status: status, data: data)
        }

        let payload = try JSONDecoder().decode(SendChatMessageEnvelope.self, from: data)
        guard let result = payload.data.first else { return }
        if result.isSent == false {
            throw ChatSendError.dropped(reason: result.dropReason?.message ?? result.dropReason?.code)
        }
    }

    // MARK: - Follow / unfollow

    /// Whether the signed-in user currently follows `channelLogin`.
    ///
    /// Reading follow state still works through the official Helix
    /// `channels/followed` endpoint (with the `user:read:follows` scope), so the
    /// initial button state is reliable even though mutating the follow is not.
    func isFollowing(channelLogin: String) async throws -> Bool {
        guard isAuthenticated, let clientID, let userID else {
            throw FollowActionError.notSignedIn
        }
        return try await withUserTokenRefreshRetry { accessToken in
            let broadcasterID = try await resolveBroadcasterID(
                forLogin: channelLogin,
                clientID: clientID,
                accessToken: accessToken
            )
            return try await fetchFollowState(
                broadcasterID: broadcasterID,
                userID: userID,
                clientID: clientID,
                accessToken: accessToken
            )
        }
    }

    /// Follows `channelLogin` on behalf of the signed-in user.
    func followChannel(login: String) async throws {
        try await setFollow(true, login: login)
    }

    /// Unfollows `channelLogin` on behalf of the signed-in user.
    func unfollowChannel(login: String) async throws {
        try await setFollow(false, login: login)
    }

    private func setFollow(_ shouldFollow: Bool, login: String) async throws {
        guard isAuthenticated, let clientID else {
            throw FollowActionError.notSignedIn
        }
        try await withUserTokenRefreshRetry { accessToken in
            let broadcasterID = try await resolveBroadcasterID(
                forLogin: login,
                clientID: clientID,
                accessToken: accessToken
            )
            try await performFollowMutation(
                targetID: broadcasterID,
                follow: shouldFollow,
                clientID: clientID,
                accessToken: accessToken
            )
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken {
            return accessToken
        }
        return try await refreshAccessTokenIfNeeded(force: true)
    }

    private func withUserTokenRefreshRetry<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let accessToken = try await validAccessToken()
        do {
            return try await operation(accessToken)
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
            let refreshedAccessToken = try await refreshAccessTokenIfNeeded(force: true)
            return try await operation(refreshedAccessToken)
        }
    }

    private func fetchFollowState(
        broadcasterID: String,
        userID: String,
        clientID: String,
        accessToken: String
    ) async throws -> Bool {
        var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "broadcaster_id", value: broadcasterID),
        ]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "checking follow status", status: status, data: data)
        }

        let payload = try JSONDecoder().decode(FollowedStateEnvelope.self, from: data)
        // `total` can represent the user's overall followed-channel count, so
        // determine state from the returned relationship rows instead.
        return payload.data.contains { entry in
            entry.broadcasterID == broadcasterID
        }
    }

    /// Mutates the follow via Twitch's private GraphQL API.
    ///
    /// Twitch removed follow/unfollow from the public Helix API in 2021, so this
    /// is the only route left and is unofficial/best-effort — it can fail or stop
    /// working if Twitch changes the endpoint.
    private func performFollowMutation(
        targetID: String,
        follow: Bool,
        clientID: String,
        accessToken: String
    ) async throws {
        let normalizedClientID = clientID.lowercased()
        do {
            try await performFollowMutationWithAuthorizationFallback(
                targetID: targetID,
                follow: follow,
                clientID: clientID,
                accessToken: accessToken
            )
        } catch let error as TwitchAuthHTTPError
        where isInvalidClientIDError(error)
            && normalizedClientID != Self.twitchGraphQLPublicClientID
        {
            // Some GQL routes reject app-issued client IDs even with valid user
            // tokens; retry with Twitch's public web client ID.
            try await performFollowMutationWithAuthorizationFallback(
                targetID: targetID,
                follow: follow,
                clientID: Self.twitchGraphQLPublicClientID,
                accessToken: accessToken
            )
        }
    }

    private func performFollowMutationWithAuthorizationFallback(
        targetID: String,
        follow: Bool,
        clientID: String,
        accessToken: String
    ) async throws {
        do {
            try await performFollowMutationRequest(
                targetID: targetID,
                follow: follow,
                clientID: clientID,
                authorizationHeader: "OAuth \(accessToken)"
            )
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
            // Some Twitch GraphQL paths only accept Bearer even for user tokens.
            try await performFollowMutationRequest(
                targetID: targetID,
                follow: follow,
                clientID: clientID,
                authorizationHeader: "Bearer \(accessToken)"
            )
        }
    }

    private func performFollowMutationRequest(
        targetID: String,
        follow: Bool,
        clientID: String,
        authorizationHeader: String
    ) async throws {
        let query: String
        var variables: [String: Any] = ["targetID": targetID]
        if follow {
            query = """
                mutation FollowUser($targetID: ID!, $disableNotifications: Boolean!) {
                  followUser(input: {targetID: $targetID, disableNotifications: $disableNotifications}) {
                    follow { disableNotifications }
                    error { code }
                  }
                }
                """
            variables["disableNotifications"] = false
        } else {
            query = """
                mutation UnfollowUser($targetID: ID!) {
                  unfollowUser(input: {targetID: $targetID}) {
                    follow { disableNotifications }
                    error { code }
                  }
                }
                """
        }

        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(
                context: follow ? "following channel" : "unfollowing channel",
                status: status,
                data: data
            )
        }

        // GraphQL returns HTTP 200 even for logical failures, so inspect the body.
        let decoded = try JSONDecoder().decode(GQLFollowResponse.self, from: data)
        if let message = decoded.errors?.compactMap({ $0.message }).first(where: { !$0.isEmpty }) {
            throw FollowActionError.mutationFailed(reason: message)
        }
        let opError =
            follow
            ? decoded.data?.followUser?.error?.code
            : decoded.data?.unfollowUser?.error?.code
        if let opError, !opError.isEmpty {
            throw FollowActionError.mutationFailed(reason: opError)
        }
    }
}

enum FollowActionError: LocalizedError {
    case notSignedIn
    case mutationFailed(reason: String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to follow channels."
        case .mutationFailed(let reason):
            if let reason, !reason.isEmpty {
                return "Couldn't update follow: \(reason)."
            }
            return "Couldn't update follow right now."
        }
    }
}

private struct FollowedStateEnvelope: Decodable {
    let total: Int?
    let data: [FollowedStateEntry]
}

private struct FollowedStateEntry: Decodable {
    let broadcasterID: String?

    private enum CodingKeys: String, CodingKey {
        case broadcasterID = "broadcaster_id"
    }
}

private struct GQLFollowResponse: Decodable {
    let data: GQLFollowData?
    let errors: [GQLFollowError]?
}

private struct GQLFollowData: Decodable {
    let followUser: GQLFollowResult?
    let unfollowUser: GQLFollowResult?
}

private struct GQLFollowResult: Decodable {
    let error: GQLFollowOpError?
}

private struct GQLFollowOpError: Decodable {
    let code: String?
}

private struct GQLFollowError: Decodable {
    let message: String?
}

enum ChatSendError: LocalizedError {
    case notSignedIn
    case channelNotFound
    case dropped(reason: String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to send messages."
        case .channelNotFound:
            return "Couldn't find that channel."
        case .dropped(let reason):
            if let reason, !reason.isEmpty {
                return "Message not sent: \(reason)."
            }
            return "Message not sent."
        }
    }
}

private struct SendChatMessageEnvelope: Decodable {
    let data: [SendChatMessageResult]
}

private struct SendChatMessageResult: Decodable {
    let messageID: String?
    let isSent: Bool?
    let dropReason: DropReason?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case isSent = "is_sent"
        case dropReason = "drop_reason"
    }

    struct DropReason: Decodable {
        let code: String?
        let message: String?
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct OAuthErrorPayload: Decodable {
    let status: Int?
    let message: String
}

private struct OAuthValidateResponse: Decodable {
    let clientID: String
    let login: String
    let userID: String
    let scopes: [String]
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case login
        case userID = "user_id"
        case scopes
        case expiresIn = "expires_in"
    }
}

private struct TwitchAuthAPIErrorPayload: Decodable {
    let status: Int?
    let message: String?
    let error: String?
}

private struct TwitchAuthHTTPError: LocalizedError {
    let context: String
    let status: Int
    let message: String?

    var errorDescription: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "\(context): \(trimmed) (HTTP \(status))"
        }
        return "\(context) failed (HTTP \(status))"
    }
}

private enum OAuthPollingError: Error {
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredToken
}

private enum TwitchAuthRefreshError: LocalizedError {
    case missingClientID
    case missingRefreshToken
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Missing Twitch client ID."
        case .missingRefreshToken:
            return "Session expired. Sign in again to reconnect Twitch."
        case .sessionExpired:
            return "Session expired. Sign in again to reconnect Twitch."
        }
    }
}

private struct UserProfileEnvelope: Decodable {
    let data: [UserProfile]
}

private struct UserProfile: Decodable {
    let id: String
    let login: String
    let displayName: String
    let profileImageURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName = "display_name"
        case profileImageURL = "profile_image_url"
    }
}
