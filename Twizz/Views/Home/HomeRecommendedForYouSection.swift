import SwiftUI

/// The Home tab's "Recommended for you" rail — the on-device personalized
/// recommendations. Hidden entirely when personalization is disabled or there's
/// nothing to show, matching the original gate.
struct HomeRecommendedForYouSection: View {
  let personalizedEnabled: Bool
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let onWatch: (FollowedChannel) -> Void
  let onGoToChannel: (FollowedChannel) -> Void
  let onNotInterested: (FollowedChannel) -> Void
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var personalized: PersonalizedRecommendationsService { environment.personalized }

  var body: some View {
    let channels = personalized.channels

    if personalizedEnabled, !channels.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Recommended for you")
            .font(.system(size: 32, weight: .bold))
            .accessibilityAddTraits(.isHeader)

          if personalized.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(channels) { channel in
              HomeRailStreamCard(
                channel: channel,
                itemID: "foryou-\(channel.id)",
                layout: style.cardLayout(for: rail),
                onWatch: onWatch,
                onGoToChannel: onGoToChannel,
                onNotInterested: onNotInterested,
                onTap: { onWatch(channel) },
                focusedItemID: $focusedItemID
              )
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
