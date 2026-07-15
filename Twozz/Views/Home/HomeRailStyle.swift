import SwiftUI

/// Shared layout constants for the Home tab's horizontal rails.
struct HomeRailStyle {
  var focusHorizontalInset: CGFloat
  var focusVerticalInset: CGFloat
  var cardCornerRadius: CGFloat
  var mediaCornerRadius: CGFloat

  var railShadowClearance: CGFloat { CardMetrics.railShadowClearance }
  var railClearanceOffset: CGFloat { CardMetrics.railClearanceOffset }

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

/// Plozz-style horizontal rail: the rail itself remains clipped so tvOS keeps
/// correct first/last-card scroll positions, while in-clip padding preserves the
/// focused card's halo and shadow.
struct HomeRailScrollView<Content: View>: View {
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let content: Content

  init(
    rail: ChannelRailMetrics,
    style: HomeRailStyle,
    @ViewBuilder content: () -> Content
  ) {
    self.rail = rail
    self.style = style
    self.content = content()
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: rail.spacing) {
        content
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.vertical, style.railShadowClearance)
    }
    .padding(.horizontal, -AppLayout.horizontalPadding)
    .padding(.vertical, style.railClearanceOffset)
  }
}
