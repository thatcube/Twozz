import Foundation

/// Which platform a chat message originated from.
enum ChatSource: String, Codable {
    case twitch
    case youtube
}

/// A single chat line parsed from Twitch IRC or YouTube Live Chat.
struct ChatMessage: Identifiable {
    let id = UUID()
    let username: String
    /// Twitch user color as a `#RRGGBB` hex string, if the user set one.
    let colorHex: String?
    /// Twitch badge keys from IRC `badges` tag, e.g. `subscriber/6`.
    let badgeKeys: [String]
    let text: String
    /// Message-scoped native Twitch emotes parsed from IRC `emotes` tag.
    /// Key = emote token in this message, value = CDN image URL.
    let twitchEmoteURLs: [String: URL]
    /// Message-scoped YouTube emotes parsed from live chat message runs.
    /// Key = emote token in this message, value = CDN image URL.
    let youtubeEmoteURLs: [String: URL]
    /// True for `/me` action messages (rendered in the user's color).
    let isAction: Bool
    /// The platform this message came from (Twitch or YouTube).
    let source: ChatSource
    /// Timestamp when the message was received (for chronological merging).
    let timestamp: Date
}

extension ChatMessage {
    /// Parse one raw Twitch IRC line (tags + PRIVMSG) into a `ChatMessage`.
    /// Returns `nil` for any non-PRIVMSG line (PING, JOIN, server notices, …).
    init?(ircLine line: String) {
        var rest = Substring(line)
        var tags: [String: String] = [:]

        // Tags section: "@key=value;key=value " (present because we request twitch.tv/tags).
        if rest.first == "@" {
            guard let spaceIdx = rest.firstIndex(of: " ") else { return nil }
            let tagString = rest[rest.index(after: rest.startIndex)..<spaceIdx]
            for pair in tagString.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 {
                    tags[String(kv[0])] = String(kv[1])
                } else if kv.count == 1 {
                    tags[String(kv[0])] = ""
                }
            }
            rest = rest[rest.index(after: spaceIdx)...]
        }

        // Prefix: ":nick!user@host ".
        guard rest.first == ":", let prefixEnd = rest.firstIndex(of: " ") else { return nil }
        let prefix = rest[rest.index(after: rest.startIndex)..<prefixEnd]
        let nickFromPrefix = prefix.split(separator: "!").first.map(String.init) ?? "user"
        rest = rest[rest.index(after: prefixEnd)...]

        // Command: "PRIVMSG #channel :message text".
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "PRIVMSG" else { return nil }

        var message = String(parts[2])
        if message.first == ":" { message.removeFirst() }

        // Detect /me actions: "\u{1}ACTION text\u{1}".
        var action = false
        if message.hasPrefix("\u{1}ACTION ") && message.hasSuffix("\u{1}") {
            action = true
            message = String(message.dropFirst("\u{1}ACTION ".count).dropLast())
        }

        let display = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? nickFromPrefix
        let color = tags["color"].flatMap { $0.isEmpty ? nil : $0 }
        let badges = Self.mergeBadgeKeys(
            explicit: Self.parseBadgeKeys(tags["badges"]),
            inferred: Self.inferRoleBadgeKeys(from: tags, nick: nickFromPrefix)
        )
        let twitchEmoteURLs = Self.parseTwitchEmoteURLs(tags["emotes"], in: message)

        self.username = display
        self.colorHex = color
        self.badgeKeys = badges
        self.text = message
        self.twitchEmoteURLs = twitchEmoteURLs
        self.youtubeEmoteURLs = [:]
        self.isAction = action
        self.source = .twitch
        self.timestamp = Date()
    }

    init(
        youtubeAuthor: String,
        text: String,
        youtubeEmoteURLs: [String: URL],
        timestamp: Date = Date()
    ) {
        self.username = youtubeAuthor
        self.colorHex = nil
        self.badgeKeys = []
        self.text = text
        self.twitchEmoteURLs = [:]
        self.youtubeEmoteURLs = youtubeEmoteURLs
        self.isAction = false
        self.source = .youtube
        self.timestamp = timestamp
    }

    private static func parseBadgeKeys(_ tag: String?) -> [String] {
        guard let tag, !tag.isEmpty else { return [] }
        return tag
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func inferRoleBadgeKeys(from tags: [String: String], nick: String) -> [String] {
        var out: [String] = []

        if tags["mod"] == "1" { out.append("moderator/1") }
        if tags["subscriber"] == "1" { out.append("subscriber/1") }
        if tags["vip"] == "1" { out.append("vip/1") }
        if tags["turbo"] == "1" { out.append("turbo/1") }

        let userType = tags["user-type"]?.lowercased() ?? ""
        if userType == "staff" || userType == "admin" || userType == "global_mod" {
            out.append("staff/1")
        }

        if let roomID = tags["room-id"], let userID = tags["user-id"], roomID == userID {
            out.append("broadcaster/1")
        }

        return out
    }

    private static func mergeBadgeKeys(explicit: [String], inferred: [String]) -> [String] {
        var merged = explicit
        for key in inferred where !merged.contains(key) {
            merged.append(key)
        }
        return merged
    }

    private static func parseTwitchEmoteURLs(_ tag: String?, in message: String) -> [String: URL] {
        guard let tag, !tag.isEmpty else { return [:] }

        // Format: emoteID:start-end,start-end/emoteID:start-end
        let text = message as NSString
        var out: [String: URL] = [:]

        for group in tag.split(separator: "/") {
            let parts = group.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let emoteID = String(parts[0])
            let ranges = parts[1].split(separator: ",")

            for rangeToken in ranges {
                let bounds = rangeToken.split(separator: "-", maxSplits: 1)
                guard bounds.count == 2,
                      let start = Int(bounds[0]),
                      let endInclusive = Int(bounds[1]) else { continue }

                let length = endInclusive - start + 1
                guard start >= 0, length > 0, start + length <= text.length else { continue }

                let token = text.substring(with: NSRange(location: start, length: length))
                guard !token.isEmpty,
                      let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteID)/default/dark/2.0")
                else { continue }

                out[token] = url
            }
        }

        return out
    }
}
