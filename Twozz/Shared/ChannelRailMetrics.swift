import CoreGraphics

/// Computed sizing for a horizontal stream-card rail. Shared so every surface
/// that lays out stream cards in a rail (Home and the Multiview picker) sizes
/// them identically and, crucially, honours the global ``StreamCardSize``
/// preference instead of each view hardcoding its own width.
struct ChannelRailMetrics: Equatable {
  let spacing: CGFloat
  let mediaWidth: CGFloat
  let mediaHeight: CGFloat
  let focusHorizontalInset: CGFloat

  /// Full card footprint (media plus the focus inset on each side) — the value
  /// to hand a `.frame(width:)` when the card lays its media out to fill.
  var outerCardWidth: CGFloat { mediaWidth + focusHorizontalInset * 2 }
}

/// Tunables and the width solver behind a stream-card rail. Centralised here so
/// Home and Multiview can't drift apart.
enum ChannelRailLayout {
  /// Fraction of the next card left peeking past the trailing edge, hinting the
  /// rail scrolls.
  static let peekCardFraction: CGFloat = 0.08
  static let minMediaWidth: CGFloat = 220
  static let maxMediaWidth: CGFloat = 900

  /// Base gap between cards before the size-aware scale is applied. Shared by
  /// the Browse grid so rails and grids tighten in lockstep.
  static var baseCardSpacing: CGFloat { CardMetrics.cardSpacing }

  /// Subtly tightens the gap between cards as they get smaller (more cards
  /// across). Smaller cards don't need as wide a gutter, and reclaiming that
  /// space lets each card render a touch larger in the same width. Full base
  /// spacing at 2-across, easing down to ~68% at 6-across.
  static func spacingScale(forVisibleCardCount count: Int) -> CGFloat {
    CardMetrics.spacingScale(forVisibleCardCount: count)
  }

  /// Solve the per-card width so `visibleCardCount` full cards (plus a peek of
  /// the next) fit across the available width. Mirrors the original Home math.
  static func metrics(
    availableWidth: CGFloat,
    trailingSafeArea: CGFloat = 0,
    visibleCardCount: Int,
    contentHorizontalInset: CGFloat = CardMetrics.cardInset
  ) -> ChannelRailMetrics {
    // Cards begin at the left page gutter inside a full-width clipping rail.
    // The usable span therefore runs from that gutter to the trailing edge.
    let visibleWidth = max(availableWidth - AppLayout.horizontalPadding + trailingSafeArea, 1)
    let n = CGFloat(max(visibleCardCount, 1))
    let peek = peekCardFraction
    let baseSpacing = max(18, min(32, visibleWidth * 0.012))
    let spacing = min(baseSpacing, 32) * spacingScale(forVisibleCardCount: visibleCardCount)
    // visibleWidth = (n + peek) * outer + n * spacing  ->  solve for outer.
    let rawOuterCardWidth = (visibleWidth - (n * spacing)) / (n + peek)
    let minOuterCardWidth = minMediaWidth + (contentHorizontalInset * 2)
    let maxOuterCardWidth = maxMediaWidth + (contentHorizontalInset * 2)
    let outerCardWidth = min(max(rawOuterCardWidth, minOuterCardWidth), maxOuterCardWidth)
    let mediaWidth = outerCardWidth - (contentHorizontalInset * 2)
    let mediaHeight = mediaWidth * 9 / 16

    return ChannelRailMetrics(
      spacing: spacing,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      focusHorizontalInset: contentHorizontalInset
    )
  }
}
