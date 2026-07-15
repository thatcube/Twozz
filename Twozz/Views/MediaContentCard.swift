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
  var focusHorizontalInset: CGFloat = CardMetrics.cardInset
  var focusVerticalInset: CGFloat = CardMetrics.cardInset
  var cardCornerRadius: CGFloat = CardMetrics.cardCornerRadius
  var mediaCornerRadius: CGFloat = CardMetrics.mediaCornerRadius

  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @AppStorage(CardPresentation.storageKey) private var presentationRaw = CardPresentation.fallback.rawValue
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
      media
      caption
    }
    .padding(.horizontal, focusHorizontalInset)
    .padding(.vertical, focusVerticalInset)
    .frame(width: mediaWidth + focusHorizontalInset * 2, alignment: .leading)
    .twozzLiquidGlassCard(
      cornerRadius: cardCornerRadius,
      isFocused: isFocused,
      palette: palette
    )
    .shadow(
      color: Color.black.opacity(isFocused ? CardMetrics.focusShadowOpacity : 0),
      radius: CardMetrics.focusShadowRadius,
      y: CardMetrics.focusShadowY
    )
    .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var posterCard: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionSpacing + CardMetrics.focusCaptionPush) {
      media
      caption
        .offset(y: isFocused ? 0 : -CardMetrics.focusCaptionPush)
    }
    .padding(.horizontal, focusHorizontalInset)
    .frame(width: mediaWidth + focusHorizontalInset * 2, alignment: .leading)
    .compositingGroup()
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var caption: some View {
    VStack(alignment: .leading, spacing: CardMetrics.captionLineSpacing) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)

      Text(subtitle.isEmpty ? " " : subtitle)
        .font(.footnote)
        .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
        .lineLimit(
          presentation == .poster ? 1 : 2,
          reservesSpace: presentation == .framed
        )
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(subtitle.isEmpty ? 0 : 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One spoken description per tile: title, subtitle, and duration — so
  /// VoiceOver reads a clip/VOD as a single coherent element.
  private var accessibilityLabel: Text {
    var parts: [String] = [title]
    if !subtitle.isEmpty {
      parts.append(subtitle)
    }
    if let durationText {
      parts.append(durationText)
    }
    return Text(parts.joined(separator: ", "))
  }

  private var media: some View {
    ZStack(alignment: .bottomTrailing) {
      Color.primary.opacity(0.08)

      CachedAsyncImage(url: thumbnailURL) { image in
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
    .clipShape(RoundedRectangle(cornerRadius: activeMediaCornerRadius, style: .continuous))
    .twozzMediaEdge(cornerRadius: activeMediaCornerRadius)
    .twozzFocusHalo(
      cornerRadius: activeMediaCornerRadius,
      focusScale: AppLayout.focusedCardScale,
      isFocused: presentation == .poster && isFocused
    )
  }

  private var activeMediaCornerRadius: CGFloat {
    presentation == .poster ? cardCornerRadius : mediaCornerRadius
  }

  private var usesLiftFocusedText: Bool {
    presentation == .framed
      && twozzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
  }
}
