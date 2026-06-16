import Foundation
import Observation

/// Reads a Twitch channel's chat anonymously over IRC-via-WebSocket.
///
/// No login or token required: we connect as a `justinfan` guest, request the
/// `twitch.tv/tags` capability (for display names + colors), and parse PRIVMSG
/// lines into `ChatMessage`s. Sending messages is intentionally out of scope.
@MainActor
@Observable
final class ChatService {
    /// Rolling buffer of the most recent messages (oldest first).
    private(set) var messages: [ChatMessage] = []
    private(set) var isConnected = false
    private(set) var emoteURLs: [String: URL] = [:]
    private(set) var badgeURLs: [String: URL] = [:]

    private let endpoint = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
    private let maxMessages = 250

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var channel: String?
    private var hasSentJoin = false
    private var hasCapAck = false

    /// Connect and join `channel` (case-insensitive). Replaces any existing connection.
    func connect(to channel: String) {
        disconnect()
        let normalized = channel.lowercased()
        self.channel = normalized
        hasSentJoin = false
        hasCapAck = false
        emoteURLs = [:]
        badgeURLs = [:]

        let task = URLSession(configuration: .default).webSocketTask(with: endpoint)
        socket = task
        task.resume()

        send("PASS SCHMOOPIIE")
        send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
        send("CAP REQ :twitch.tv/tags twitch.tv/commands")

        Task { [weak self] in
            guard let self else { return }
            let catalog = await EmoteCatalogService.shared.catalog(for: normalized)
            guard self.channel == normalized else { return }
            self.emoteURLs = catalog
        }

        Task { [weak self] in
            guard let self else { return }
            let catalog = await BadgeCatalogService.shared.catalog(for: normalized)
            guard self.channel == normalized else { return }
            self.badgeURLs = catalog
        }

        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    /// Tear down the connection and clear the buffer.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        messages.removeAll()
        emoteURLs.removeAll()
        badgeURLs.removeAll()
        channel = nil
        hasSentJoin = false
        hasCapAck = false
    }

    private func sendJoinIfNeeded() {
        guard !hasSentJoin, let channel else { return }
        send("JOIN #\(channel)")
        hasSentJoin = true
    }

    private func send(_ command: String) {
        socket?.send(.string(command + "\r\n")) { _ in }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let frame = try await socket.receive()
                switch frame {
                case .string(let text): handle(text)
                case .data(let data): handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                isConnected = false
                break
            }
        }
    }

    private func handle(_ raw: String) {
        // A single frame can batch multiple IRC lines.
        var parsedMessages: [ChatMessage] = []
        for piece in raw.components(separatedBy: "\r\n") where !piece.isEmpty {
            if piece.hasPrefix("PING") {
                send("PONG :tmi.twitch.tv")
                continue
            }
            if piece.contains(" CAP ") && piece.contains(" ACK ") && piece.contains("twitch.tv/tags") {
                hasCapAck = true
                sendJoinIfNeeded()
                continue
            }
            if piece.contains(" 366 ") {  // end-of-NAMES => join confirmed
                isConnected = true
                continue
            }
            if let message = ChatMessage(ircLine: piece) {
                parsedMessages.append(message)
            }
        }

        guard !parsedMessages.isEmpty else { return }
        messages.append(contentsOf: parsedMessages)
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }
}

actor BadgeCatalogService {
    static let shared = BadgeCatalogService()

    private let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    private var cache: [String: [String: URL]] = [:]

    func catalog(for channel: String) async -> [String: URL] {
        let key = channel.lowercased()
        if let cached = cache[key] { return cached }

        let userID = await twitchUserID(for: key)

        async let global = fetchGlobalBadges()
        async let channelBadges = fetchChannelBadges(twitchUserID: userID)

        let merged = (await global).merging(await channelBadges) { _, new in new }
        cache[key] = merged
        return merged
    }

    private func fetchGlobalBadges() async -> [String: URL] {
        guard let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/global") else { return [:] }
        guard let json = await fetchJSON(url: url) else { return [:] }
        return parseBadgeJSON(json)
    }

    private func fetchChannelBadges(twitchUserID: String?) async -> [String: URL] {
        guard let twitchUserID,
              let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/channel?id=\(twitchUserID)") else {
            return [:]
        }
        guard let json = await fetchJSON(url: url) else { return [:] }
        return parseBadgeJSON(json)
    }

    private func parseBadgeJSON(_ json: Any) -> [String: URL] {
        if let dict = json as? [String: Any] {
            return parseLegacyBadgeDisplayJSON(dict)
        }
        if let array = json as? [[String: Any]] {
            return parseIVRBadgeArray(array)
        }
        return [:]
    }

    private func parseLegacyBadgeDisplayJSON(_ json: [String: Any]) -> [String: URL] {
        guard let sets = json["badge_sets"] as? [String: Any] else { return [:] }
        var out: [String: URL] = [:]

        for (setName, setValue) in sets {
            guard let set = setValue as? [String: Any],
                  let versions = set["versions"] as? [String: Any] else { continue }

            for (version, versionValue) in versions {
                guard let meta = versionValue as? [String: Any] else { continue }
                let urlString = (meta["image_url_2x"] as? String)
                    ?? (meta["image_url_4x"] as? String)
                    ?? (meta["image_url_1x"] as? String)
                guard let urlString, let url = URL(string: urlString) else { continue }
                out["\(setName)/\(version)"] = url
            }
        }

        return out
    }

    private func parseIVRBadgeArray(_ sets: [[String: Any]]) -> [String: URL] {
        var out: [String: URL] = [:]

        for set in sets {
            guard let setID = set["set_id"] as? String,
                  let versions = set["versions"] as? [[String: Any]] else { continue }

            for version in versions {
                guard let versionID = version["id"] as? String else { continue }
                let urlString = (version["image_url_2x"] as? String)
                    ?? (version["image_url_4x"] as? String)
                    ?? (version["image_url_1x"] as? String)
                guard let urlString, let url = URL(string: urlString) else { continue }
                out["\(setID)/\(versionID)"] = url
            }
        }

        return out
    }

    private func twitchUserID(for login: String) async -> String? {
        if let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let ivrURL = URL(string: "https://api.ivr.fi/v2/twitch/user?login=\(encoded)"),
           let payload = await fetchJSON(url: ivrURL) as? [[String: Any]],
           let id = payload.first?["id"] as? String,
           !id.isEmpty {
            return id
        }

        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = "query UserID($login: String!) { user(login: $login) { id } }"
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": login],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let json = await fetchJSON(request: req) as? [String: Any] else { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }
        guard let user = data["user"] as? [String: Any] else { return nil }
        return user["id"] as? String
    }

    private func fetchJSON(url: URL) async -> Any? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func fetchJSON(request: URLRequest) async -> Any? {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
