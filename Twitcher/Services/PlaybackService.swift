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

/// One selectable quality from the HLS master playlist (e.g. "1080p60", "720p", "Audio Only").
struct StreamQuality: Identifiable, Hashable {
    let id: String        // HLS group-id, e.g. "chunked", "720p60", "audio_only"
    let name: String      // display name, e.g. "1080p60 (Source)"
    let url: URL          // direct media-playlist URL for this single quality
    let isAudioOnly: Bool
}

/// Result of resolving a channel: the master (adaptive/"Auto") playlist plus the
/// individual quality variants parsed from it, ordered best → worst.
struct StreamPlayback {
    let master: URL
    let qualities: [StreamQuality]
}

struct PlaybackService {
    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let accessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    /// Headers to attach to the AVURLAsset so every variant playlist and media
    /// segment (across Twitch's CDNs and all quality levels) is fetched with the
    /// same identity AVPlayer used for the master playlist. AVPlayer handles
    /// adaptive bitrate (quality switching) automatically from the master playlist.
    static let streamHeaders: [String: String] = [
        "Referer": "https://player.twitch.tv",
        "Origin": "https://player.twitch.tv",
        "User-Agent": userAgent,
    ]

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

    /// Resolves a channel to its master playlist plus the list of selectable
    /// quality variants parsed from that playlist.
    static func resolve(for channel: String) async throws -> StreamPlayback {
        let token = try await fetchAccessToken(channel: channel)
        let master = buildUsherURL(channel: channel, token: token)
        let qualities = try await fetchQualities(master)
        return StreamPlayback(master: master, qualities: qualities)
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
        for (k, v) in streamHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (_, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { throw PlaybackError.offline }
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }
    }

    /// Fetches the master playlist and parses its variants into `StreamQuality` values.
    /// Also doubles as reachability validation (throws if offline/unreachable).
    private static func fetchQualities(_ master: URL) async throws -> [StreamQuality] {
        var req = URLRequest(url: master)
        for (k, v) in streamHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { throw PlaybackError.offline }
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }

        let text = String(decoding: data, as: UTF8.self)
        return parseMaster(text)
    }

    /// Parses a Twitch HLS master playlist. Each rendition is a single
    /// `#EXT-X-STREAM-INF` line carrying `IVS-NAME="720p60"` (display name),
    /// `IVS-VARIANT-SOURCE="source"` (marks the highest/source rendition) and
    /// (for video) a `RESOLUTION=` attribute, immediately followed by the URL.
    static func parseMaster(_ text: String) -> [StreamQuality] {
        var ordered: [StreamQuality] = []
        let lines = text.components(separatedBy: .newlines)

        var pendingName: String?
        var pendingID: String?
        var pendingIsSource = false
        var pendingHasResolution = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingID = attribute("STABLE-VARIANT-ID", in: line)
                pendingName = attribute("IVS-NAME", in: line) ?? pendingID
                pendingIsSource = attribute("IVS-VARIANT-SOURCE", in: line)?.lowercased() == "source"
                pendingHasResolution = line.contains("RESOLUTION=")
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                let id = pendingID ?? pendingName ?? "source"
                let nameLower = (pendingName ?? id).lowercased()
                let isAudio = !pendingHasResolution || nameLower.contains("audio")
                let display = displayName(pendingName ?? id, isSource: pendingIsSource, isAudio: isAudio)
                ordered.append(StreamQuality(id: id, name: display, url: url, isAudioOnly: isAudio))
                pendingName = nil
                pendingID = nil
                pendingIsSource = false
                pendingHasResolution = false
            }
        }
        return ordered
    }

    /// Extracts a quoted or bare attribute value from an HLS tag line.
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.first == "\"" {
            let afterQuote = rest.dropFirst()
            if let end = afterQuote.firstIndex(of: "\"") {
                return String(afterQuote[..<end])
            }
            return nil
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Normalizes Twitch's rendition name into a clean display label.
    private static func displayName(_ name: String, isSource: Bool, isAudio: Bool) -> String {
        if isAudio { return "Audio Only" }
        let base = name.replacingOccurrences(of: " (source)", with: "")
                       .replacingOccurrences(of: " (Source)", with: "")
        return isSource ? "\(base) (Source)" : base
    }
}
