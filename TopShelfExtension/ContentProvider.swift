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
        guard let snapshot = TopShelfStore.load(), !snapshot.sections.isEmpty else {
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
            completionHandler(nil)
            return
        }

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
