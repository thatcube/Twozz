import SwiftUI

/// The Home tab's "Following" (or "Trending" in demo mode) rail: the header with
/// its loading spinner, "See All" and refresh buttons, an optional error line,
/// and the horizontal rail of merged Twitch + live-YouTube cards. Card content
/// (the merged `channels` list) and the watch / go-to actions are supplied by
/// `HomeView`, which still owns the cross-service merge and routing logic.
struct HomeFollowingSection: View {
  let channels: [FollowedChannel]
  let rail: ChannelRailMetrics
  let style: HomeRailStyle
  @Binding var showingFollowingDirectory: Bool
  let onRefresh: () -> Void
  let onWatch: (FollowedChannel) -> Void
  let onGoToChannel: (FollowedChannel) -> Void
  @FocusState.Binding var focusedItemID: String?

  @Environment(AppEnvironment.self) private var environment
  private var follows: FollowedChannelsService { environment.follows }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(follows.isUsingDemoData ? "Trending" : "Following")
          .font(.system(size: 32, weight: .bold))
          .accessibilityAddTraits(.isHeader)

        if follows.isLoading {
          ProgressView()
            .scaleEffect(0.85)
        }

        Spacer()

        HStack(spacing: 8) {
          if !follows.isUsingDemoData {
            Button {
              showingFollowingDirectory = true
            } label: {
              Text("See All")
                .font(.system(size: 24, weight: .semibold))
            }
            .accessibilityLabel("See all followed channels")
          }

          Button {
            onRefresh()
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 28, weight: .semibold))
          }
          .accessibilityLabel("Refresh")
        }
      }

      if let errorMessage = follows.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.orange)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: rail.spacing) {
          ForEach(channels) { channel in
            HomeRailStreamCard(
              channel: channel,
              itemID: "following-\(channel.id)",
              layout: style.cardLayout(for: rail),
              onWatch: onWatch,
              onGoToChannel: onGoToChannel,
              onTap: { onWatch(channel) },
              focusedItemID: $focusedItemID
            )
          }
        }
        .padding(.vertical, style.railVerticalPadding)
      }
      .scrollClipDisabled()

      if channels.isEmpty {
        Text(follows.isUsingDemoData ? "No trending channels are available right now." : "No followed channels are available yet.")
          .foregroundStyle(.secondary)
      }
    }
    .focusSection()
  }
}
