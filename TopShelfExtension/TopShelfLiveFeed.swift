import Foundation

/// Fetches fresh, currently-live Twitch streams directly from the Top Shelf
/// extension process so the shelf reflects what is live *right now* instead of a
/// snapshot the app cached the last time it was open.
///
/// This is deliberately small and dependency-free to respect the extension's
/// tight memory/time budget. Every call is best-effort: any failure lets the
/// caller fall back to the last published snapshot.
enum TopShelfLiveFeed {
    private static let maxItemsPerSection = 12
    private static let helixBase = "https://api.twitch.tv/helix"

    /// Builds fresh sections from live Twitch data, reusing the cached
    /// "recommended" set to refresh its liveness and thumbnails. Returns `nil`
    /// when no live content can be produced (the caller then falls back to the
    /// cached snapshot).
    static func run(
        credentials: TopShelfCredentials,
        recommended: TopShelfSnapshot.Section?
    ) async -> [TopShelfSnapshot.Section]? {
        var credentials = credentials

        // Following · Live now — direct, personalised, always current.
        guard let followingItems = try? await followedLive(&credentials) else {
            return nil
        }

        var sections: [TopShelfSnapshot.Section] = []
        let primaryItems = Array(followingItems.prefix(maxItemsPerSection))
        if !primaryItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: "following",
                    title: "Following · Live now",
                    items: primaryItems
                )
            )
        }

        // Recommended — refresh the liveness/thumbnails of the last published
        // recommended set, dropping any channel that has since gone offline.
        if let recommended {
            let primaryLogins = Set(primaryItems.map { $0.login.lowercased() })
            let ids = recommended.items.map(\.id)
            if let liveStreams = try? await liveStreams(forUserIDs: ids, &credentials) {
                let items = liveStreams
                    .filter { !primaryLogins.contains($0.userLogin.lowercased()) }
                    .prefix(maxItemsPerSection)
                    .map(item(from:))
                if !items.isEmpty {
                    sections.append(
                        TopShelfSnapshot.Section(
                            id: "recommended",
                            title: "Recommended",
                            items: Array(items)
                        )
                    )
                }
            }
        }

        return sections.isEmpty ? nil : sections
    }

    // MARK: - Endpoints

    private static func followedLive(
        _ credentials: inout TopShelfCredentials
    ) async throws -> [TopShelfSnapshot.Item] {
        var components = URLComponents(string: "\(helixBase)/streams/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: credentials.userID),
            URLQueryItem(name: "first", value: "\(maxItemsPerSection)")
        ]

        let streams = try await getStreams(url: components.url!, &credentials)
        return streams.filter { $0.type == "live" }.map(item(from:))
    }

    private static func liveStreams(
        forUserIDs ids: [String],
        _ credentials: inout TopShelfCredentials
    ) async throws -> [Stream] {
        let capped = Array(Set(ids)).prefix(100)
        guard !capped.isEmpty else { return [] }

        var components = URLComponents(string: "\(helixBase)/streams")!
        components.queryItems = [URLQueryItem(name: "first", value: "100")]
        components.queryItems?.append(
            contentsOf: capped.map { URLQueryItem(name: "user_id", value: $0) }
        )

        let streams = try await getStreams(url: components.url!, &credentials)
        return streams.filter { $0.type == "live" }
    }

    /// Performs a Helix GET, transparently refreshing the access token once on a
    /// 401 (expired token) and retrying.
    private static func getStreams(
        url: URL,
        _ credentials: inout TopShelfCredentials
    ) async throws -> [Stream] {
        do {
            return try await decodeStreams(url: url, credentials: credentials)
        } catch let error as HTTPError where error.status == 401 {
            try await refreshToken(&credentials)
            return try await decodeStreams(url: url, credentials: credentials)
        }
    }

    private static func decodeStreams(
        url: URL,
        credentials: TopShelfCredentials
    ) async throws -> [Stream] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Twizz/0.1 tvOS TopShelf", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw HTTPError(status: status) }

        return try JSONDecoder().decode(StreamsEnvelope.self, from: data).data
    }

    private static func refreshToken(_ credentials: inout TopShelfCredentials) async throws {
        guard let refreshToken = credentials.refreshToken else { throw HTTPError(status: 401) }

        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(encode(credentials.clientID))"
            + "&grant_type=refresh_token"
            + "&refresh_token=\(encode(refreshToken))"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw HTTPError(status: status) }

        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        credentials.accessToken = refreshed.accessToken
        if let newRefreshToken = refreshed.refreshToken {
            credentials.refreshToken = newRefreshToken
        }

        // Persist for the app and future extension runs (single source of truth).
        TopShelfCredentialStore.updateTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken
        )
    }

    // MARK: - Mapping

    private static func item(from stream: Stream) -> TopShelfSnapshot.Item {
        let thumbnail = stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")

        return TopShelfSnapshot.Item(
            id: stream.userID,
            login: stream.userLogin.lowercased(),
            displayName: stream.userName,
            title: stream.title,
            gameName: stream.gameName,
            thumbnailURL: URL(string: thumbnail),
            viewerCount: stream.viewerCount
        )
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - Wire models

    struct Stream: Decodable {
        let userID: String
        let userLogin: String
        let userName: String
        let gameName: String
        let title: String
        let viewerCount: Int
        let thumbnailURL: String
        let type: String

        enum CodingKeys: String, CodingKey {
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

    private struct StreamsEnvelope: Decodable {
        let data: [Stream]
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct HTTPError: Error {
        let status: Int
    }
}
