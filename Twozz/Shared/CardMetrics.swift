import CoreGraphics

/// Centralised card sizing tokens. Every card surface in the app derives its
/// corner radii, internal padding, and spacing from here so changes propagate
/// everywhere at once and the visual system stays coherent.
///
/// Inspired by Plozz's shared-metrics approach: a single source of truth that
/// any card view can reference, with the concentric-radius pattern (outer glass
/// radius = inner media radius + card inset) guaranteeing an even-width border
/// at every size.
enum CardMetrics {

  // MARK: - Card Inset (glass edge → content artwork)

  /// The visual gap between the outer glass surface and the inner content/media.
  /// Corner radii are concentric: outerRadius = innerRadius + cardInset, so the
  /// glass border renders at a constant width around the artwork.
  static let cardInset: CGFloat = 12

  // MARK: - Corner Radii (inner media radii; outer derived concentrically)

  /// Standard media/artwork corner radius used for rail cards, category art,
  /// content cards, and most surfaces.
  static let mediaCornerRadius: CGFloat = 18

  /// Tighter media corner radius for compact grid cards.
  static let gridMediaCornerRadius: CGFloat = 14

  /// Outer card corner radius: concentric with the standard media radius.
  static var cardCornerRadius: CGFloat { mediaCornerRadius + cardInset } // 30

  /// Outer card corner radius for compact grid cards.
  static var gridCardCornerRadius: CGFloat { gridMediaCornerRadius + cardInset } // 26

  /// Outer corner radius for hero/featured surfaces (slightly smaller than a
  /// full card, matching the larger single-item presentation).
  static let heroCornerRadius: CGFloat = 28

  // MARK: - Insets

  /// Internal content padding for compact grid cards. It matches the radius
  /// difference so the frame stays concentric at every size.
  static var gridContentInset: CGFloat { cardInset }

  /// Internal padding for category (box-art) cards. This must equal
  /// ``cardInset`` so the artwork and outer card radii stay concentric.
  static var categoryInset: CGFloat { cardInset }

  /// Width of the focus-only glass halo around a borderless "poster" card.
  static let focusHaloInset: CGFloat = 8

  /// Reserved caption movement below a borderless card's focused artwork.
  static let focusCaptionPush: CGFloat = 16

  // MARK: - Spacing Between Cards

  /// Base horizontal gap between cards in rails and grids. Subtly tightens
  /// at higher card counts via ``spacingScale(forVisibleCardCount:)``.
  static let cardSpacing: CGFloat = 24

  /// Vertical padding above/below a card rail row.
  static let railVerticalPadding: CGFloat = 24

  /// Room reserved inside a clipping horizontal rail for focus scale, halo, and
  /// shadow. The scroll view negates this down to ``railVerticalPadding`` outside
  /// the clip, preserving the row's original footprint.
  static let railShadowClearance: CGFloat = 60

  /// Outer padding that cancels the extra in-clip shadow clearance.
  static var railClearanceOffset: CGFloat {
    railVerticalPadding - railShadowClearance
  }

  /// Gap between the media thumbnail and the text/metadata below it.
  static let captionSpacing: CGFloat = 10

  /// Gap between text lines within a card's caption area (e.g. title → game).
  static let captionLineSpacing: CGFloat = 4

  /// Gap between the avatar and the text block in cards with a profile image.
  static let avatarTextSpacing: CGFloat = 10

  /// Vertical gap between full rail sections on the Home tab.
  static let sectionSpacing: CGFloat = 72

  // MARK: - Screen Layout

  /// Horizontal page gutter (matches ``AppLayout.horizontalPadding``).
  static let screenPadding: CGFloat = 24

  // MARK: - Focus & Animation

  /// Uniform scale applied to a focused card.
  static let focusedScale: CGFloat = 1.07

  /// Focus shadow opacity for dark/OLED themes.
  static let focusShadowOpacity: CGFloat = 0.36

  /// Focus shadow opacity for light theme.
  static let focusShadowOpacityLight: CGFloat = 0.12

  /// Focus shadow blur radius.
  static let focusShadowRadius: CGFloat = 20

  /// Focus shadow vertical offset.
  static let focusShadowY: CGFloat = 10

  /// Subtle resting-card shadow used by framed cards for depth and Light-theme
  /// separation. The theme-aware outer hairline provides Dark/OLED definition.
  static let restingShadowOpacity: CGFloat = 0.15
  static let restingShadowRadius: CGFloat = 8
  static let restingShadowY: CGFloat = 4

  // MARK: - Avatars

  /// Channel avatar diameter in rail cards.
  static let railAvatarSize: CGFloat = 62

  /// Channel avatar diameter in grid cards.
  static let gridAvatarSize: CGFloat = 68

  // MARK: - Adaptive Spacing

  /// Subtly tightens the gap between cards as more fit across the screen.
  /// Full base spacing at 2-across, easing to ~68 % at 6-across.
  static func spacingScale(forVisibleCardCount count: Int) -> CGFloat {
    let clamped = CGFloat(min(max(count, 2), 6))
    return 1.0 - (clamped - 2) * 0.08
  }
}

/// Shared visual presentation for media cards. "Poster" matches Plozz's
/// borderless Posters option: artwork and caption only, with glass appearing as
/// a concentric focus halo rather than an always-on frame.
enum CardPresentation: String, CaseIterable, Identifiable {
  case framed
  case poster

  var id: String { rawValue }

  var title: String {
    switch self {
    case .framed: "Cards"
    case .poster: "Posters"
    }
  }

  var subtitle: String {
    switch self {
    case .framed: "Framed"
    case .poster: "Artwork only"
    }
  }

  static let storageKey = PersistenceKey.cardPresentation
  static let fallback: CardPresentation = .poster

  static func resolve(_ rawValue: String) -> CardPresentation {
    CardPresentation(rawValue: rawValue) ?? .fallback
  }
}
