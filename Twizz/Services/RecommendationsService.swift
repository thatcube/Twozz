import Foundation
import Observation

/// Powers the Home tab's "Recommended" rails. Twitch's personalized
/// recommendations require a logged-in GQL session with integrity tokens, so
/// this anonymously surfaces top live channels and top categories — the same
/// public signals the web home page leans on for logged-out visitors.
@MainActor
@Observable
final class RecommendationsService {
    private(set) var channels: [FollowedChannel] = []
    private(set) var categories: [TwitchCategory] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdatedAt: Date?

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            lastUpdatedAt = Date()
        }

        do {
            async let channelsTask = fetchRecommendedChannels(limit: 30)
            async let categoriesTask = fetchRecommendedCategories(limit: 20)
            let (loadedChannels, loadedCategories) = try await (channelsTask, categoriesTask)
            channels = loadedChannels
            categories = loadedCategories
            prewarmStaticArtwork(channels: loadedChannels, categories: loadedCategories)
        } catch {
            errorMessage = "Could not load recommendations right now."
        }
    }

    /// Warm the decoded-image cache for the *static* artwork the recommendation
    /// rails show — channel avatars and category box art — so those tiles paint
    /// instantly as the Home screen scrolls instead of decoding on the fly. Live
    /// stream preview thumbnails (`FollowedChannel.thumbnailURL`) are deliberately
    /// never prewarmed: they must always reflect the current moment. Best-effort
    /// and low priority; `CachedAsyncImage` still loads on demand if the user
    /// scrolls before the warm pass finishes.
    private func prewarmStaticArtwork(channels: [FollowedChannel], categories: [TwitchCategory]) {
        let urls = channels.compactMap(\.profileImageURL)
            + categories.compactMap(\.boxArtURL)
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if Task.isCancelled { return }
                await ImageMemoryCache.shared.prewarm(url)
            }
        }
    }

    // MARK: - GQL: Recommended Channels (top live streams)

    /// Fetches the most-viewed live channels in viewer-count order, with the
    /// viewer's language filter applied server-side. Twitch's `streams`
    /// connection caps `first` at 30 per request, and paginating past that
    /// requires an integrity token the anonymous public client can't mint — so
    /// this is the full ranked page for the chosen language. "Top streams" then
    /// only hides channels the viewer marked "Not interested".
    private func fetchRecommendedChannels(limit: Int) async throws -> [FollowedChannel] {
        struct StreamNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let isMature: Bool?
            let previewImageURL: String?
            let broadcaster: Broadcaster?
            let game: Game?

            struct Broadcaster: Decodable {
                let login: String?
                let displayName: String?
                let profileImageURL: String?
            }

            struct Game: Decodable {
                let displayName: String?
            }
        }
        struct StreamEdge: Decodable { let node: StreamNode? }
        struct StreamsConn: Decodable { let edges: [StreamEdge]? }
        struct GQLData: Decodable { let streams: StreamsConn? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        // `broadcasterLanguages` is a GQL enum (e.g. EN), not a string, so it
        // is taken from a whitelisted token below — never interpolated from raw
        // input. When the viewer chooses "All", the option is omitted entirely.
        let languageOption: String
        if let token = StreamLanguagePreference.currentToken() {
          languageOption = ", broadcasterLanguages: [\(token)]"
        } else {
          languageOption = ""
        }
        let query = """
            query RecommendedStreams($first: Int!) {
              streams(first: $first, options: {sort: VIEWER_COUNT\(languageOption)}) {
                edges {
                  node {
                    id
                    title
                    viewersCount
                    isMature
                    previewImageURL(width: 640, height: 360)
                    broadcaster {
                      login
                      displayName
                      profileImageURL(width: 70)
                    }
                    game {
                      displayName
                    }
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(query: query, variables: ["first": limit])
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        let edges = decoded.data?.streams?.edges ?? []

        return edges.compactMap { edge -> FollowedChannel? in
            guard let node = edge.node,
                  let broadcaster = node.broadcaster,
                  let login = broadcaster.login?.trimmingCharacters(in: .whitespaces),
                  !login.isEmpty
            else { return nil }

            let streamID = node.id ?? UUID().uuidString
            let displayName = broadcaster.displayName?.trimmingCharacters(in: .whitespaces) ?? login
            let title = node.title?.trimmingCharacters(in: .whitespaces) ?? "Live now"
            let gameName = node.game?.displayName?.trimmingCharacters(in: .whitespaces) ?? "Live"
            let previewURL = node.previewImageURL.flatMap { URL(string: $0) }
            let profileURL = broadcaster.profileImageURL.flatMap { URL(string: $0) }

            return FollowedChannel(
                id: streamID,
                login: login,
                displayName: displayName,
                title: title,
                gameName: gameName,
                viewerCount: node.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: profileURL,
                isLive: true,
                isMature: node.isMature ?? false
            )
        }
    }

    // MARK: - GQL: Recommended Categories (top games)

    private func fetchRecommendedCategories(limit: Int) async throws -> [TwitchCategory] {
        struct GameNode: Decodable {
            let id: String?
            let name: String?
            let boxArtURL: String?
            let viewersCount: Int?
            let isMature: Bool?
        }
        struct GameEdge: Decodable { let node: GameNode? }
        struct TopGamesConn: Decodable { let edges: [GameEdge]? }
        struct GQLData: Decodable { let games: TopGamesConn? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        let query = """
            query RecommendedGames($first: Int!) {
              games(first: $first) {
                edges {
                  node {
                    id
                    name
                    boxArtURL(width: 285, height: 380)
                    viewersCount
                    isMature
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(query: query, variables: ["first": limit])
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        let edges = decoded.data?.games?.edges ?? []

        return edges.compactMap { edge -> TwitchCategory? in
            guard let node = edge.node,
                  let id = node.id,
                  let name = node.name?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { return nil }

            let boxArtURL = node.boxArtURL.flatMap { URL(string: $0) }
            return TwitchCategory(
                id: id,
                name: name,
                boxArtURL: boxArtURL,
                viewerCount: node.viewersCount,
                isMature: node.isMature ?? false
            )
        }
    }

    // MARK: - GQL Transport

    private func performGQL(query: String, variables: [String: Any]) async throws -> Data {
        var req = TwitchAPIClient.graphQLRequest(userAgent: TwitchConfig.apiUserAgent)
        req.httpBody = try JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

        let (data, response) = try await URLSession.shared.data(for: req)
        return try TwitchAPIClient.validatedData(data, response)
    }
}
