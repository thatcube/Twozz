import Foundation

/// Image prewarming collaborator for `FollowedChannelsService`.
///
/// Warms the decoded-image cache for followed channels' *static* avatars
/// whenever the followed list or the full Following directory updates, so the
/// Home "Followed" rail and the directory grid paint each avatar instantly
/// instead of decoding it on the fly while scrolling. Live stream preview
/// thumbnails (`FollowedChannel.thumbnailURL`) are deliberately never
/// prewarmed: they must always reflect the current moment. Best-effort and low
/// priority; idempotent and bounded by the shared `NSCache`.
///
/// Tracks which avatar URLs it has already warmed so each follows/directory
/// update only fetches the *newly added* avatars, instead of re-walking the
/// entire (potentially large) list on every refresh.
///
/// `@MainActor` only to preserve the exact isolation this had on the
/// `@MainActor` service. Foundation-only so it can back a future iOS target.
@MainActor
final class FollowedChannelsAvatarPrewarmer {
  private var warmedURLs: Set<URL> = []

  func prewarm(_ channels: [FollowedChannel]) {
    let newURLs = channels
      .compactMap(\.profileImageURL)
      .filter { warmedURLs.insert($0).inserted }
    guard !newURLs.isEmpty else { return }
    Task(priority: .utility) {
      for url in newURLs {
        if Task.isCancelled { return }
        await ImageMemoryCache.shared.prewarm(url)
      }
    }
  }
}
