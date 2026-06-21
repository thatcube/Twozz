import SwiftUI

/// Full "Following" directory: every channel the viewer follows — live **and**
/// offline — in a native focus-friendly grid, sorted live-first. Reached from the
/// "See All" affordance on the Home "Following" rail.
///
/// - Selecting a **live** channel watches it (opens the player).
/// - Selecting an **offline** channel opens its `ChannelPageView` (VODs / clips /
///   similar) instead of attempting playback — there is nothing live to play.
/// - The grid is pinned to the densest 5-across layout regardless of the global
///   `StreamCardSize` preference, since a large follow list is unwieldy at the
///   bigger card sizes.
/// - A native search field filters the whole list (online + offline) by display
///   name and login.
struct FollowingDirectoryView: View {
  @Environment(AppEnvironment.self) private var environment
  private var follows: FollowedChannelsService { environment.follows }
  private var auth: TwitchAuthSession { environment.auth }
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @FocusState private var focusedID: String?
  @State private var searchText = ""

  /// Pinned dense layout: always 5 columns, independent of the user's global
  /// stream-card-size preference, so a ~100-channel directory stays navigable.
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 5)
  private let gridSpacing: CGFloat = 24
  private let gridBottomInset: CGFloat = 12

  private var liveCount: Int {
    follows.directory.reduce(into: 0) { $0 += $1.isLive ? 1 : 0 }
  }

  /// The directory filtered by the search query (display name or login,
  /// case-insensitive). The source list is already sorted live-first, and
  /// filtering preserves that order.
  private var filteredChannels: [FollowedChannel] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return follows.directory }
    return follows.directory.filter { channel in
      channel.displayName.localizedCaseInsensitiveContains(query)
        || channel.login.localizedCaseInsensitiveContains(query)
    }
  }

  /// Routes a selected channel: offline channels go to their channel page (no
  /// playback to attempt); live channels open the player.
  private func select(_ channel: FollowedChannel) {
    if channel.isLive {
      selectedChannel = channel
    } else {
      channelPageTarget = ChannelPageTarget(channel: channel)
    }
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Following")
              .font(.title.weight(.bold))
            if !follows.directory.isEmpty {
              Text("\(liveCount) live • \(follows.directory.count) total")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }

          if follows.isLoadingDirectory && follows.directory.isEmpty {
            ProgressView().scaleEffect(0.85)
          }

          Spacer()
        }
        .focusSection()

        if let err = follows.directoryErrorMessage {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        if !follows.isLoadingDirectory && follows.directory.isEmpty
          && follows.directoryErrorMessage == nil
        {
          Text("You don't follow any channels yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } else if filteredChannels.isEmpty {
          Text("No channels match \"\(searchText)\".")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } else {
          LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(filteredChannels) { channel in
              let isFocused = focusedID == channel.id
              StreamChannelCard(
                channel: channel,
                isFocused: isFocused,
                showsGameName: true,
                onWatch: { selectedChannel = $0 },
                onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) }
              )
              .contentShape(RoundedRectangle(cornerRadius: 16))
              .focusable(true)
              .focused($focusedID, equals: channel.id)
              .focusEffectDisabled()
              .onTapGesture {
                select(channel)
              }
              .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
              .animation(AppLayout.focusScaleAnimation, value: isFocused)
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .focusSection()
        }
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.top, 8)
      .padding(.bottom, gridBottomInset)
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .searchable(text: $searchText, prompt: "Search your follows")
    .navigationBarHidden(true)
    .toolbar(.hidden, for: .tabBar)
    .task {
      await follows.loadDirectory(using: auth)
    }
    .onChange(of: follows.directory) { _, channels in
      if focusedID == nil, let first = channels.first {
        Task {
          try? await Task.sleep(for: .milliseconds(150))
          await MainActor.run { focusedID = first.id }
        }
      }
    }
  }
}
