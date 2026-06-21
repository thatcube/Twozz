import SwiftUI

/// The Home tab's "Recommended categories" rail. Tapping a category pushes it
/// onto `HomeView`'s navigation path so the category view is genuinely L2 of
/// Home. Hidden when there are no recommended categories.
struct HomeRecommendedCategoriesSection: View {
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  @Binding var homePath: [TwitchCategory]
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var recommendations: RecommendationsService { environment.recommendations }

  var body: some View {
    if !recommendations.categories.isEmpty {
      let categoryWidth = max(180, min(240, rail.mediaWidth * 0.6))

      VStack(alignment: .leading, spacing: 2) {
        Text("Recommended categories")
          .font(.system(size: 32, weight: .bold))
          .accessibilityAddTraits(.isHeader)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(recommendations.categories) { category in
              let itemID = "category-\(category.id)"
              let isFocused = focusedItemID == itemID

              CategoryCardView(
                category: category,
                isFocused: isFocused,
                width: categoryWidth
              )
              .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                homePath.append(category)
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
              .animation(AppLayout.focusScaleAnimation, value: isFocused)
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .padding(.vertical, style.railVerticalPadding)
        }
        .scrollClipDisabled()
      }
      .focusSection()
    }
  }
}
