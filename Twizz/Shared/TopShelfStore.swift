import Foundation

/// Shared constants and helpers that bridge the main app and the Top Shelf
/// extension. Both targets compile this file.
enum TopShelf {
    /// App Group shared between the app and the Top Shelf extension. Must match
    /// the `com.apple.security.application-groups` entitlement on both targets.
    static let appGroupID = "group.com.thatcube.Twizz"

    /// File name of the snapshot inside the shared container.
    static let snapshotFileName = "topshelf-snapshot.json"

    /// Custom URL scheme Twizz registers for deep links.
    static let deepLinkScheme = "twizz"

    /// Deep-link host used for "open this channel" links.
    static let channelHost = "channel"

    /// Builds the deep link that launches Twizz straight into a channel.
    /// Example: `twizz://channel/pokimane`.
    static func channelDeepLink(login: String) -> URL {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = channelHost
        components.path = "/" + login
        return components.url ?? URL(string: "\(deepLinkScheme)://\(channelHost)/\(login)")!
    }

    /// Extracts the channel login from a deep link, or `nil` if the URL is not
    /// a recognised channel link.
    static func channelLogin(from url: URL) -> String? {
        guard url.scheme?.lowercased() == deepLinkScheme,
              url.host?.lowercased() == channelHost
        else { return nil }

        let login = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }
}

/// Reads and writes the Top Shelf snapshot in the shared App Group container.
enum TopShelfStore {
    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TopShelf.appGroupID
        )
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent(TopShelf.snapshotFileName)
    }

    /// Persists the snapshot. Writes atomically so the extension never reads a
    /// half-written file. Silently no-ops if the App Group is unavailable.
    static func save(_ snapshot: TopShelfSnapshot) {
        guard let url = snapshotURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal: the Top Shelf simply shows nothing/stale content.
        }
    }

    /// Loads the most recent snapshot, or `nil` if none exists yet.
    static func load() -> TopShelfSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TopShelfSnapshot.self, from: data)
    }
}
