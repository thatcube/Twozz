import SwiftUI

struct HomeView: View {
  let deepLinkRouter: DeepLinkRouter

  private let channelRailVerticalPadding: CGFloat = 20
  private let peekCardFraction: CGFloat = 0.15
  private let focusHorizontalInset: CGFloat = 18
  private let focusVerticalInset: CGFloat = 18
  private let cardCornerRadius: CGFloat = 22
  private let mediaCornerRadius: CGFloat = 18
  private let minMediaWidth: CGFloat = 220
  private let maxMediaWidth: CGFloat = 560
  private let focusedCardScale: CGFloat = 1.07
  private let autoRefreshStaleInterval: TimeInterval = 5 * 60

  @State private var selectedTopTab: TopTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var recommendations = RecommendationsService()
  @State private var themeManager = ThemeManager()
  @State private var selectedChannel: FollowedChannel?
  @State private var pendingBrowseCategory: TwitchCategory?
  @State private var firstFocusRequested = false
  @State private var showSignIn = false

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue

  @Environment(\.colorScheme) private var systemColorScheme
  @FocusState private var focusedItemID: String?

  private let firstLaunchSignInPromptKey = "hasPromptedFirstLaunchSignIn"

  private var resolvedPalette: ThemePalette {
    themeManager.theme.palette(systemColorScheme: systemColorScheme)
  }

  private var streamCardSize: StreamCardSize {
    StreamCardSize.resolve(streamCardSizeRaw)
  }

  private var targetVisibleCards: CGFloat {
    CGFloat(streamCardSize.visibleCardCount)
  }

  // Removed private so it can be accessed by the custom components below
  enum TopTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case browse = "Browse"
    case settings = "Settings"

    var id: String { rawValue }
  }

  private struct ChannelRailMetrics {
    let spacing: CGFloat
    let mediaWidth: CGFloat
    let mediaHeight: CGFloat
  }

  var body: some View {
    ZStack(alignment: .top) {
      // 1) The active tab content (scrolls underneath the header)
      Group {
        switch selectedTopTab {
        case .home:
          tabContainer { homeTab }
        case .browse:
          tabContainer {
            BrowseView(
              auth: auth,
              selectedChannel: $selectedChannel,
              pendingCategory: $pendingBrowseCategory
            )
          }
        case .settings:
          tabContainer {
            SettingsView(
              themeManager: themeManager,
              auth: auth,
              onRequestSignIn: { showSignIn = true },
              onAccountChanged: {
                Task {
                  await refreshFollowedChannelsIfNeeded(force: true)
                  requestFocusIfPossible(force: true)
                }
              }
            )
          }
        }
      }

      // 2) A completely detached, fixed custom tab bar matched perfectly to tvOS 18 native style
      CustomTopTabBar(selection: $selectedTopTab)
        .zIndex(100)
    }
    .background(
      LinearGradient(
        colors: resolvedPalette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
    .environment(\.themePalette, resolvedPalette)
    .preferredColorScheme(themeManager.theme.preferredColorScheme)
    .task {
      auth.restore()
      promptFirstLaunchSignInIfNeeded()
      await refreshFollowedChannelsIfNeeded(force: true)
      await refreshRecommendationsIfNeeded(force: true)
      requestFocusIfPossible(force: true)
      openDeepLinkedChannelIfNeeded(deepLinkRouter.pendingChannelLogin)
    }
    .onChange(of: follows.channels) { _, _ in
      requestFocusIfPossible(force: false)
    }
    .onChange(of: auth.isAuthenticated) { _, _ in
      Task {
        await refreshFollowedChannelsIfNeeded(force: true)
        requestFocusIfPossible(force: true)
      }
    }
    .onChange(of: selectedTopTab) { _, tab in
      guard tab == .home else { return }
      Task {
        await refreshFollowedChannelsIfNeeded(force: false)
        await refreshRecommendationsIfNeeded(force: false)
      }
    }
    .onChange(of: deepLinkRouter.pendingChannelLogin) { _, login in
      openDeepLinkedChannelIfNeeded(login)
    }
    .fullScreenCover(item: $selectedChannel) { channel in
      PlayerView(channel: channel.login, auth: auth)
        .environment(\.themePalette, resolvedPalette)
    }
    .fullScreenCover(isPresented: $showSignIn) {
      SignInView(auth: auth) {
        Task {
          await refreshFollowedChannelsIfNeeded(force: true)
          requestFocusIfPossible(force: true)
        }
      }
      .environment(\.themePalette, resolvedPalette)
      .preferredColorScheme(themeManager.theme.preferredColorScheme)
    }
    .toolbar(.visible, for: .tabBar)
  }

  @ViewBuilder
  private func tabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ZStack {
      LinearGradient(
        colors: resolvedPalette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var homeTab: some View {
    GeometryReader { proxy in
      let rail = channelRailMetrics(for: proxy.size.width)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 40) {
          followingSection(rail: rail)
          recommendedChannelsSection(rail: rail)
          recommendedCategoriesSection(rail: rail)
          authBanner
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 20)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func followingSection(rail: ChannelRailMetrics) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        Text(follows.isUsingDemoData ? "Trending" : "Following")
          .font(.title.weight(.bold))

        if follows.isLoading {
          ProgressView()
            .scaleEffect(0.85)
        }

        Spacer()

        Button("Refresh") {
          Task {
            await refreshFollowedChannelsIfNeeded(force: true)
            await refreshRecommendationsIfNeeded(force: true)
            requestFocusIfPossible(force: true)
          }
        }

        streamCardSettingsMenu
      }

      if let errorMessage = follows.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.orange)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: rail.spacing) {
          ForEach(follows.channels) { channel in
            let itemID = "following-\(channel.id)"
            let isFocused = focusedItemID == itemID

            FollowedChannelCard(
              channel: channel,
              isFocused: isFocused,
              mediaWidth: rail.mediaWidth,
              mediaHeight: rail.mediaHeight,
              focusHorizontalInset: focusHorizontalInset,
              focusVerticalInset: focusVerticalInset,
              cardCornerRadius: cardCornerRadius,
              mediaCornerRadius: mediaCornerRadius
            )
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
            .focusable(true)
            .focused($focusedItemID, equals: itemID)
            .focusEffectDisabled()
            .onTapGesture {
              selectedChannel = channel
            }
            .accessibilityAddTraits(.isButton)
            .scaleEffect(isFocused ? focusedCardScale : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .zIndex(isFocused ? 2 : 0)
          }
        }
        .padding(.vertical, channelRailVerticalPadding)
      }
      .scrollClipDisabled()

      if follows.channels.isEmpty {
        Text(follows.isUsingDemoData ? "No trending channels are available right now." : "No followed channels are available yet.")
          .foregroundStyle(.secondary)
      }
    }
    .focusSection()
  }

  @ViewBuilder
  private func recommendedChannelsSection(rail: ChannelRailMetrics) -> some View {
    let followedIDs = Set(follows.channels.map(\.id))
    let recommended = recommendations.channels.filter { !followedIDs.contains($0.id) }

    if !recommended.isEmpty {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("Recommended channels")
            .font(.title.weight(.bold))

          if recommendations.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(recommended) { channel in
              let itemID = "recommended-\(channel.id)"
              let isFocused = focusedItemID == itemID

              FollowedChannelCard(
                channel: channel,
                isFocused: isFocused,
                mediaWidth: rail.mediaWidth,
                mediaHeight: rail.mediaHeight,
                focusHorizontalInset: focusHorizontalInset,
                focusVerticalInset: focusVerticalInset,
                cardCornerRadius: cardCornerRadius,
                mediaCornerRadius: mediaCornerRadius
              )
              .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                selectedChannel = channel
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? focusedCardScale : 1)
              .animation(.easeOut(duration: 0.14), value: isFocused)
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .padding(.vertical, channelRailVerticalPadding)
        }
        .scrollClipDisabled()
      }
      .focusSection()
    }
  }

  @ViewBuilder
  private func recommendedCategoriesSection(rail: ChannelRailMetrics) -> some View {
    if !recommendations.categories.isEmpty {
      let categoryWidth = max(180, min(240, rail.mediaWidth * 0.6))

      VStack(alignment: .leading, spacing: 24) {
        Text("Recommended categories")
          .font(.title.weight(.bold))

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(recommendations.categories) { category in
              let itemID = "category-\(category.id)"
              let isFocused = focusedItemID == itemID

              HomeCategoryCard(
                category: category,
                isFocused: isFocused,
                width: categoryWidth
              )
              .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                pendingBrowseCategory = category
                selectedTopTab = .browse
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? focusedCardScale : 1)
              .animation(.easeOut(duration: 0.14), value: isFocused)
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .padding(.vertical, channelRailVerticalPadding)
        }
        .scrollClipDisabled()
      }
      .focusSection()
    }
  }

  private var streamCardSettingsMenu: some View {
    Menu {
      Picker("Card Size", selection: $streamCardSizeRaw) {
        ForEach(StreamCardSize.allCases) { size in
          Label("\(size.title) · \(size.subtitle)", systemImage: size.symbolName)
            .tag(size.rawValue)
        }
      }
      // Future: a "Search" entry point can be added here as another menu item.
    } label: {
      Image(systemName: "slider.horizontal.3")
        .font(.headline)
    }
    .accessibilityLabel("View settings")
  }

  private func channelRailMetrics(for availableWidth: CGFloat) -> ChannelRailMetrics {
    let width = max(availableWidth, 1)
    let spacing = max(18, min(32, width * 0.012))
    let rawOuterCardWidth = (width - ((targetVisibleCards - 1) * spacing)) / (targetVisibleCards + peekCardFraction)
    let minOuterCardWidth = minMediaWidth + (focusHorizontalInset * 2)
    let maxOuterCardWidth = maxMediaWidth + (focusHorizontalInset * 2)
    let outerCardWidth = min(max(rawOuterCardWidth, minOuterCardWidth), maxOuterCardWidth)
    let mediaWidth = outerCardWidth - (focusHorizontalInset * 2)
    let mediaHeight = mediaWidth * 9 / 16

    return ChannelRailMetrics(
      spacing: spacing,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight
    )
  }

  @ViewBuilder
  private var authBanner: some View {
    if !auth.isAuthenticated {
      HStack(spacing: 28) {
        Image(systemName: "person.crop.circle.badge.plus")
          .font(.system(size: 44))
          .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))

        VStack(alignment: .leading, spacing: 6) {
          Text("Sign in with Twitch")
            .font(.title2.weight(.bold))
          Text("Connect your account to see the channels you follow and join the chat.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 24)

        Button("Sign In") {
          showSignIn = true
        }
        .font(.headline)
      }
      .padding(.vertical, 32)
      .padding(.horizontal, 40)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 28)
          .fill(.ultraThinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 28)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      )
      .padding(.top, 12)
      .focusSection()
    }
  }

  /// On the very first app launch (and only then), present the Twitch sign-in
  /// screen to a signed-out viewer. The flag is persisted so we never prompt
  /// again, even if they skip signing in (they can still sign in via Settings
  /// or the Home banner).
  private func promptFirstLaunchSignInIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: firstLaunchSignInPromptKey) else { return }
    defaults.set(true, forKey: firstLaunchSignInPromptKey)

    guard !auth.isAuthenticated else { return }
    showSignIn = true
  }

  private func requestFocusIfPossible(force: Bool) {
    guard let first = follows.channels.first else { return }
    if !force && firstFocusRequested { return }

    firstFocusRequested = true
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      await MainActor.run {
        focusedItemID = "following-\(first.id)"
      }
    }
  }

  private func refreshFollowedChannelsIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshFollowedChannels() else { return }
    await follows.refresh(using: auth)
    publishTopShelfSnapshot()
  }

  private func refreshRecommendationsIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshRecommendations() else { return }
    await recommendations.refresh()
    publishTopShelfSnapshot()
  }

  private func publishTopShelfSnapshot() {
    TopShelfPublisher.publish(
      followed: follows.channels,
      isUsingDemoData: follows.isUsingDemoData,
      recommended: recommendations.channels
    )
  }

  /// Presents the player for a channel requested via deep link (Top Shelf).
  /// Prefers a fully-populated channel from loaded data, otherwise builds a
  /// minimal placeholder — the player only needs the login to start playback.
  private func openDeepLinkedChannelIfNeeded(_ login: String?) {
    guard let login = login?.trimmingCharacters(in: .whitespacesAndNewlines),
          !login.isEmpty
    else { return }

    let match = (follows.channels + recommendations.channels).first {
      $0.login.caseInsensitiveCompare(login) == .orderedSame
    }

    selectedChannel = match ?? FollowedChannel(
      id: login,
      login: login,
      displayName: login,
      title: "",
      gameName: "",
      viewerCount: nil,
      thumbnailURL: nil,
      profileImageURL: nil,
      isLive: true
    )

    deepLinkRouter.pendingChannelLogin = nil
  }

  private func shouldAutoRefreshFollowedChannels() -> Bool {
    guard !follows.isLoading else { return false }
    guard let lastUpdatedAt = follows.lastUpdatedAt else { return true }
    return Date().timeIntervalSince(lastUpdatedAt) >= autoRefreshStaleInterval
  }

  private func shouldAutoRefreshRecommendations() -> Bool {
    guard !recommendations.isLoading else { return false }
    guard let lastUpdatedAt = recommendations.lastUpdatedAt else { return true }
    return Date().timeIntervalSince(lastUpdatedAt) >= autoRefreshStaleInterval
  }
}

private struct FollowedChannelCard: View {
  let channel: FollowedChannel
  let isFocused: Bool
  let mediaWidth: CGFloat
  let mediaHeight: CGFloat
  let focusHorizontalInset: CGFloat
  let focusVerticalInset: CGFloat
  let cardCornerRadius: CGFloat
  let mediaCornerRadius: CGFloat

  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottomLeading) {
        AsyncImage(url: channel.thumbnailURL) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          Color.primary.opacity(0.08)
        }
        .frame(width: mediaWidth, height: mediaHeight)
        .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))

        LinearGradient(
          colors: [Color.clear, Color.black.opacity(0.82)],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(width: mediaWidth, height: mediaHeight)
        .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))

        HStack(spacing: 8) {
          Circle()
            .fill(channel.isLive ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
          if let viewerCount = channel.viewerCount {
            Text("\(viewerCount) watching")
              .font(.caption2)
              .foregroundStyle(Color.white.opacity(0.78))
          }
        }
        .padding(12)
      }
      .frame(width: mediaWidth, alignment: .leading)

      Text(channel.displayName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isFocused ? palette.liftPrimaryText : Color.primary)
        .lineLimit(1)

      Text(channel.title.isEmpty ? "No title" : channel.title)
        .font(.footnote)
        .foregroundStyle(isFocused ? palette.liftSecondaryText : Color.secondary)
        .lineLimit(2)
        .frame(height: 38, alignment: .topLeading)

      Text(channel.gameName)
        .font(.caption2)
        .foregroundStyle(isFocused ? palette.liftSecondaryText : Color.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, focusHorizontalInset)
    .padding(.vertical, focusVerticalInset)
    .frame(width: mediaWidth + (focusHorizontalInset * 2), alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: cardCornerRadius)
        .fill(isFocused ? palette.liftSurface : Color.clear)
    }
    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
    .shadow(color: Color.black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
  }
}

private struct HomeCategoryCard: View {
  let category: TwitchCategory
  let isFocused: Bool
  let width: CGFloat

  @Environment(\.themePalette) private var palette

  private let cornerRadius: CGFloat = 16
  private let artRatio: CGFloat = 285.0 / 380.0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      AsyncImage(url: category.boxArtURL) { img in
        img
          .resizable()
          .scaledToFill()
      } placeholder: {
        Color.primary.opacity(0.08)
      }
      .frame(width: width, height: width / artRatio)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 2))

      VStack(alignment: .leading, spacing: 4) {
        Text(category.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isFocused ? palette.liftPrimaryText : Color.primary)
          .lineLimit(2, reservesSpace: true)

        if let viewers = category.viewerCount {
          Text("\(viewers) watching")
            .font(.caption2)
            .foregroundStyle(isFocused ? palette.liftSecondaryText : Color.secondary)
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
    .frame(width: width + 20)
    .background {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(isFocused ? palette.liftSurface : Color.primary.opacity(0.07))
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  }
}

#Preview {
  HomeView(deepLinkRouter: DeepLinkRouter())
}

// MARK: - Custom Fixed Tab Bar

private struct CustomTopTabBar: View {
    @Binding var selection: HomeView.TopTab
    @Namespace private var focusNamespace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HomeView.TopTab.allCases) { tab in
                CustomTopTabBarButton(
                    tab: tab,
                    selection: $selection,
                    namespace: focusNamespace
                )
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        .padding(.top, 40)
    }
}

private struct CustomTopTabBarButton: View {
    let tab: HomeView.TopTab
    @Binding var selection: HomeView.TopTab
    let namespace: Namespace.ID
    
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme
    
    var isSelected: Bool { selection == tab }
    
    var body: some View {
        Button(action: {
            selection = tab
        }) {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: tab))
                    .font(.body.weight(isSelected ? .semibold : .medium))
                
                // Only show text if selected or focused, closely matching tvOS dynamic styles
                if isSelected || isFocused {
                    Text(tab.rawValue)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(isFocused ? Color.primary : (isSelected ? Color.primary : Color.secondary))
            .background {
                if isFocused {
                    Capsule()
                        .fill(Material.regularMaterial)
                        .shadow(color: Color.black.opacity(0.1), radius: 8, y: 4)
                        .matchedGeometryEffect(id: "focusRing", in: namespace)
                } else if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.15))
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.2), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }
    
    func iconName(for tab: HomeView.TopTab) -> String {
        switch tab {
        case .home: return isSelected ? "house.fill" : "house"
        case .browse: return isSelected ? "square.grid.2x2.fill" : "square.grid.2x2"
        case .settings: return isSelected ? "gearshape.fill" : "gearshape"
        }
    }
}
