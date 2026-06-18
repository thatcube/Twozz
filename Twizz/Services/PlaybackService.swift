import Foundation

/// Resolves a Twitch live channel to an HLS master-playlist URL playable by AVPlayer.
///
/// Mirrors the open-source Streamlink method (basic path only): request a
/// PlaybackAccessToken from Twitch's GraphQL endpoint, then build the Usher HLS URL.
/// Verified working on-device with no client-integrity token, so no server is required.
///
/// This is a non-commercial, ad-respecting client: it does not strip ads.
enum PlaybackError: LocalizedError, Equatable {
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
    let bitrate: Int      // BANDWIDTH from #EXT-X-STREAM-INF
}

/// Result of resolving a channel: the master (adaptive/"Auto") playlist plus the
/// individual quality variants parsed from it, ordered best → worst.
struct StreamPlayback {
    let master: URL
    let qualities: [StreamQuality]
}

struct ChannelMetadata {
    let displayName: String
    let title: String
    let profileImageURL: URL?
}

/// Authoritative live state for a channel, used to decide whether to surface the
/// "offline" empty state. `.unknown` means the lookup itself failed (network,
/// parse, throttling) and must NOT be treated as offline — only `.offline`
/// positively confirms the broadcast has ended.
enum StreamLiveStatus {
    case live
    case offline
    case unknown
}

struct PlaybackService {
    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let accessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    private static let previewURLCache = PreviewURLCache()
    private static let previewURLCacheTTL: TimeInterval = 120
    private static let previewTargetBitrate = 1_500_000
    private static let previewMaxBitrate = 2_200_000
    private static let previewMinBitrate = 350_000

    /// Headers to attach to the AVURLAsset so every variant playlist and media
    /// segment (across Twitch's CDNs and all quality levels) is fetched with the
    /// same identity AVPlayer used for the master playlist. AVPlayer handles
    /// adaptive bitrate (quality switching) automatically from the master playlist.
    static let streamHeaders: [String: String] = [
        "Referer": "https://player.twitch.tv",
        "Origin": "https://player.twitch.tv",
        "User-Agent": userAgent,
    ]

    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

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

    /// Returns a lower-bitrate live stream URL tailored for lightweight previews
    /// (hover cards + ambient blurred backdrop). This reduces decoder/network
    /// pressure versus Source/Auto while preserving live motion.
    static func previewHLSURL(for channel: String) async throws -> URL {
        let normalized = channel.lowercased()
        if let cached = await previewURLCache.value(for: normalized, now: Date()) {
            return cached
        }

        let playback = try await resolve(for: normalized)
        let selected = preferredPreviewQuality(from: playback.qualities)?.url ?? playback.master
        await previewURLCache.insert(
            selected,
            for: normalized,
            expiresAt: Date().addingTimeInterval(previewURLCacheTTL)
        )
        return selected
    }

    /// Best-effort fetch of the current live stream title for overlay UI.
    /// Returns nil if the channel is offline/unavailable or if the request fails.
    static func streamTitle(for channel: String) async -> String? {
        guard let metadata = await channelMetadata(for: channel) else { return nil }
        return metadata.title.isEmpty ? nil : metadata.title
    }

    /// Best-effort fetch of channel display metadata for overlay UI.
    /// Returns nil if unavailable or if the request fails.
    static func channelMetadata(for channel: String) async -> ChannelMetadata? {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = "query ChannelMetadata($login: String!) { user(login: $login) { displayName profileImageURL(width: 70) stream { title } } }"
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": channel.lowercased()],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await networkSession.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let dataObj = json["data"] as? [String: Any] else { return nil }
        guard let userObj = dataObj["user"] as? [String: Any] else { return nil }

        let displayName = (userObj["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamObj = userObj["stream"] as? [String: Any]
        let title = (streamObj?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imageURLString = userObj["profileImageURL"] as? String
        let profileImageURL = imageURLString.flatMap(URL.init(string:))

        return ChannelMetadata(
            displayName: (displayName?.isEmpty == false ? displayName! : channel),
            title: title,
            profileImageURL: profileImageURL
        )
    }

    /// Authoritatively checks whether a channel is currently live.
    ///
    /// Twitch's GraphQL `user.stream` object is non-null only while a broadcast
    /// is active, so it is a far more reliable "is this offline?" signal than the
    /// HLS resolve path (which can briefly keep serving a stale playlist right as
    /// a stream ends). Any failure returns `.unknown` so callers never mistake a
    /// transient network hiccup for the channel going offline.
    static func streamLiveStatus(for channel: String) async -> StreamLiveStatus {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = "query StreamStatus($login: String!) { user(login: $login) { stream { id type } } }"
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": channel.lowercased()],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await networkSession.data(for: req) else { return .unknown }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return .unknown }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        // A GraphQL `errors` array means we can't trust the payload — stay unknown.
        if json["errors"] != nil { return .unknown }
        guard let dataObj = json["data"] as? [String: Any] else { return .unknown }

        // `user` is present in `data` even for offline channels; only `stream`
        // disappears when the broadcast ends. An explicitly-null `user` means the
        // login doesn't exist, which we also treat as offline.
        guard dataObj.keys.contains("user") else { return .unknown }
        let userObj = dataObj["user"] as? [String: Any]
        guard let userObj else { return .offline }

        guard userObj.keys.contains("stream") else { return .unknown }
        let streamObj = userObj["stream"] as? [String: Any]
        return streamObj == nil ? .offline : .live
    }

    // MARK: - On-demand (clips + VODs)

    /// Resolves a clip slug to a directly-playable MP4 URL (highest quality),
    /// signed with the clip's anonymous playback access token.
    static func clipSourceURL(slug: String) async throws -> URL {
        let query = """
            query ClipPlayback($slug: ID!) {
              clip(slug: $slug) {
                playbackAccessToken(params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) {
                  signature value
                }
                videoQualities { quality frameRate sourceURL }
              }
            }
            """

        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": ["slug": slug]]
        )

        let (data, response) = try await networkSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = json["data"] as? [String: Any],
            let clip = dataObj["clip"] as? [String: Any],
            let token = clip["playbackAccessToken"] as? [String: Any],
            let signature = token["signature"] as? String,
            let value = token["value"] as? String,
            let qualities = clip["videoQualities"] as? [[String: Any]]
        else { throw PlaybackError.badResponse }

        // Qualities arrive ordered best -> worst; take the first valid source.
        guard let best = qualities.first(where: { ($0["sourceURL"] as? String)?.isEmpty == false }),
              let source = best["sourceURL"] as? String,
              var comps = URLComponents(string: source)
        else { throw PlaybackError.offline }

        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "sig", value: signature))
        items.append(URLQueryItem(name: "token", value: value))
        comps.queryItems = items
        guard let url = comps.url else { throw PlaybackError.badResponse }
        return url
    }

    /// Resolves a VOD id to a seekable HLS master-playlist URL, signed with the
    /// VOD's anonymous playback access token (the `isVod` path of the same
    /// PlaybackAccessToken operation used for live streams).
    static func vodMasterURL(id: String) async throws -> URL {
        let token = try await fetchVodAccessToken(vodID: id)
        var comps = URLComponents(string: "https://usher.ttvnw.net/vod/\(id).m3u8")!
        comps.queryItems = [
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "p", value: String(Int.random(in: 0..<999999))),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "supported_codecs", value: "h264"),
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
        ]
        let usher = comps.url!
        try await validatePlaylist(usher)
        return usher
    }

    private static func fetchVodAccessToken(vodID: String) async throws -> Token {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "operationName": "PlaybackAccessToken",
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": accessTokenHash]],
            "variables": [
                "isLive": false,
                "login": "",
                "isVod": true,
                "vodID": vodID,
                "playerType": "embed",
                "platform": "site",
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await networkSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaybackError.badResponse
        }
        if let errors = json["errors"] as? [[String: Any]] {
            let msg = (errors.first?["message"] as? String ?? "").lowercased()
            throw msg.contains("integrity") ? PlaybackError.integrityRequired : PlaybackError.badResponse
        }
        guard let dataObj = json["data"] as? [String: Any],
              let tokenObj = dataObj["videoPlaybackAccessToken"] as? [String: Any],
              let value = tokenObj["value"] as? String,
              let signature = tokenObj["signature"] as? String
        else { throw PlaybackError.offline }
        return Token(value: value, signature: signature)
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

        let (data, response) = try await networkSession.data(for: req)
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
        let (_, response) = try await networkSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 { throw PlaybackError.offline }
        guard (200...299).contains(status) else { throw PlaybackError.http(status) }
    }

    /// Fetches the master playlist and parses its variants into `StreamQuality` values.
    /// Also doubles as reachability validation (throws if offline/unreachable).
    private static func fetchQualities(_ master: URL) async throws -> [StreamQuality] {
        var req = URLRequest(url: master)
        for (k, v) in streamHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await networkSession.data(for: req)
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
        var pendingBitrate = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingID = attribute("STABLE-VARIANT-ID", in: line)
                pendingName = attribute("IVS-NAME", in: line) ?? pendingID
                pendingIsSource = attribute("IVS-VARIANT-SOURCE", in: line)?.lowercased() == "source"
                pendingHasResolution = line.contains("RESOLUTION=")
                pendingBitrate = Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                let id = pendingID ?? pendingName ?? "source"
                let nameLower = (pendingName ?? id).lowercased()
                let isAudio = !pendingHasResolution || nameLower.contains("audio")
                let display = displayName(pendingName ?? id, isSource: pendingIsSource, isAudio: isAudio)
                ordered.append(StreamQuality(
                    id: id,
                    name: display,
                    url: url,
                    isAudioOnly: isAudio,
                    bitrate: pendingBitrate
                ))
                pendingName = nil
                pendingID = nil
                pendingIsSource = false
                pendingHasResolution = false
                pendingBitrate = 0
            }
        }
        return ordered.sorted { lhs, rhs in
            if lhs.isAudioOnly != rhs.isAudioOnly { return !lhs.isAudioOnly }
            if lhs.bitrate != rhs.bitrate { return lhs.bitrate > rhs.bitrate }
            return lhs.name < rhs.name
        }
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

    /// Picks a preview-friendly rendition: avoid Source-level bitrates while
    /// also avoiding ultra-low variants that look muddy when blurred fullscreen.
    private static func preferredPreviewQuality(from qualities: [StreamQuality]) -> StreamQuality? {
        let videoQualities = qualities.filter { !$0.isAudioOnly }
        guard !videoQualities.isEmpty else { return nil }

        return videoQualities.min { lhs, rhs in
            let lhsScore = previewScore(lhs.bitrate)
            let rhsScore = previewScore(rhs.bitrate)
            if lhsScore == rhsScore {
                // Tie-break toward the higher bitrate for visual quality.
                return lhs.bitrate > rhs.bitrate
            }
            return lhsScore < rhsScore
        }
    }

    private static func previewScore(_ bitrate: Int) -> Int {
        let clamped = max(0, bitrate)
        let distance = abs(clamped - previewTargetBitrate)
        let overPenalty = clamped > previewMaxBitrate ? (clamped - previewMaxBitrate) * 4 : 0
        let underPenalty = clamped < previewMinBitrate ? (previewMinBitrate - clamped) * 2 : 0
        return distance + overPenalty + underPenalty
    }

    private actor PreviewURLCache {
        private struct Entry {
            let url: URL
            let expiresAt: Date
        }

        private var entries: [String: Entry] = [:]

        func value(for channel: String, now: Date) -> URL? {
            guard let entry = entries[channel] else { return nil }
            guard entry.expiresAt > now else {
                entries[channel] = nil
                return nil
            }
            return entry.url
        }

        func insert(_ url: URL, for channel: String, expiresAt: Date) {
            entries[channel] = Entry(url: url, expiresAt: expiresAt)
        }
    }
}
