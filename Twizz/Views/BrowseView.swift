import SwiftUI

// MARK: - BrowseView

struct BrowseView: View {
  let auth: TwitchAuthSession
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?
  @Binding var pendingCategory: TwitchCategory?
  @Binding var path: [TwitchCategory]

  @State private var service = BrowseService()

  private func open(_ category: TwitchCategory) {
    if path.last != category {
      withAnimation(.easeInOut(duration: 0.35)) {
        path.append(category)
      }
    }
  }

  var body: some View {
    NavigationStack(path: $path) {
      BrowseCategoriesView(
        service: service,
        onSelectCategory: { category in
          open(category)
        }
      )
      .task {
        if service.categories.isEmpty {
          await service.loadCategories()
        }
      }
      .navigationDestination(for: TwitchCategory.self) { category in
        BrowseStreamsView(
          category: category,
          service: service,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget
        )
        .task(id: category.id) {
          await service.loadStreams(for: category)
        }
      }
    }
    .onAppear { consumePendingCategoryIfNeeded() }
    .onChange(of: pendingCategory) { _, _ in consumePendingCategoryIfNeeded() }
  }

  private func consumePendingCategoryIfNeeded() {
    guard let category = pendingCategory else { return }
    pendingCategory = nil
    open(category)
  }
}

// MARK: - Categories Grid

private struct BrowseCategoriesView: View {
  let service: BrowseService
  let onSelectCategory: (TwitchCategory) -> Void

  @FocusState private var focusedID: String?
  @Namespace private var browseFocusNamespace

  private let columns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 28)
  ]

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("Browse")
            .font(.title.weight(.bold))

          if service.isLoadingCategories {
            ProgressView().scaleEffect(0.85)
          }

          Spacer()

          Button("Refresh") {
            Task { await service.loadCategories() }
          }
        }

        if let err = service.categoryErrorMessage {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        LazyVGrid(columns: columns, spacing: 28) {
          ForEach(service.categories) { category in
            let isFocused = focusedID == category.id
            CategoryCardView(
              category: category,
              isFocused: isFocused
            )
            .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
            .focusable(true)
            .focused($focusedID, equals: category.id)
            .prefersDefaultFocus(
              category.id == service.categories.first?.id,
              in: browseFocusNamespace
            )
            .focusEffectDisabled()
            .onTapGesture {
              onSelectCategory(category)
            }
            .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
            .animation(AppLayout.focusScaleAnimation, value: isFocused)
            .zIndex(isFocused ? 2 : 0)
          }
        }
        .padding(.vertical, 8)
        .focusSection()
        .focusScope(browseFocusNamespace)
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.bottom, 12)
    }
  }
}

// MARK: - Streams for a Category

private struct BrowseStreamsView: View {
  let category: TwitchCategory
  let service: BrowseService
  @Binding var selectedChannel: FollowedChannel?
  @Binding var channelPageTarget: ChannelPageTarget?

  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedStreamID: String?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 24),
      count: StreamCardSize.resolve(streamCardSizeRaw).visibleCardCount
    )
  }
  private let gridSpacing: CGFloat = 24
  private let gridBottomInset: CGFloat = 12

  var body: some View {
    ZStack(alignment: .top) {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 20) {
          // Header (scrolls with content)
          HStack(spacing: 20) {
            Button(action: { dismiss() }) {
              HStack(spacing: 8) {
                Icon(glyph: .chevronLeft, size: 26)
                Text("Categories")
              }
              .font(.callout.weight(.medium))
              .padding(.horizontal, 18)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: 10)
                  .fill(Color.primary.opacity(0.1))
              )
            }
            .buttonStyle(.plain)

            if let url = category.boxArtURL {
              AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
              } placeholder: {
                Color.primary.opacity(0.08)
              }
              .frame(width: 40, height: 53)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 2) {
              Text(category.name)
                .font(.title.weight(.bold))
              if let viewers = category.viewerCount {
                Text("\(viewers) watching")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }

            if service.isLoadingStreams && service.categoryStreams.isEmpty {
              ProgressView().scaleEffect(0.85)
            }

            Spacer()
          }
          .focusSection()

          if let err = service.streamsErrorMessage {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.orange)
          }

          if !service.isLoadingStreams && service.categoryStreams.isEmpty
            && service.streamsErrorMessage == nil
          {
            Text("No live streams found for \(category.name) right now.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 8)
          } else {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
              ForEach(service.categoryStreams) { channel in
                let isFocused = focusedStreamID == channel.id
                StreamChannelCard(
                  channel: channel,
                  isFocused: isFocused,
                  onWatch: { selectedChannel = $0 },
                  onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) }
                )
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .focusable(true)
                .focused($focusedStreamID, equals: channel.id)
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
    }
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationBarHidden(true)
    .toolbar(.hidden, for: .tabBar)
    .onChange(of: service.categoryStreams) { _, streams in
      if focusedStreamID == nil, let first = streams.first {
        Task {
          try? await Task.sleep(for: .milliseconds(150))
          await MainActor.run { focusedStreamID = first.id }
        }
      }
    }
  }
}
