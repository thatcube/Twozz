import SwiftUI

/// Shared category (box art) card used by Home, Browse, and Search so the three
/// surfaces stay visually identical. Pass `width` for the fixed-size Home rails;
/// leave it nil to fill the available grid cell via aspect ratio.
struct CategoryCardView: View {
  let category: TwitchCategory
  let isFocused: Bool
  var width: CGFloat? = nil

  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled

  /// Match the stream cards: aggressive outer glass rounding with the inner box
  /// art rounded to the same radius the stream card media uses.
  private let outerCornerRadius: CGFloat = 30
  private let artCornerRadius: CGFloat = 18
  private let artRatio: CGFloat = 285.0 / 380.0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      CachedAsyncImage(url: category.boxArtURL) { img in
        img.resizable().scaledToFill()
      } placeholder: {
        Color.primary.opacity(0.08)
      }
      .modifier(ArtSizing(width: width, artRatio: artRatio))
      .clipShape(RoundedRectangle(cornerRadius: artCornerRadius, style: .continuous))

      VStack(alignment: .leading, spacing: 4) {
        Text(category.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
          .lineLimit(2, reservesSpace: true)
          .minimumScaleFactor(0.8)

        if let viewers = category.viewerCount {
          Text("\(viewers) watching")
            .font(.caption2)
            .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
          Text(" ")
            .font(.caption2)
            .hidden()
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .padding(10)
    .modifier(CardSizing(width: width))
    .twizzLiquidGlassCard(
      cornerRadius: outerCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// One spoken description per category tile: name plus the viewer count when
  /// present, so VoiceOver reads it as a single element.
  private var accessibilityLabel: Text {
    if let viewers = category.viewerCount {
      return Text("\(category.name), \(viewers) watching")
    }
    return Text(category.name)
  }

  /// The corner radius callers should use for the focus/hit-test content shape so
  /// it matches the card's outer rounding.
  static let contentShapeCornerRadius: CGFloat = 30

  private var usesLiftFocusedText: Bool {
    twizzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
  }
}

private struct ArtSizing: ViewModifier {
  let width: CGFloat?
  let artRatio: CGFloat

  func body(content: Content) -> some View {
    if let width {
      content.frame(width: width, height: width / artRatio)
    } else {
      content.aspectRatio(artRatio, contentMode: .fit)
    }
  }
}

private struct CardSizing: ViewModifier {
  let width: CGFloat?

  func body(content: Content) -> some View {
    if let width {
      content.frame(width: width + 20)
    } else {
      content
    }
  }
}
