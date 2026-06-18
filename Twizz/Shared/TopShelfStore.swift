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

    /// Directory inside the shared container where the snapshot lives.
    ///
    /// tvOS keeps the App Group container *root* read-only — only
    /// subdirectories such as `Library/Caches` are writable. Writing the
    /// snapshot to the root fails with `NSFileWriteNoPermissionError` (513), so
    /// it is stored under `Library/Caches` instead. Both the app and the
    /// extension resolve the same path through this property.
    private static var snapshotDirectoryURL: URL? {
        containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    private static var snapshotURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent(TopShelf.snapshotFileName)
    }

    /// Records the outcome of the most recent `save` so the in-app diagnostics
    /// can surface why a write failed instead of silently swallowing it.
    private(set) nonisolated(unsafe) static var lastSaveOutcome: String?

    /// Persists the snapshot into the shared App Group container.
    ///
    /// The container directory is created on demand first: the system hands back
    /// a valid container URL even before the directory itself exists on disk, so
    /// a plain atomic write can fail with a "no permission" / "no such file"
    /// error. Creating the directory (and falling back to a non-atomic write)
    /// makes the first publish succeed.
    static func save(_ snapshot: TopShelfSnapshot) {
        guard let directory = snapshotDirectoryURL, let url = snapshotURL else {
            lastSaveOutcome = "save skipped: no container URL"
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Atomic writes stage a temp file + rename, which can be denied
                // in some sandboxed container states; retry with a direct write.
                try data.write(to: url)
            }
            lastSaveOutcome = "saved \(data.count) bytes OK"
        } catch {
            lastSaveOutcome = "save failed: \(error.localizedDescription)"
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

    /// Appends a timestamped breadcrumb so the (otherwise invisible) Top Shelf
    /// extension process can be observed off-device. Writes to the process's own
    /// Caches (always available) and records whether the shared App Group
    /// container is reachable. Temporary diagnostic.
    static func appendExtensionBreadcrumb(_ message: String) {
        let groupStatus = containerURL?.path ?? "GROUP_CONTAINER_NIL"
        let line = "\(ISO8601DateFormatter().string(from: Date())) [group=\(groupStatus)] \(message)\n"

        // Own sandbox caches — does not require the App Group entitlement.
        if let ownCaches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first {
            appendLine(line, to: ownCaches.appendingPathComponent("topshelf-ext-log.txt"))
        }

        // Also try the shared container (only works if the group is reachable).
        if let directory = snapshotDirectoryURL {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            appendLine(line, to: directory.appendingPathComponent("topshelf-ext-log.txt"))
        }
    }

    private static func appendLine(_ line: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Whether the shared App Group container is reachable. If this is `false`
    /// the entitlement/provisioning for the App Group is not active at runtime
    /// and neither the app nor the extension can exchange the snapshot.
    static var isContainerAvailable: Bool {
        containerURL != nil
    }

    /// Whether a snapshot file has actually been written to the container yet.
    static var snapshotFileExists: Bool {
        guard let url = snapshotURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Human-readable one-line summary of the current Top Shelf state, used by
    /// the in-app diagnostics row to pinpoint where publishing breaks.
    static func diagnosticsSummary() -> String {
        guard isContainerAvailable else {
            return "App Group container unavailable (entitlement not active)."
        }
        guard snapshotFileExists else {
            let outcome = lastSaveOutcome ?? "save never attempted"
            return "Container OK, but no snapshot file. Last save: \(outcome)."
        }
        guard let snapshot = load() else {
            return "Snapshot file exists but could not be decoded."
        }
        let itemCount = snapshot.sections.reduce(0) { $0 + $1.items.count }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let when = formatter.string(from: snapshot.generatedAt)
        let outcome = lastSaveOutcome.map { " [\($0)]" } ?? ""
        return "\(snapshot.sections.count) section(s), \(itemCount) item(s) — written \(when).\(outcome)"
    }
}
