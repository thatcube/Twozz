import TVServices

/// Supplies content for the tvOS Top Shelf — the banner shown above the app
/// grid when Twizz is in the top row of the Home screen.
///
/// This runs in a separate, short-lived process and must not perform network or
/// auth work. It simply renders the snapshot the main app published into the
/// shared App Group container.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        let snapshot = TopShelfStore.load()
        TopShelfStore.appendExtensionBreadcrumb(
            "invoked; snapshot=\(snapshot != nil) sections=\(snapshot?.sections.count ?? -1)"
        )

        guard let snapshot, !snapshot.sections.isEmpty else {
            TopShelfStore.appendExtensionBreadcrumb("returning nil (no snapshot/sections)")
            completionHandler(nil)
            return
        }

        let collections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] =
            snapshot.sections.compactMap { section in
                let items = section.items.map(makeItem)
                guard !items.isEmpty else { return nil }
                let collection = TVTopShelfItemCollection(items: items)
                collection.title = section.title
                return collection
            }

        guard !collections.isEmpty else {
            TopShelfStore.appendExtensionBreadcrumb("returning nil (no collections)")
            completionHandler(nil)
            return
        }

        TopShelfStore.appendExtensionBreadcrumb("returning \(collections.count) collections")
        completionHandler(TVTopShelfSectionedContent(sections: collections))
    }

    private func makeItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
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
