import SwiftUI

/// Shared layout constants for the Home tab's horizontal rails. Each extracted
/// section builds the same `StreamChannelCard.Layout` from the per-width
/// `ChannelRailMetrics` without re-declaring the inset/corner constants, so the
/// rails stay byte-for-byte identical to the original single-file `HomeView`.
struct HomeRailStyle {
  var focusHorizontalInset: CGFloat
  var focusVerticalInset: CGFloat
  var cardCornerRadius: CGFloat
  var mediaCornerRadius: CGFloat
  var railVerticalPadding: CGFloat

  /// Builds the `.rail` card layout for a given width's metrics, matching the
  /// inline `.rail(...)` HomeView used at every card-render site.
  func cardLayout(for rail: ChannelRailMetrics) -> StreamChannelCard.Layout {
    .rail(
      mediaWidth: rail.mediaWidth,
      mediaHeight: rail.mediaHeight,
      focusHorizontalInset: focusHorizontalInset,
      focusVerticalInset: focusVerticalInset,
      cardCornerRadius: cardCornerRadius,
      mediaCornerRadius: mediaCornerRadius
    )
  }
}
