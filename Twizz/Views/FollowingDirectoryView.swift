import SwiftUI

/// Full "Following" directory: every channel the viewer follows — live **and**
/// offline — in a native focus-friendly grid, sorted live-first. Reached from the
/// "See All" affordance on the Home "Following" rail. Tapping a card watches the
/// channel; press-and-hold "Go to Channel" opens `ChannelPageView` (VODs / clips /
/// similar), which is the whole point for offline follows.
struct FollowingDirectoryView: View {
  let follows: FollowedChannelsService
  let auth: TwitchAuthSession
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @FocusState private var focusedID: String?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 24),
      count: StreamCardSize.resolve(streamCardSizeRaw).visibleCardCount
    )
  }
  private let gridSpacing: CGFloat = 24
  private let gridBottomInset: CGFloat = 12

  private var liveCount: Int {
    follows.directory.reduce(into: 0) { $0 += $1.isLive ? 1 : 0 }
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
        } else {
          LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(follows.directory) { channel in
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
                selectedChannel = channel
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
