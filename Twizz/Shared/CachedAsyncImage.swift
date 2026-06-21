import SDWebImage
import SDWebImageSwiftUI
import SwiftUI

/// Best-effort cache prewarming, backed by SDWebImage's shared image cache. The
/// app standardizes on SDWebImage for all image loading/caching (it already
/// powers chat emotes/badges and decodes WebP/animated content), so prewarming
/// here populates the *same* memory+disk cache that `CachedAsyncImage` and
/// `WebImage` read from — no second parallel cache. As tvOS recycles cards while
/// scrolling, an already-warmed thumbnail paints from cache instead of being
/// re-fetched and re-decoded.
final class ImageMemoryCache: @unchecked Sendable {
  static let shared = ImageMemoryCache()

  private init() {}

  /// Fetch `url` and store it in SDWebImage's cache ahead of time, so a view that
  /// later renders it (via `CachedAsyncImage`) paints on its first frame instead
  /// of popping in once the download finishes. Best-effort, low priority, and
  /// idempotent; a nil URL or an already-cached entry resolves immediately.
  func prewarm(_ url: URL?) async {
    guard let url else { return }
    await withCheckedContinuation { continuation in
      SDWebImageManager.shared.loadImage(
        with: url,
        options: [.lowPriority],
        progress: nil
      ) { _, _, _, _, _, _ in
        continuation.resume()
      }
    }
  }
}

/// Drop-in replacement for the two-closure `AsyncImage`, implemented as a thin
/// wrapper over SDWebImage's `WebImage`. Behavior matches `AsyncImage`:
/// `placeholder` shows until the image resolves, and a nil URL stays on the
/// placeholder. Routing through `WebImage` means media tiles, avatars, banners,
/// and live thumbnails share the single SDWebImage cache (memory + disk, WebP
/// aware) used everywhere else, so scrolling doesn't thrash the decoder and a
/// recycled card paints from cache on its first frame.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
  private let url: URL?
  private let content: (Image) -> Content
  private let placeholder: () -> Placeholder

  init(
    url: URL?,
    @ViewBuilder content: @escaping (Image) -> Content,
    @ViewBuilder placeholder: @escaping () -> Placeholder
  ) {
    self.url = url
    self.content = content
    self.placeholder = placeholder
  }

  var body: some View {
    // Pin animation off so cards/avatars render a single static frame, matching
    // the prior decoded-`UIImage` behavior; animated emotes have their own
    // `AnimatedImage`/`WebImage` paths in chat. SDWebImage serves an already
    // cached image synchronously, so a warmed tile still paints immediately.
    WebImage(url: url, isAnimating: .constant(false)) { image in
      content(image)
    } placeholder: {
      placeholder()
    }
  }
}
