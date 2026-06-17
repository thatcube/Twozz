import Foundation

/// Bridges the app's live channel data into the shared Top Shelf snapshot.
///
/// The Top Shelf extension is a separate process that cannot see the app's
/// in-memory state, so the app publishes a small JSON snapshot into the shared
/// App Group container whenever its data refreshes. The extension just renders
/// whatever it finds — no networking or auth in the extension itself.
@MainActor
enum TopShelfPublisher {
    /// Maximum items per carousel. The Top Shelf has limited horizontal space
    /// and the system only shows a handful before "see all".
    private static let maxItemsPerSection = 12

    /// Builds and persists a snapshot from the current Following + Trending
    /// data. `isUsingDemoData` flips the primary section's title between a
    /// personalised "Following" feed and an anonymous "Trending" feed.
    static func publish(
        followed: [FollowedChannel],
        isUsingDemoData: Bool,
        recommended: [FollowedChannel]
    ) {
        var sections: [TopShelfSnapshot.Section] = []

        let primaryItems = makeItems(from: followed.filter(\.isLive))
        if !primaryItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: isUsingDemoData ? "trending" : "following",
                    title: isUsingDemoData ? "Trending now" : "Following · Live now",
                    items: primaryItems
                )
            )
        }

        // Avoid duplicating channels already shown in the primary section.
        let primaryLogins = Set(primaryItems.map(\.login))
        let recommendedItems = makeItems(
            from: recommended.filter { $0.isLive && !primaryLogins.contains($0.login.lowercased()) }
        )
        if !recommendedItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: "recommended",
                    title: "Recommended",
                    items: recommendedItems
                )
            )
        }

        // If nothing live is available, clear the snapshot so the Top Shelf
        // falls back to the app's default banner instead of stale content.
        guard !sections.isEmpty else {
            TopShelfStore.save(TopShelfSnapshot(sections: []))
            return
        }

        TopShelfStore.save(TopShelfSnapshot(sections: sections))
    }

    private static func makeItems(from channels: [FollowedChannel]) -> [TopShelfSnapshot.Item] {
        channels.prefix(maxItemsPerSection).map { channel in
            TopShelfSnapshot.Item(
                id: channel.id,
                login: channel.login.lowercased(),
                displayName: channel.displayName,
                title: channel.title,
                gameName: channel.gameName,
                thumbnailURL: channel.thumbnailURL,
                viewerCount: channel.viewerCount
            )
        }
    }
}
