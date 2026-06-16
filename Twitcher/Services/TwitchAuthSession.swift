import Foundation
import Observation

@MainActor
@Observable
final class TwitchAuthSession {
    private(set) var isAuthenticated = false
    private(set) var userID: String?
    private(set) var userLogin: String?
    private(set) var userDisplayName: String?
    private(set) var accessToken: String?

    private(set) var isAuthenticating = false
    private(set) var activationCode: String?
    private(set) var verificationURI: String?
    private(set) var verificationURIComplete: String?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let userDefaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?

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

    private enum StorageKey {
        static let accessToken = "twitch.auth.accessToken"
        static let userID = "twitch.auth.userID"
        static let userLogin = "twitch.auth.userLogin"
        static let userDisplayName = "twitch.auth.userDisplayName"
    }

    func restore() {
        accessToken = userDefaults.string(forKey: StorageKey.accessToken)
        userID = userDefaults.string(forKey: StorageKey.userID)
        userLogin = userDefaults.string(forKey: StorageKey.userLogin)
        userDisplayName = userDefaults.string(forKey: StorageKey.userDisplayName)
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
        userID = nil
        userLogin = nil
        userDisplayName = nil
        activationCode = nil
        verificationURI = nil
        verificationURIComplete = nil
        statusMessage = nil
        errorMessage = nil

        userDefaults.removeObject(forKey: StorageKey.accessToken)
        userDefaults.removeObject(forKey: StorageKey.userID)
        userDefaults.removeObject(forKey: StorageKey.userLogin)
        userDefaults.removeObject(forKey: StorageKey.userDisplayName)
    }

    func beginDeviceCodeSignIn() async {
        errorMessage = nil

        guard !isAuthenticating else { return }
        guard let clientID else {
            errorMessage = "Missing Twitch client ID. Set TWITCH_CLIENT_ID in Config/TwitchSecrets.xcconfig.local."
            return
        }

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
            errorMessage = "Could not start Twitch sign-in: \(error.localizedDescription)"
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
                try await finishSignIn(accessToken: token.accessToken, clientID: clientID)
                return
            } catch let error as OAuthPollingError {
                switch error {
                case .authorizationPending:
                    statusMessage = "Waiting for Twitch authorization..."
                case .slowDown:
                    pollSeconds += 2
                    statusMessage = "Waiting for Twitch authorization..."
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
                errorMessage = "Sign-in failed: \(error.localizedDescription)"
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

    private func finishSignIn(accessToken: String, clientID: String) async throws {
        let profile = try await requestUserProfile(accessToken: accessToken, clientID: clientID)

        self.accessToken = accessToken
        self.userID = profile.id
        self.userLogin = profile.login
        self.userDisplayName = profile.displayName
        self.isAuthenticated = true
        self.isAuthenticating = false
        self.statusMessage = "Signed in as \(profile.displayName)."
        self.errorMessage = nil

        userDefaults.set(accessToken, forKey: StorageKey.accessToken)
        userDefaults.set(profile.id, forKey: StorageKey.userID)
        userDefaults.set(profile.login, forKey: StorageKey.userLogin)
        userDefaults.set(profile.displayName, forKey: StorageKey.userDisplayName)
    }

    private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let scope = "user:read:follows"
        let body = "client_id=\(percentEncode(clientID))&scopes=\(percentEncode(scope))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw URLError(.badServerResponse)
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
            switch payload?.message.lowercased() {
            case "authorization_pending": throw OAuthPollingError.authorizationPending
            case "slow_down": throw OAuthPollingError.slowDown
            case "access_denied": throw OAuthPollingError.accessDenied
            case "expired_token": throw OAuthPollingError.expiredToken
            default: break
            }
        }

        guard (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
    }

    private func requestUserProfile(accessToken: String, clientID: String) async throws -> UserProfile {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/users")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw URLError(.badServerResponse)
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

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct OAuthErrorPayload: Decodable {
    let status: Int?
    let message: String
}

private enum OAuthPollingError: Error {
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredToken
}

private struct UserProfileEnvelope: Decodable {
    let data: [UserProfile]
}

private struct UserProfile: Decodable {
    let id: String
    let login: String
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName = "display_name"
    }
}
