import Foundation
import Observation

@MainActor
@Observable
final class BrowseService {
    private(set) var categories: [TwitchCategory] = []
    private(set) var isLoadingCategories = false
    private(set) var categoryErrorMessage: String?

    private(set) var categoryStreams: [FollowedChannel] = []
    private(set) var isLoadingStreams = false
    private(set) var streamsErrorMessage: String?

    // MARK: - Public API

    func loadCategories() async {
        isLoadingCategories = true
        categoryErrorMessage = nil
        defer { isLoadingCategories = false }

        do {
            categories = try await fetchTopCategories(limit: 40)
        } catch {
            categoryErrorMessage = "Could not load categories."
        }
    }

    func loadStreams(for category: TwitchCategory) async {
        isLoadingStreams = true
        streamsErrorMessage = nil
        categoryStreams = []
        defer { isLoadingStreams = false }

        do {
            // Twitch's anonymous GQL client rejects cursor pagination (integrity
            // challenge), so fetch the full set in one request. 100 is the max
            // the API allows for `first`.
            categoryStreams = try await fetchStreams(for: category, limit: 100)
        } catch {
            streamsErrorMessage = "Could not load streams for \(category.name)."
        }
    }

    // MARK: - GQL: Top Categories

    private func fetchTopCategories(limit: Int) async throws -> [TwitchCategory] {
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
            query TopGames($first: Int!) {
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

        let responseData = try await performGQL(
            query: query, variables: ["first": limit])
        let decoded = try JSONDecoder().decode(GQLEnvelope.self, from: responseData)
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

    // MARK: - GQL: Streams by Category

    private func fetchStreams(
        for category: TwitchCategory,
        limit: Int
    ) async throws -> [FollowedChannel] {
        struct StreamNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let previewImageURL: String?
            let isMature: Bool?
            let broadcaster: Broadcaster?

            struct Broadcaster: Decodable {
                let login: String?
                let displayName: String?
                let profileImageURL: String?
            }
        }
        struct StreamEdge: Decodable {
            let node: StreamNode?
        }
        struct StreamsConn: Decodable {
            let edges: [StreamEdge]?
        }
        struct GameResult: Decodable { let streams: StreamsConn? }
        struct GQLData: Decodable { let game: GameResult? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        // `broadcasterLanguages` is a GQL enum (e.g. EN), not a string, so it is
        // taken from a whitelisted token below — never interpolated from raw
        // input. When the viewer chooses "All", options are omitted entirely so
        // the category's default ordering is preserved.
        let optionsClause: String
        if let token = StreamLanguagePreference.currentToken() {
          optionsClause = ", options: {broadcasterLanguages: [\(token)]}"
        } else {
          optionsClause = ""
        }
        let query = """
            query GameStreams($id: ID!, $first: Int!) {
              game(id: $id) {
                streams(first: $first\(optionsClause)) {
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
                    }
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(
            query: query, variables: ["id": category.id, "first": limit])
        let decoded = try JSONDecoder().decode(GQLEnvelope.self, from: responseData)
        let edges = decoded.data?.game?.streams?.edges ?? []

        return edges.compactMap { edge -> FollowedChannel? in
            guard let node = edge.node,
                  let broadcaster = node.broadcaster,
                  let login = broadcaster.login?.trimmingCharacters(in: .whitespaces),
                  !login.isEmpty
            else { return nil }

            let streamID = node.id ?? UUID().uuidString
            let displayName = broadcaster.displayName?.trimmingCharacters(in: .whitespaces) ?? login
            let title = node.title?.trimmingCharacters(in: .whitespaces) ?? "Live now"
            let previewURL = node.previewImageURL.flatMap { URL(string: $0) }
            let profileURL = broadcaster.profileImageURL.flatMap { URL(string: $0) }

            return FollowedChannel(
                id: streamID,
                login: login,
                displayName: displayName,
                title: title,
                gameName: category.name,
                viewerCount: node.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: profileURL,
                isLive: true,
                isMature: node.isMature ?? false
            )
        }
    }

    // MARK: - GQL Transport

    private func performGQL(query: String, variables: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-Id")
        req.setValue("Twizz/0.1 tvOS", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = ["query": query, "variables": variables]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? -1) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
