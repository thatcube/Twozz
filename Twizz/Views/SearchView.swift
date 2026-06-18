import SwiftUI

// MARK: - SearchView

struct SearchView: View {
  let auth: TwitchAuthSession
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?
  /// Invoked when a category result is chosen; the host switches to Browse.
  let onSelectCategory: (TwitchCategory) -> Void

  @State private var service = SearchService()
  @State private var query = ""

  var body: some View {
    NavigationStack {
      SearchResultsView(
        service: service,
        onSelectChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
        onWatchChannel: { selectedChannel = $0 },
        onSelectCategory: onSelectCategory
      )
      .navigationTitle("Search")
    }
    .searchable(
      text: $query,
      placement: .automatic,
      prompt: "Search channels and categories"
    )
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

        if service.query.isEmpty && !service.hasResults && service.errorMessage == nil
          && !service.isSearching
        {
          emptyPrompt
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var emptyPrompt: some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 48, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Search Twitch")
        .font(.title2.weight(.semibold))
      Text("Find live channels and categories by name.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 24)
  }

  private var categoriesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Categories")
        .font(.title3.weight(.bold))

      LazyVGrid(columns: categoryColumns, spacing: 28) {
        ForEach(service.categoryResults) { category in
          let id = "category-\(category.id)"
          let isFocused = focusedID == id
          SearchCategoryCard(category: category, isFocused: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .focusable(true)
            .focused($focusedID, equals: id)
            .focusEffectDisabled()
            .onTapGesture { onSelectCategory(category) }
            .scaleEffect(isFocused ? 1.07 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
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
          .scaleEffect(isFocused ? 1.06 : 1)
          .animation(.easeOut(duration: 0.14), value: isFocused)
          .zIndex(isFocused ? 2 : 0)
        }
      }
      .focusSection()
    }
  }
}

// MARK: - Category Card

private struct SearchCategoryCard: View {
  let category: TwitchCategory
  let isFocused: Bool

  @Environment(\.themePalette) private var palette

  private let cornerRadius: CGFloat = 14
  private let artRatio: CGFloat = 285.0 / 380.0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      AsyncImage(url: category.boxArtURL) { img in
        img.resizable().scaledToFill()
      } placeholder: {
        Color.primary.opacity(0.08)
      }
      .aspectRatio(artRatio, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 2))

      VStack(alignment: .leading, spacing: 4) {
        Text(category.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(usesLiftFocusedText ? palette.liftPrimaryText : Color.primary)
          .lineLimit(2, reservesSpace: true)

        if let viewers = category.viewerCount {
          Text("\(viewers) watching")
            .font(.caption2)
            .foregroundStyle(usesLiftFocusedText ? palette.liftSecondaryText : Color.secondary)
        } else {
          Text(" ")
            .font(.caption2)
            .hidden()
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .padding(10)
    .twizzLiquidGlassCard(
      cornerRadius: cornerRadius,
      isFocused: isFocused,
      palette: palette
    )
  }

  private var usesLiftFocusedText: Bool {
    guard isFocused else { return false }
    if #available(tvOS 26.0, *) {
      return false
    }
    return true
  }
}
