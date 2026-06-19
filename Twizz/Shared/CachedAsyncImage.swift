import SwiftUI
import UIKit

/// A small in-memory cache of decoded images, keyed by URL. `AsyncImage` keeps no
/// cache of its own, so as tvOS recycles cards during scrolling it re-fetches and
/// re-decodes the same thumbnails repeatedly — the dominant cost when flicking
/// through the channel page's clip/VOD rails. This keeps decoded `UIImage`s around
/// so a recycled card paints instantly. `NSCache` is thread-safe and evicts under
/// memory pressure on its own.
final class ImageMemoryCache: @unchecked Sendable {
  static let shared = ImageMemoryCache()
  private let cache = NSCache<NSURL, UIImage>()

  private init() {
    cache.countLimit = 240
  }

  func image(for url: URL) -> UIImage? {
    cache.object(forKey: url as NSURL)
  }

  func insert(_ image: UIImage, for url: URL) {
    cache.setObject(image, forKey: url as NSURL)
  }
}

/// Drop-in replacement for the two-closure `AsyncImage` that adds a decoded-image
/// memory cache (and rides the shared `URLCache` for the network layer). Behavior
/// matches `AsyncImage`: `placeholder` shows until the image resolves, and a nil
/// URL stays on the placeholder. Used for the channel page's media tiles, avatar,
/// banner, and live thumbnail so scrolling doesn't thrash the decoder.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
  private let url: URL?
  private let content: (Image) -> Content
  private let placeholder: () -> Placeholder

  @State private var uiImage: UIImage?

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
    Group {
      if let uiImage {
        content(Image(uiImage: uiImage))
      } else {
        placeholder()
      }
    }
    .task(id: url) { await load() }
  }

  private func load() async {
    guard let url else {
      uiImage = nil
      return
    }

    if let cached = ImageMemoryCache.shared.image(for: url) {
      uiImage = cached
      return
    }

    uiImage = nil
    guard let prepared = await Self.fetchAndDecode(url) else { return }
    guard !Task.isCancelled else { return }
    ImageMemoryCache.shared.insert(prepared, for: url)
    uiImage = prepared
  }

  /// Fetches and *fully decodes* the image off the main thread. `UIImage(data:)`
  /// alone defers decoding until the image is first drawn — which lands on the
  /// main thread mid-scroll and stutters as each new tile appears. Forcing the
  /// decode here with `preparingForDisplay()` (and being `nonisolated` so it runs
  /// on the cooperative pool, not the MainActor) hands SwiftUI a ready-to-blit
  /// bitmap, so painting a recycled card costs nothing on the main thread.
  nonisolated private static func fetchAndDecode(_ url: URL) async -> UIImage? {
    var request = URLRequest(url: url)
    request.cachePolicy = .returnCacheDataElseLoad
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let image = UIImage(data: data) else { return nil }
    return image.preparingForDisplay() ?? image
  }
}
