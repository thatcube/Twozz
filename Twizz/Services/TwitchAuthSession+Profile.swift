import Foundation

extension TwitchAuthSession {
    func requestUserProfile(accessToken: String, clientID: String, userID: String) async throws -> UserProfile {
        var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
        components.queryItems = [URLQueryItem(name: "id", value: userID)]

        let req = TwitchAPIClient.helixRequest(
            url: components.url!, accessToken: accessToken, clientID: clientID)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "loading Twitch profile", status: status, data: data)
        }

        let payload = try TwitchAPIClient.decode(UserProfileEnvelope.self, from: data)
        guard let first = payload.data.first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }

    // MARK: - EventSub support

    /// Credentials needed to open an EventSub WebSocket and create
    /// subscriptions on behalf of the signed-in user. `nil` when signed out.
    var eventSubCredentials: TwitchEventSubCredentials? {
        guard isAuthenticated,
              let clientID,
              let accessToken,
              let userID else {
            return nil
        }
        return TwitchEventSubCredentials(
            clientID: clientID,
            accessToken: accessToken,
            userID: userID
        )
    }

    /// Resolve a channel login to its numeric Twitch user id, reusing the shared
    /// broadcaster-id cache and transparently refreshing the user token on 401.
    /// Public wrapper so EventSub can resolve the `from_broadcaster_user_id`
    /// without duplicating auth/HTTP logic.
    func broadcasterID(forLogin login: String) async throws -> String {
        guard isAuthenticated, let clientID else {
            throw ChatSendError.notSignedIn
        }
        return try await withUserTokenRefreshRetry { accessToken in
            try await resolveBroadcasterID(
                forLogin: login,
                clientID: clientID,
                accessToken: accessToken
            )
        }
    }

    func resolveBroadcasterID(
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

        let req = TwitchAPIClient.helixRequest(
            url: components.url!, accessToken: accessToken, clientID: clientID)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "resolving channel", status: status, data: data)
        }

        let payload = try TwitchAPIClient.decode(UserProfileEnvelope.self, from: data)
        guard let id = payload.data.first?.id else {
            throw ChatSendError.channelNotFound
        }
        broadcasterIDCache[normalized] = id
        return id
    }
}

private struct UserProfileEnvelope: Decodable {
    let data: [UserProfile]
}

struct UserProfile: Decodable {
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
