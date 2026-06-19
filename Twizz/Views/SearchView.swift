import SwiftUI

// MARK: - SearchView

struct SearchView: View {
  let auth: TwitchAuthSession
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @State private var service = SearchService()
  @State private var query = ""
  @State private var path: [TwitchCategory] = []

  var body: some View {
    NavigationStack(path: $path) {
      SearchResultsView(
        query: $query,
        service: service,
        onSelectChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
        onWatchChannel: { selectedChannel = $0 },
        onSelectCategory: { path.append($0) }
      )
      .navigationDestination(for: TwitchCategory.self) { category in
        CategoryStreamsView(
          category: category,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget
        )
      }
    }
    .task(id: query) {
      // Debounce keystrokes from the on-screen keyboard before hitting the API.
      let pending = query
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, pending == query else { return }
      await service.search(pending)
    }
  }
}

// MARK: - Results

private struct SearchResultsView: View {
  @Binding var query: String
  let service: SearchService
  let onSelectChannel: (FollowedChannel) -> Void
  let onWatchChannel: (FollowedChannel) -> Void
  let onSelectCategory: (TwitchCategory) -> Void

  @FocusState private var focusedID: String?

  private let channelColumns = [
    GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 24)
  ]
  private let categoryColumns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 28)
  ]

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 32) {
        if service.isSearching && !service.hasResults {
          HStack(spacing: 12) {
            ProgressView()
            Text("Searching…")
              .foregroundStyle(.secondary)
          }
          .padding(.top, 12)
        }

        if let err = service.errorMessage, !service.hasResults {
          Text(err)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        }

        if !service.categoryResults.isEmpty {
          categoriesSection
        }

        if !service.channelResults.isEmpty {
          channelsSection
        }
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.top, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .searchable(
      text: $query,
      placement: .automatic,
      prompt: "Search channels and categories"
    )
  }

  private var categoriesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Categories")
        .font(.title3.weight(.bold))

      LazyVGrid(columns: categoryColumns, spacing: 28) {
        ForEach(service.categoryResults) { category in
          let id = "category-\(category.id)"
          let isFocused = focusedID == id
          CategoryCardView(category: category, isFocused: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
            .focusable(true)
            .focused($focusedID, equals: id)
            .focusEffectDisabled()
            .onTapGesture { onSelectCategory(category) }
            .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
            .animation(AppLayout.focusScaleAnimation, value: isFocused)
            .zIndex(isFocused ? 2 : 0)
        }
      }
      .focusSection()
    }
  }

  private var channelsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Channels")
        .font(.title3.weight(.bold))

      LazyVGrid(columns: channelColumns, spacing: 24) {
        ForEach(service.channelResults) { channel in
          let id = "channel-\(channel.id)"
          let isFocused = focusedID == id
          StreamChannelCard(
            channel: channel,
            isFocused: isFocused,
            showsGameName: true,
            onWatch: channel.isLive ? { onWatchChannel($0) } : nil,
            onGoToChannel: { onSelectChannel($0) }
          )
          .contentShape(RoundedRectangle(cornerRadius: 16))
          .focusable(true)
          .focused($focusedID, equals: id)
          .focusEffectDisabled()
          .onTapGesture { onSelectChannel(channel) }
          .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
          .animation(AppLayout.focusScaleAnimation, value: isFocused)
          .zIndex(isFocused ? 2 : 0)
        }
      }
      .focusSection()
    }
  }
}
