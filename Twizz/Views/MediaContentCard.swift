import SwiftUI

/// A card for on-demand content (clips & VODs) on the channel page. It mirrors
/// `StreamChannelCard`'s visual language — the same liquid-glass surface, media
/// framing, focus shadow, corner radii and metadata layout — so the channel page
/// feels like the rest of the app. It intentionally drops the channel avatar
/// (a clip/VOD tile doesn't need it) and swaps the live "watching" badge for a
/// duration chip.
struct MediaContentCard: View {
  let title: String
  let subtitle: String
  let thumbnailURL: URL?
  let durationText: String?
  let isFocused: Bool

  var mediaWidth: CGFloat
  var mediaHeight: CGFloat
  var focusHorizontalInset: CGFloat = 18
  var focusVerticalInset: CGFloat = 18
  var cardCornerRadius: CGFloat = 22
  var mediaCornerRadius: CGFloat = 18

  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      media

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
          .lineLimit(1)

        Text(subtitle.isEmpty ? " " : subtitle)
          .font(.footnote)
          .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
          .lineLimit(2, reservesSpace: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, focusHorizontalInset)
    .padding(.vertical, focusVerticalInset)
    .frame(width: mediaWidth + focusHorizontalInset * 2, alignment: .leading)
    .twizzLiquidGlassCard(
      cornerRadius: cardCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .shadow(color: Color.black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
  }

  private var media: some View {
    ZStack(alignment: .bottomTrailing) {
      Color.primary.opacity(0.08)

      AsyncImage(url: thumbnailURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.clear
      }

      LinearGradient(
        colors: [Color.clear, Color.black.opacity(0.55)],
        startPoint: .center,
        endPoint: .bottom
      )

      if let durationText {
        Text(durationText)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.black.opacity(0.75)))
          .padding(10)
      }
    }
    .frame(width: mediaWidth, height: mediaHeight)
    .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))
  }

  private var usesLiftFocusedText: Bool {
    guard isFocused else { return false }
    if #available(tvOS 26.0, *) {
      return false
    }
    return true
  }
}
