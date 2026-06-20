import SwiftUI

/// The shared loading state for every surface where a stream can be watched —
/// the full player, multiview tiles, and the clip player.
///
/// Instead of a bare spinner on a black screen, it shows the stream's own
/// thumbnail blurred and dimmed behind a centered native cluster (channel
/// avatar, name, and the system `ProgressView`). The blurred art doubles as a
/// poster that fills the frame immediately, so opening a stream reads as a quick
/// sharpen into live video rather than a black "Loading…" gap.
///
/// Theme-aware per the repo conventions: over real stream art the foreground is
/// white (the dark scrim guarantees legibility, matching over-video chrome), and
/// when there's no art it falls back to the active `ThemePalette` so the Light
/// theme stays legible instead of assuming a dark background.
struct StreamLoadingView: View {
  /// The stream's last frame, shown blurred as the backdrop. `nil` falls back to
  /// the theme's player backdrop.
  var posterURL: URL? = nil
  /// Channel avatar shown above the name. Hidden in `compact` tiles.
  var avatarURL: URL? = nil
  /// Channel display name or content title. Hidden in `compact` tiles when nil.
  var title: String? = nil
  /// Tight layout for multiview filmstrip tiles: smaller blur, no avatar, smaller
  /// spinner and type.
  var compact: Bool = false

  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  private var hasArt: Bool { posterURL != nil }

  /// White over real art (the scrim keeps it legible, like over-video chrome);
  /// theme-derived otherwise so Light mode doesn't paint white-on-white.
  private var foreground: Color {
    hasArt ? .white : (palette.isLight ? .black.opacity(0.85) : .white)
  }

  var body: some View {
    ZStack {
      backdrop
      cluster
    }
    .allowsHitTesting(false)
    .onAppear {
      guard !reduceMotion, !compact, avatarURL != nil else { return }
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }

  @ViewBuilder
  private var backdrop: some View {
    if let posterURL {
      CachedAsyncImage(url: posterURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        palette.playerBackdrop
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .blur(radius: compact ? 0 : 36, opaque: true)
      .overlay(Color.black.opacity(compact ? 0.28 : 0.42))
      .clipped()
    } else {
      palette.playerBackdrop
    }
  }

  private var cluster: some View {
    VStack(spacing: compact ? 10 : 18) {
      if !compact, let avatarURL {
        avatar(avatarURL)
      }
      ProgressView()
        .tint(foreground)
        .scaleEffect(compact ? 1.0 : 1.3)
      if let title, !title.isEmpty {
        Text(title)
          .font(compact ? .headline : .title3.weight(.semibold))
          .foregroundStyle(compact ? foreground.opacity(0.85) : foreground)
          .lineLimit(1)
          .shadow(color: hasArt ? .black.opacity(0.5) : .clear, radius: 6, y: 1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(compact ? 12 : 24)
  }

  private func avatar(_ url: URL) -> some View {
    let size: CGFloat = 96
    return CachedAsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(foreground.opacity(0.12))
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(foreground.opacity(0.3), lineWidth: 2))
    .shadow(color: .black.opacity(hasArt ? 0.4 : 0), radius: 12, y: 4)
    .scaleEffect(pulse ? 1.0 : 0.93)
    .opacity(pulse ? 1.0 : 0.85)
  }
}
