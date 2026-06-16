import Foundation

/// Resolves a Twitch live channel to an HLS master-playlist URL playable by AVPlayer.
///
/// Mirrors the open-source Streamlink method (basic path only): request a
/// PlaybackAccessToken from Twitch's GraphQL endpoint, then build the Usher HLS URL.
/// Verified working on-device with no client-integrity token, so no server is required.
///
/// This is a non-commercial, ad-respecting client: it does not strip ads.
enum PlaybackError: LocalizedError {
    case http(Int)
    case integrityRequired
    case offline
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Network error (HTTP \(code))."
        case .integrityRequired: return "Twitch requires extra verification for this channel."
        case .offline: return "This channel is offline or doesn't exist."
        case .badResponse: return "Unexpected response from Twitch."
        }
    }
}

struct PlaybackService {
    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let accessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    private struct Token {
        let value: String
        let signature: String
    }

    /// Returns the HLS master playlist URL for a live channel.
    static func hlsURL(for channel: String) async throws -> URL {
        let token = try await fetchAccessToken(channel: channel)
        let usher = buildUsherURL(channel: channel, token: token)
        // Validate the playlist is reachable before handing it to AVPlayer.
        try await validatePlaylist(usher)
        return usher
    }

    private static func fetchAccessToken(channel: String) async throws -> Token {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "operationName": "PlaybackAccessToken",
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": accessTokenHash]],
            "variables": [
                "isLive": true,
                "login": channel,
                "isVod": false,
                "vodID": "",
                "playerType": "embed",
                "platform": "site",
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaybackError.badResponse
        }
        if let errors = json["errors"] as? [[String: Any]] {
            let msg = (errors.first?["message"] as? String ?? "").lowercased()
            throw msg.contains("integrity") ? PlaybackError.integrityRequired : PlaybackError.badResponse
        }
        guard let dataObj = json["data"] as? [String: Any] else { throw PlaybackError.badResponse }
        guard let tokenObj = dataObj["streamPlaybackAccessToken"] as? [String: Any] else {
            throw PlaybackError.offline
        }
        guard let value = tokenObj["value"] as? String,
              let signature = tokenObj["signature"] as? String else {
            throw PlaybackError.badResponse
        }
        return Token(value: value, signature: signature)
    }

    private static func buildUsherURL(channel: String, token: Token) -> URL {
        var comps = URLComponents(string: "https://usher.ttvnw.net/api/v2/channel/hls/\(channel.lowercased()).m3u8")!
        comps.queryItems = [
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "p", value: String(Int.random(in: 0..<999999))),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "supported_codecs", value: "h264"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
        ]
        return comps.url!
    }

    private static func validatePlaylist(_ url: URL) async throws {
        var req = URLRequest(url: url)
        req.setValue("https://player.twitch.tv", forHTTPHeaderField: "Referer")
        req.setValue("https://player.twitch.tv", forHTTPHeaderField: "Origin")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { throw PlaybackError.offline }
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }
    }
}
