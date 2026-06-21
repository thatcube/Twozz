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

/// Centralized policy for **live** stream preview thumbnails. These must NEVER be
/// served from a cache — a live preview has to reflect the current moment of the
/// stream — but they MAY be requested at a smaller size for smaller cards.
///
/// `LiveThumbnail` is the single render-time path for live previews everywhere in
/// the app (stream cards and the channel page). Unlike `CachedAsyncImage`, it
/// deliberately routes through plain `AsyncImage` (no SDWebImage disk/memory
/// cache) and rewrites every URL so it:
///   1. carries a per-presentation cache-busting token (so even `URLSession`'s
///      own `URLCache` can't hand back a stale frame), and
///   2. requests the Twitch preview at the size bucket that fits the card it's
///      rendered into, instead of always pulling the full 640x360.
enum LiveThumbnailPolicy {
  /// Twitch live-preview size buckets (`{width}x{height}`), smallest first.
  static let sizeBuckets: [(width: Int, height: Int)] = [
    (320, 180), (480, 270), (640, 360),
  ]

  /// Smallest bucket whose pixel width covers the rendered card width, so a
  /// 6-across card fetches 320x180 while a 2-across card fetches 640x360.
  static func bucket(forRenderedWidth width: CGFloat, scale: CGFloat) -> (width: Int, height: Int) {
    let neededPixels = max(width, 1) * max(scale, 1)
    return sizeBuckets.first { CGFloat($0.width) >= neededPixels } ?? sizeBuckets[sizeBuckets.count - 1]
  }

  /// Produce a guaranteed-fresh, card-sized URL from a live preview URL.
  static func freshURL(from url: URL?, renderedWidth: CGFloat, scale: CGFloat, token: String) -> URL? {
    guard let url else { return nil }
    let bucket = bucket(forRenderedWidth: renderedWidth, scale: scale)
    let sized = resizingTwitchPreview(url, to: bucket)
    return appendingCacheBust(sized, token: token)
  }

  /// Rewrite the `-{width}x{height}.jpg` segment of a Twitch preview URL. Returns
  /// the URL unchanged when it doesn't match (e.g. a YouTube `hqdefault.jpg`,
  /// which has no resizable dimension segment).
  private static func resizingTwitchPreview(_ url: URL, to size: (width: Int, height: Int)) -> URL {
    let absolute = url.absoluteString
    guard let regex = try? NSRegularExpression(pattern: "-\\d+x\\d+(?=\\.jpg)") else { return url }
    let range = NSRange(absolute.startIndex..., in: absolute)
    guard regex.firstMatch(in: absolute, options: [], range: range) != nil else { return url }
    let replaced = regex.stringByReplacingMatches(
      in: absolute, options: [], range: range, withTemplate: "-\(size.width)x\(size.height)")
    return URL(string: replaced) ?? url
  }

  private static func appendingCacheBust(_ url: URL, token: String) -> URL {
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var items = comps.queryItems ?? []
    items.append(URLQueryItem(name: "cb", value: token))
    comps.queryItems = items
    return comps.url ?? url
  }
}

/// Drop-in, **non-caching** image view for live stream preview thumbnails. Mirrors
/// the `CachedAsyncImage` API but enforces `LiveThumbnailPolicy`: it measures the
/// card it's rendered into, requests the matching Twitch size bucket, and appends
/// a fresh cache-busting token on every presentation so the preview is always the
/// current moment of the stream. Static art (avatars, box art, VOD/clip
/// thumbnails, banners) must keep using `CachedAsyncImage`.
struct LiveThumbnail<Content: View, Placeholder: View>: View {
  private let url: URL?
  private let content: (Image) -> Content
  private let placeholder: () -> Placeholder

  @Environment(\.displayScale) private var displayScale
  @State private var cacheBustToken = UUID().uuidString

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
    GeometryReader { geo in
      AsyncImage(
        url: LiveThumbnailPolicy.freshURL(
          from: url, renderedWidth: geo.size.width, scale: displayScale, token: cacheBustToken)
      ) { image in
        content(image)
      } placeholder: {
        placeholder()
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .clipped()
    }
    // Re-bust on every appearance so a recycled/re-shown card refetches fresh
    // rather than reusing the token (and therefore the URL) from last time.
    .onAppear { cacheBustToken = UUID().uuidString }
  }
}

#if canImport(UIKit)
  import UIKit
#endif

/// One-time bounds + memory-pressure handling for the shared SDWebImage cache.
///
/// Without this the cache is unbounded, which on a memory-constrained Apple TV
/// lets decoded thumbnails/avatars/emotes grow until the system jettisons the
/// app. `configure()` caps the in-memory and on-disk footprints and wires up
/// memory-warning / background notifications to flush the in-memory image cache
/// (the disk cache survives so warmed art still paints across launches).
enum ImageCacheConfigurator {
  /// ~96 MB of decoded images held in memory.
  private static let maxMemoryCost: UInt = 96 * 1024 * 1024
  /// ~256 MB of encoded images on disk.
  private static let maxDiskSize: UInt = 256 * 1024 * 1024
  /// Evict disk entries untouched for a week.
  private static let maxDiskAge: TimeInterval = 7 * 24 * 60 * 60

  @MainActor private static var didConfigure = false

  @MainActor
  static func configure() {
    guard !didConfigure else { return }
    didConfigure = true

    let config = SDImageCache.shared.config
    config.maxMemoryCost = maxMemoryCost
    config.maxDiskSize = maxDiskSize
    config.maxDiskAge = maxDiskAge

    #if canImport(UIKit)
      let center = NotificationCenter.default
      center.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil, queue: .main
      ) { _ in
        SDImageCache.shared.clearMemory()
      }
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil, queue: .main
      ) { _ in
        SDImageCache.shared.clearMemory()
      }
    #endif
  }
}
