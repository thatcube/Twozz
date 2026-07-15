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
  @AppStorage(CardPresentation.storageKey) private var presentationRaw = CardPresentation.fallback.rawValue

  /// Match the stream cards: aggressive outer glass rounding with the inner box
  /// art rounded to the same radius the stream card media uses.
  private var outerCornerRadius: CGFloat { CardMetrics.cardCornerRadius }
  private var artCornerRadius: CGFloat { CardMetrics.mediaCornerRadius }
  private let artRatio: CGFloat = 285.0 / 380.0
  private var presentation: CardPresentation { CardPresentation.resolve(presentationRaw) }

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .framed:
      framedCard
    case .poster:
      posterCard
    }
  }

  private var framedCard: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionSpacing) {
      artwork(cornerRadius: artCornerRadius, showsFocusHalo: false)
      caption
        .padding(.horizontal, CardMetrics.categoryInset)
        .padding(.bottom, CardMetrics.cardInset)
    }
    .padding(CardMetrics.categoryInset)
    .modifier(CardSizing(width: width))
    .twozzLiquidGlassCard(
      cornerRadius: outerCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .shadow(
      color: .black.opacity(
        isFocused ? focusedShadowOpacity : CardMetrics.restingShadowOpacity
      ),
      radius: isFocused ? CardMetrics.focusShadowRadius : CardMetrics.restingShadowRadius,
      y: isFocused ? CardMetrics.focusShadowY : CardMetrics.restingShadowY
    )
    .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var posterCard: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionSpacing + CardMetrics.focusCaptionPush) {
      artwork(cornerRadius: outerCornerRadius, showsFocusHalo: true)
      caption
        .padding(.horizontal, CardMetrics.categoryInset)
        .offset(y: isFocused ? 0 : -CardMetrics.focusCaptionPush)
    }
    .padding(.horizontal, CardMetrics.categoryInset)
    .modifier(CardSizing(width: width))
    .compositingGroup()
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var caption: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionLineSpacing) {
      Text(category.name)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
        .lineLimit(
          presentation == .poster ? 1 : 2,
          reservesSpace: presentation == .framed
        )
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
  }

  private func artwork(cornerRadius: CGFloat, showsFocusHalo: Bool) -> some View {
    CachedAsyncImage(url: category.boxArtURL) { img in
      img.resizable().scaledToFill()
    } placeholder: {
      Color.primary.opacity(0.08)
    }
    .modifier(ArtSizing(width: width, artRatio: artRatio))
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .twozzMediaEdge(cornerRadius: cornerRadius)
    .twozzFocusHalo(
      cornerRadius: cornerRadius,
      focusScale: AppLayout.focusedCardScale,
      isFocused: showsFocusHalo && isFocused
    )
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
  static var contentShapeCornerRadius: CGFloat { CardMetrics.cardCornerRadius }

  private var usesLiftFocusedText: Bool {
    presentation == .framed
      && twozzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
  }

  private var focusedShadowOpacity: Double {
    palette.isLight ? CardMetrics.focusShadowOpacityLight : CardMetrics.focusShadowOpacity
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
      content.frame(width: width + CardMetrics.categoryInset * 2)
    } else {
      content
    }
  }
}
