import SwiftUI

/// The Home tab's "Top streams" rail — the most-viewed live channels after the
/// language filter and "Not interested" removals. `channels` is the memoized
/// `topStreams` list owned by `HomeView`; the rail hides when it's empty.
struct HomeTopStreamsSection: View {
  let channels: [FollowedChannel]
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  let onWatch: (FollowedChannel) -> Void
  let onGoToChannel: (FollowedChannel) -> Void
  let onNotInterested: (FollowedChannel) -> Void
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var recommendations: RecommendationsService { environment.recommendations }

  var body: some View {
    if !channels.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Top streams")
            .font(.system(size: 32, weight: .bold))
            .accessibilityAddTraits(.isHeader)

          if recommendations.isLoading {
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
                itemID: "topstreams-\(channel.id)",
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
