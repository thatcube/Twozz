import Foundation
import Observation

@MainActor
@Observable
final class FollowedChannelsService {
    private(set) var channels: [FollowedChannel] = []
    private(set) var isLoading = false
    private(set) var isUsingDemoData = false
    private(set) var errorMessage: String?
    private(set) var lastUpdatedAt: Date?

    func refresh(using auth: TwitchAuthSession) async {
        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
            lastUpdatedAt = Date()
        }

        guard auth.isAuthenticated,
              let clientID = resolveClientID(),
              let accessToken = auth.accessToken,
              let userID = auth.userID else {
            channels = await fetchDemoChannels()
            isUsingDemoData = true
            return
        }

        do {
            channels = try await fetchLiveFollowedChannels(
                clientID: clientID,
                accessToken: accessToken,
                userID: userID
            )
            isUsingDemoData = false
        } catch {
            channels = await fetchDemoChannels()
            isUsingDemoData = true
            let detail = describe(error)
            errorMessage = "Could not load followed channels (\(detail)). Showing trending channels instead."
        }
    }

    private func resolveClientID() -> String? {
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

    private func fetchDemoChannels() async -> [FollowedChannel] {
        do {
            let trending = try await fetchTrendingChannels()
            if !trending.isEmpty {
                return trending
            }
            errorMessage = "Trending feed is empty right now. Showing fallback demo channels."
        } catch {
            errorMessage = "Could not load trending channels. Showing fallback demo channels."
        }

        return Self.demoChannels
    }

    private func fetchLiveFollowedChannels(clientID: String, accessToken: String, userID: String) async throws -> [FollowedChannel] {
        do {
            let followed = try await fetchFollowedStreamsDirect(clientID: clientID, accessToken: accessToken, userID: userID)
            return followed.map(mapStream)
        } catch let error as TwitchHelixRequestError {
            guard error.status == 404 else {
                throw error
            }

            let follows = try await fetchFollowedBroadcasters(clientID: clientID, accessToken: accessToken, userID: userID)
            if follows.isEmpty {
                return []
            }

            let liveByBroadcasterID = try await fetchLiveStreamsByBroadcasterID(
                clientID: clientID,
                accessToken: accessToken,
                broadcasterIDs: follows.map(\.broadcasterID)
            )

            return follows.compactMap { followed in
                guard let stream = liveByBroadcasterID[followed.broadcasterID] else {
                    return nil
                }
                return mapStream(stream)
            }
        }
    }

    private func fetchFollowedStreamsDirect(clientID: String, accessToken: String, userID: String) async throws -> [HelixStream] {
        var components = URLComponents(string: "https://api.twitch.tv/helix/streams/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "first", value: "100")
        ]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, status) = try await performHelixRequest(req)
        guard (200...299).contains(status) else {
            throw makeHelixError(context: "loading followed streams", status: status, data: data)
        }

        return try JSONDecoder().decode(FollowedStreamsEnvelope.self, from: data).data
    }

    private func fetchFollowedBroadcasters(clientID: String, accessToken: String, userID: String) async throws -> [FollowedBroadcaster] {
        var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "first", value: "100")
        ]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, status) = try await performHelixRequest(req)
        guard (200...299).contains(status) else {
            throw makeHelixError(context: "loading followed channels", status: status, data: data)
        }

        return try JSONDecoder().decode(FollowedChannelsEnvelope.self, from: data).data
    }

    private func fetchLiveStreamsByBroadcasterID(clientID: String, accessToken: String, broadcasterIDs: [String]) async throws -> [String: HelixStream] {
        guard !broadcasterIDs.isEmpty else { return [:] }

        let cappedIDs = Array(Set(broadcasterIDs)).prefix(100)
        var components = URLComponents(string: "https://api.twitch.tv/helix/streams")!
        components.queryItems = [URLQueryItem(name: "first", value: "100")]
        components.queryItems?.append(contentsOf: cappedIDs.map { URLQueryItem(name: "user_id", value: $0) })

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")

        let (data, status) = try await performHelixRequest(req)
        guard (200...299).contains(status) else {
            throw makeHelixError(context: "loading live stream statuses", status: status, data: data)
        }

        let streams = try JSONDecoder().decode(FollowedStreamsEnvelope.self, from: data).data
        return Dictionary(uniqueKeysWithValues: streams.map { ($0.userID, $0) })
    }

    private func mapStream(_ stream: HelixStream) -> FollowedChannel {
            let thumb = stream.thumbnailURL
                .replacingOccurrences(of: "{width}", with: "640")
                .replacingOccurrences(of: "{height}", with: "360")

        return FollowedChannel(
            id: stream.userID,
            login: stream.userLogin,
            displayName: stream.userName,
            title: stream.title,
            gameName: stream.gameName,
            viewerCount: stream.viewerCount,
            thumbnailURL: URL(string: thumb),
            profileImageURL: nil,
            isLive: stream.type == "live"
        )
    }

    private func performHelixRequest(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    private func makeHelixError(context: String, status: Int, data: Data) -> TwitchHelixRequestError {
        let payload = try? JSONDecoder().decode(TwitchHelixErrorPayload.self, from: data)
        let message = payload?.message ?? payload?.error ?? String(data: data, encoding: .utf8)
        return TwitchHelixRequestError(context: context, status: status, message: message)
    }

    private func describe(_ error: Error) -> String {
        if let helixError = error as? TwitchHelixRequestError {
            return helixError.localizedDescription
        }
        return error.localizedDescription
    }

    /// Fetches top live streams anonymously from Twitch GraphQL.
    /// This powers demo mode when user auth is not configured yet.
    private func fetchTrendingChannels(limit: Int = 20) async throws -> [FollowedChannel] {
        struct TrendingNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let previewImageURL: String?
            let broadcaster: Broadcaster?
            let game: Game?

            struct Broadcaster: Decodable {
                let login: String?
                let displayName: String?
            }

            struct Game: Decodable {
                let displayName: String?
            }
        }

        struct TrendingEdge: Decodable {
            let node: TrendingNode?
        }

        struct StreamsConnection: Decodable {
            let edges: [TrendingEdge]?
        }

        struct TrendingData: Decodable {
            let streams: StreamsConnection?
        }

        struct TrendingEnvelope: Decodable {
            let data: TrendingData?
        }

        let query = """
        query TopStreams($first: Int!) {
          streams(first: $first) {
            edges {
              node {
                id
                title
                viewersCount
                previewImageURL(width: 640, height: 360)
                broadcaster {
                  login
                  displayName
                }
                game {
                  displayName
                }
              }
            }
          }
        }
        """

        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-Id")

        let payload: [String: Any] = [
            "query": query,
            "variables": ["first": limit]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(TrendingEnvelope.self, from: data)
        let edges = decoded.data?.streams?.edges ?? []

        let channels = edges.compactMap { edge -> FollowedChannel? in
            guard let node = edge.node else { return nil }

            let id = node.id ?? UUID().uuidString
            let login = node.broadcaster?.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = node.broadcaster?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = node.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Live now"
            let gameName = node.game?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Live"
            let previewURL = node.previewImageURL.flatMap { URL(string: $0) }

            guard !login.isEmpty else { return nil }

            return FollowedChannel(
                id: id,
                login: login,
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? login,
                title: title,
                gameName: gameName,
                viewerCount: node.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: nil,
                isLive: true
            )
        }

        return channels
    }

    private static let demoChannels: [FollowedChannel] = [
        FollowedChannel(
            id: "44322889",
            login: "alveussanctuary",
            displayName: "AlveusSanctuary",
            title: "Rescue animals, science, and chill vibes",
            gameName: "Animals, Aquariums, and Zoos",
            viewerCount: 4821,
            thumbnailURL: URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_alveussanctuary-640x360.jpg"),
            profileImageURL: nil,
            isLive: true
        ),
        FollowedChannel(
            id: "71092938",
            login: "northernlion",
            displayName: "Northernlion",
            title: "Trying weird roguelikes and talking nonsense",
            gameName: "Balatro",
            viewerCount: 8230,
            thumbnailURL: URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_northernlion-640x360.jpg"),
            profileImageURL: nil,
            isLive: true
        ),
        FollowedChannel(
            id: "26490481",
            login: "cohhcarnage",
            displayName: "CohhCarnage",
            title: "New release first look",
            gameName: "Just Chatting",
            viewerCount: 3912,
            thumbnailURL: URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_cohhcarnage-640x360.jpg"),
            profileImageURL: nil,
            isLive: true
        ),
        FollowedChannel(
            id: "23161357",
            login: "esl_cs2",
            displayName: "ESL_CSGO",
            title: "Playoffs day 2 - main stage",
            gameName: "Counter-Strike",
            viewerCount: 66740,
            thumbnailURL: URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_esl_cs2-640x360.jpg"),
            profileImageURL: nil,
            isLive: true
        )
    ]
}

private struct FollowedStreamsEnvelope: Decodable {
    let data: [HelixStream]
}

private struct HelixStream: Decodable {
    let userID: String
    let userLogin: String
    let userName: String
    let gameName: String
    let title: String
    let viewerCount: Int
    let thumbnailURL: String
    let type: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userLogin = "user_login"
        case userName = "user_name"
        case gameName = "game_name"
        case title
        case viewerCount = "viewer_count"
        case thumbnailURL = "thumbnail_url"
        case type
    }
}

private struct FollowedChannelsEnvelope: Decodable {
    let data: [FollowedBroadcaster]
}

private struct FollowedBroadcaster: Decodable {
    let broadcasterID: String

    private enum CodingKeys: String, CodingKey {
        case broadcasterID = "broadcaster_id"
    }
}

private struct TwitchHelixErrorPayload: Decodable {
    let error: String?
    let status: Int?
    let message: String?
}

private struct TwitchHelixRequestError: LocalizedError {
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
