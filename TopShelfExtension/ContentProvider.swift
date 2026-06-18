import TVServices

/// Supplies content for the tvOS Top Shelf — the banner shown above the app
/// grid when Twizz is in the top row of the Home screen.
///
/// This runs in a separate, short-lived process. It fetches the currently-live
/// streams directly from Twitch at render time so the shelf always reflects
/// what is live *right now* — fixing stale/offline cards and missing
/// thumbnails. If the fresh fetch fails (offline, signed out, expired session),
/// it falls back to the snapshot the main app last published.
final class ContentProvider: TVTopShelfContentProvider {
    /// Upper bound on the live fetch. The system allows ~60s, but the shelf
    /// should appear quickly; beyond this we render the cached snapshot instead.
    private static let fetchTimeout: Double = 8

    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        // The system's completion handler is not `Sendable`; `nonisolated(unsafe)`
        // lets it be called from the async task that performs the live fetch.
        nonisolated(unsafe) let handler = completionHandler
        Task {
            let content = await Self.makeContent()
            handler(content)
        }
    }

    private static func makeContent() async -> TVTopShelfContent? {
        let sections = await resolveSections()
        guard let sections, !sections.isEmpty else { return nil }

        let collections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] =
            sections.compactMap { section in
                let items = section.items.map(makeItem)
                guard !items.isEmpty else { return nil }
                let collection = TVTopShelfItemCollection(items: items)
                collection.title = section.title
                return collection
            }

        guard !collections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: collections)
    }

    /// Returns fresh live sections when possible, otherwise the cached snapshot.
    private static func resolveSections() async -> [TopShelfSnapshot.Section]? {
        let cached = TopShelfStore.load()

        if let fresh = await freshSections(cached: cached) {
            // Keep the cached snapshot current so the fallback stays fresh too.
            TopShelfStore.save(TopShelfSnapshot(sections: fresh))
            return fresh
        }

        return cached?.sections
    }

    private static func freshSections(
        cached: TopShelfSnapshot?
    ) async -> [TopShelfSnapshot.Section]? {
        guard let credentials = TopShelfCredentialStore.load() else { return nil }
        let recommended = cached?.sections.first { $0.id == "recommended" }

        return await withTimeout(seconds: fetchTimeout) {
            await TopShelfLiveFeed.run(credentials: credentials, recommended: recommended)
        }
    }

    /// Runs an async operation with a timeout. Returns `nil` if the operation
    /// does not finish in time, letting the caller fall back to cached content.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func makeItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
        shelfItem.title = item.displayName
        shelfItem.imageShape = .hdtv

        if let thumbnailURL = item.thumbnailURL {
            shelfItem.setImageURL(thumbnailURL, for: .screenScale1x)
            shelfItem.setImageURL(thumbnailURL, for: .screenScale2x)
        }

        let deepLink = TopShelf.channelDeepLink(login: item.login)
        let action = TVTopShelfAction(url: deepLink)
        shelfItem.displayAction = action
        shelfItem.playAction = action

        return shelfItem
    }
}
