import Foundation

extension TwitchAuthSession {
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

    private func postChatMessage(
        text: String,
        broadcasterID: String,
        senderID: String,
        clientID: String,
        accessToken: String
    ) async throws {
        var req = TwitchAPIClient.helixRequest(
            url: URL(string: "https://api.twitch.tv/helix/chat/messages")!,
            method: "POST", accessToken: accessToken, clientID: clientID,
            contentType: "application/json")

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

        let payload = try TwitchAPIClient.decode(SendChatMessageEnvelope.self, from: data)
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

        let req = TwitchAPIClient.helixRequest(
            url: components.url!, accessToken: accessToken, clientID: clientID)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "checking follow status", status: status, data: data)
        }

        let payload = try TwitchAPIClient.decode(FollowedStateEnvelope.self, from: data)
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

        var req = TwitchAPIClient.graphQLRequest(clientID: clientID, clientIDField: "Client-ID")
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

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
        let decoded = try TwitchAPIClient.decode(GQLFollowResponse.self, from: data)
        if let message = decoded.errors?.compactMap({ $0.message }).first(where: { !$0.isEmpty }) {
            if isIntegrityCheckFailureMessage(message) {
                throw FollowActionError.integrityCheckRequired
            }
            throw FollowActionError.mutationFailed(reason: message)
        }
        let opError =
            follow
            ? decoded.data?.followUser?.error?.code
            : decoded.data?.unfollowUser?.error?.code
        if let opError, !opError.isEmpty {
            if isIntegrityCheckFailureMessage(opError) {
                throw FollowActionError.integrityCheckRequired
            }
            throw FollowActionError.mutationFailed(reason: opError)
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
