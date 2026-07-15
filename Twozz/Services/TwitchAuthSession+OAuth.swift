import Foundation

extension TwitchAuthSession {
    /// Refreshes the OAuth access token using the persisted refresh token.
    /// If no refresh token exists, callers should prompt the user to sign in again.
    func refreshAccessTokenIfNeeded(force: Bool = false) async throws -> String {
        if !force, let accessToken {
            return accessToken
        }
        return try await runTokenRefresh(rejectedAccessToken: nil)
    }

    /// Recovers from a 401 without needlessly rotating again when another process
    /// has already published a replacement access token to the shared store.
    func recoverAccessToken(afterUnauthorized rejectedAccessToken: String) async throws -> String {
        try await runTokenRefresh(rejectedAccessToken: rejectedAccessToken)
    }

    private func runTokenRefresh(rejectedAccessToken: String?) async throws -> String {
        // Join an already-running refresh instead of starting a second one.
        // This is what stops the in-app services (followed channels, playback,
        // chat) from racing each other onto the same single-use refresh token.
        if let refreshInFlight {
            return try await refreshInFlight.value
        }

        let task = Task { () throws -> String in
            try await performTokenRefresh(rejectedAccessToken: rejectedAccessToken)
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    private func performTokenRefresh(rejectedAccessToken: String?) async throws -> String {
        guard let clientID else {
            throw TwitchAuthRefreshError.missingClientID
        }

        // Always start from the persisted source of truth. If the token that
        // triggered a 401 has already been replaced, use the replacement instead
        // of spending another refresh token.
        reloadTokensFromStore()
        if let rejectedAccessToken,
           let storedAccessToken = accessToken,
           storedAccessToken != rejectedAccessToken {
            return storedAccessToken
        }
        guard let currentRefreshToken = refreshToken else {
            throw TwitchAuthRefreshError.missingRefreshToken
        }

        do {
            let token = try await requestRefreshToken(
                clientID: clientID, refreshToken: currentRefreshToken)
            return applyRefreshedTokens(token)
        } catch let error as TwitchAuthHTTPError where isInvalidRefreshError(error) {
            // A concurrent app request may have published a replacement while
            // this request was in flight. Reload once before declaring the
            // session dead.
            reloadTokensFromStore()
            if let rejectedAccessToken,
               let storedAccessToken = accessToken,
               storedAccessToken != rejectedAccessToken {
                return storedAccessToken
            }
            if let reloaded = refreshToken, reloaded != currentRefreshToken {
                do {
                    let token = try await requestRefreshToken(
                        clientID: clientID, refreshToken: reloaded)
                    return applyRefreshedTokens(token)
                } catch let retryError as TwitchAuthHTTPError
                    where isInvalidRefreshError(retryError) {
                    // Both tokens are genuinely invalid — fall through to sign-out.
                }
                // A transient (e.g. network) failure on the retry propagates
                // without wiping the session.
            }
            clearStoredAuthState()
            errorMessage = "Session expired. Sign in again to reconnect Twitch."
            throw TwitchAuthRefreshError.sessionExpired
        }
    }

    /// Persists a freshly-issued token pair to memory and the shared App Group
    /// store (which the Top Shelf extension also reads), returning the new
    /// access token.
    @discardableResult
    private func applyRefreshedTokens(_ token: DeviceTokenResponse) -> String {
        accessToken = token.accessToken
        userDefaults.set(token.accessToken, forKey: StorageKey.accessToken)

        if let nextRefreshToken = token.refreshToken,
           !nextRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.refreshToken = nextRefreshToken
            userDefaults.set(nextRefreshToken, forKey: StorageKey.refreshToken)
        }

        return token.accessToken
    }

    /// Pulls the latest persisted tokens from the shared App Group store before
    /// any refresh/recovery decision.
    private func reloadTokensFromStore() {
        accessToken = userDefaults.string(forKey: StorageKey.accessToken)
        refreshToken = userDefaults.string(forKey: StorageKey.refreshToken)
    }

    func startSessionValidation() {
        guard clientIDValidationIssue == nil,
              accessToken != nil || refreshToken != nil else { return }
        startValidationLoop(validateImmediately: true)
    }

    func validateSessionIfNeeded(force: Bool = false) async {
        guard clientIDValidationIssue == nil,
              let expectedClientID = clientID else { return }

        if !force,
           let lastValidatedAt,
           Date().timeIntervalSince(lastValidatedAt) < Self.validationInterval {
            return
        }

        let currentAccessToken: String
        if let accessToken {
            currentAccessToken = accessToken
        } else {
            do {
                currentAccessToken = try await refreshAccessTokenIfNeeded(force: true)
            } catch {
                return
            }
        }

        do {
            let identity = try await requestValidatedIdentity(accessToken: currentAccessToken)
            applyValidatedIdentity(identity, expectedClientID: expectedClientID)
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
            do {
                let recovered = try await recoverAccessToken(
                    afterUnauthorized: currentAccessToken)
                let identity = try await requestValidatedIdentity(accessToken: recovered)
                applyValidatedIdentity(identity, expectedClientID: expectedClientID)
            } catch let refreshError as TwitchAuthRefreshError {
                if case .missingRefreshToken = refreshError {
                    isAuthenticated = false
                    errorMessage = "Session expired. Sign in again to reconnect Twitch."
                }
            } catch {
                // Network and server failures are transient. Preserve credentials
                // and retry validation on the next foreground/hourly check.
            }
        } catch {
            // Validation is best-effort during transient network/server failures;
            // never discard a session unless Twitch rejects its refresh token.
        }
    }

    private func applyValidatedIdentity(
        _ identity: OAuthValidateResponse,
        expectedClientID: String
    ) {
        guard identity.clientID.caseInsensitiveCompare(expectedClientID) == .orderedSame else {
            isAuthenticated = false
            errorMessage =
                "The saved Twitch session belongs to a different Twitch client. Restore the matching client configuration or sign in again."
            return
        }

        userID = identity.userID
        userLogin = identity.login
        isAuthenticated = true
        errorMessage = nil
        let now = Date()
        lastValidatedAt = now
        userDefaults.set(identity.userID, forKey: StorageKey.userID)
        userDefaults.set(identity.login, forKey: StorageKey.userLogin)
        userDefaults.set(now, forKey: StorageKey.lastValidatedAt)
    }

    private func startValidationLoop(validateImmediately: Bool = false) {
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            if validateImmediately {
                guard let self else { return }
                await self.validateSessionIfNeeded(force: true)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.validationInterval))
                } catch {
                    return
                }
                guard let self else { return }
                await self.validateSessionIfNeeded(force: true)
            }
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
        userDefaults.set(clientID, forKey: StorageKey.clientID)
        userDefaults.set(resolvedLogin, forKey: StorageKey.userLogin)
        userDefaults.set(resolvedDisplayName, forKey: StorageKey.userDisplayName)
        if let resolvedImageURL {
            userDefaults.set(resolvedImageURL.absoluteString, forKey: StorageKey.profileImageURL)
        } else {
            userDefaults.removeObject(forKey: StorageKey.profileImageURL)
        }
        let now = Date()
        lastValidatedAt = now
        userDefaults.set(now, forKey: StorageKey.lastValidatedAt)
        startValidationLoop()
    }

    private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let scope = requestedScopes.joined(separator: " ")
        let body = "client_id=\(percentEncode(clientID))&scopes=\(percentEncode(scope))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "requesting Twitch device code", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(DeviceCodeResponse.self, from: data)
    }

    private func requestToken(clientID: String, deviceCode: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "urn:ietf:params:oauth:grant-type:device_code"
        let body = "client_id=\(percentEncode(clientID))&device_code=\(percentEncode(deviceCode))&grant_type=\(percentEncode(grantType))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if status == 400 {
            let payload = (try? TwitchAPIClient.sharedDecoder.decode(OAuthErrorPayload.self, from: data))
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

        return try TwitchAPIClient.sharedDecoder.decode(DeviceTokenResponse.self, from: data)
    }

    private func requestRefreshToken(clientID: String, refreshToken: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "refresh_token"
        let body = "client_id=\(percentEncode(clientID))&grant_type=\(percentEncode(grantType))&refresh_token=\(percentEncode(refreshToken))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "refreshing Twitch token", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(DeviceTokenResponse.self, from: data)
    }

    private func requestValidatedIdentity(accessToken: String) async throws -> OAuthValidateResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        req.httpMethod = "GET"
        req.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "validating Twitch token", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(OAuthValidateResponse.self, from: data)
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
