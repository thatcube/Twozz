import SwiftUI

struct HomeView: View {
  let deepLinkRouter: DeepLinkRouter

  private let channelRailVerticalPadding: CGFloat = 20
  private let peekCardFraction: CGFloat = 0.08
  private let focusHorizontalInset: CGFloat = 18
  private let focusVerticalInset: CGFloat = 18
  private let cardCornerRadius: CGFloat = 30
  private let mediaCornerRadius: CGFloat = 18
  private let minMediaWidth: CGFloat = 220
  private let maxMediaWidth: CGFloat = 900
  private let focusedCardScale: CGFloat = 1.07
  private let autoRefreshStaleInterval: TimeInterval = 5 * 60

  @State private var selectedSidebarTab: SidebarTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var recommendations = RecommendationsService()
  @State private var personalized = PersonalizedRecommendationsService()
  @State private var watchHistory = WatchHistoryService()
  @State private var themeManager = ThemeManager()
  @State private var selectedChannel: FollowedChannel?
  @State private var channelPageTarget: ChannelPageTarget?
  @State private var pendingWatchChannel: FollowedChannel?
  @State private var pendingBrowseCategory: TwitchCategory?
  @State private var browsePath: [TwitchCategory] = []
  @State private var firstFocusRequested = false
  @State private var showSignIn = false

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedEnabled = true
  @AppStorage(StreamLanguagePreference.storageKey) private var streamLanguage = StreamLanguagePreference.deviceDefault()

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

  enum SidebarTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case browse = "Browse"
    case search = "Search"
    case settings = "Settings"

    var id: String { rawValue }

    var glyph: Glyph {
      switch self {
      case .home: return .home
      case .browse: return .layoutGrid
      case .search: return .search
      case .settings: return .settings
      }
    }

    /// Asset-catalog name for the vendored Tabler template image, so tab items
    /// use the same icon library as the rest of the app.
    var tablerImageName: String { "tb-\(glyph.rawValue)" }
  }

  private struct ChannelRailMetrics {
    let spacing: CGFloat
    let mediaWidth: CGFloat
    let mediaHeight: CGFloat
  }

  var body: some View {
    TabView(selection: $selectedSidebarTab) {
      tabContainer { homeTab }
        .tag(SidebarTab.home)
        .tabItem {
          Label(SidebarTab.home.rawValue, image: SidebarTab.home.tablerImageName)
        }

      tabContainer {
        BrowseView(
          auth: auth,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget,
          pendingCategory: $pendingBrowseCategory,
          path: $browsePath
        )
      }
      .tag(SidebarTab.browse)
      .tabItem {
        Label(SidebarTab.browse.rawValue, image: SidebarTab.browse.tablerImageName)
      }

      tabContainer {
        SearchView(
          auth: auth,
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget,
          onSelectCategory: { category in
            pendingBrowseCategory = category
            selectedSidebarTab = .browse
          }
        )
      }
      .tag(SidebarTab.search)
      .tabItem {
        Label(SidebarTab.search.rawValue, image: SidebarTab.search.tablerImageName)
      }

      tabContainer {
        SettingsView(
          themeManager: themeManager,
          auth: auth,
          onRequestSignIn: { showSignIn = true },
          onClearWatchHistory: {
            watchHistory.clear()
            Task { await refreshPersonalizedIfNeeded(force: true) }
          },
          onAccountChanged: {
            Task {
              await refreshFollowedChannelsIfNeeded(force: true)
              requestFocusIfPossible(force: true)
            }
          },
          onRepublishTopShelf: { publishTopShelfSnapshot() }
        )
      }
      .tag(SidebarTab.settings)
      .tabItem {
        Label(SidebarTab.settings.rawValue, image: SidebarTab.settings.tablerImageName)
      }
    }
    .tabViewStyle(.automatic)
    .background(AppBackground(palette: resolvedPalette))
    .environment(\.themePalette, resolvedPalette)
    .preferredColorScheme(themeManager.theme.preferredColorScheme)
    .task {
      auth.restore()
      promptFirstLaunchSignInIfNeeded()
      await refreshFollowedChannelsIfNeeded(force: true)
      await refreshRecommendationsIfNeeded(force: true)
      await refreshPersonalizedIfNeeded(force: true)
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
    .onChange(of: selectedSidebarTab) { _, tab in
      // tvOS SwiftUI bug: while the Browse tab's NavigationStack has a pushed
      // detail, the sidebar won't switch tabs. Popping Browse to root as the
      // selection leaves Browse lets the tab change take effect.
      if tab != .browse && !browsePath.isEmpty {
        browsePath.removeAll()
      }
      guard tab == .home else { return }
      Task {
        await refreshFollowedChannelsIfNeeded(force: false)
        await refreshRecommendationsIfNeeded(force: false)
        await refreshPersonalizedIfNeeded(force: false)
      }
    }
    .onChange(of: deepLinkRouter.pendingChannelLogin) { _, login in
      openDeepLinkedChannelIfNeeded(login)
    }
    .onChange(of: selectedChannel) { _, channel in
      // Single funnel for every play (Following, recommendations, Browse, Search,
      // channel page, deep links) — record it for on-device personalization.
      if let channel { watchHistory.record(channel) }
    }
    .onChange(of: personalizedEnabled) { _, _ in
      Task { await refreshPersonalizedIfNeeded(force: true) }
    }
    .onChange(of: streamLanguage) { _, _ in
      Task {
        await refreshRecommendationsIfNeeded(force: true)
        await refreshPersonalizedIfNeeded(force: true)
      }
    }
    .fullScreenCover(item: $selectedChannel) { channel in
      PlayerView(channel: channel.login, auth: auth)
        .environment(\.themePalette, resolvedPalette)
    }
    .fullScreenCover(item: $channelPageTarget, onDismiss: { presentPendingWatchIfNeeded() }) { target in
      ChannelPageView(
        target: target,
        onWatchChannel: { channel in
          pendingWatchChannel = channel
          channelPageTarget = nil
        }
      )
      .environment(\.themePalette, resolvedPalette)
      .preferredColorScheme(themeManager.theme.preferredColorScheme)
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
  }

  @ViewBuilder
  private func tabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ZStack {
      AppBackground(palette: resolvedPalette)

      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var homeTab: some View {
    GeometryReader { proxy in
      let rail = channelRailMetrics(
        for: proxy.size.width,
        trailingSafeArea: proxy.safeAreaInsets.trailing
      )

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 72) {
          followingSection(rail: rail)
          recommendedForYouSection(rail: rail)
          topStreamsSection(rail: rail)
          recommendedCategoriesSection(rail: rail)
          authBanner
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func followingSection(rail: ChannelRailMetrics) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(follows.isUsingDemoData ? "Trending" : "Following")
          .font(.system(size: 32, weight: .bold))

        if follows.isLoading {
          ProgressView()
            .scaleEffect(0.85)
        }

        Spacer()

        Button("Refresh") {
          Task {
            await refreshFollowedChannelsIfNeeded(force: true)
            await refreshRecommendationsIfNeeded(force: true)
            await refreshPersonalizedIfNeeded(force: true)
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

            StreamChannelCard(
              channel: channel,
              isFocused: isFocused,
              layout: .rail(
                mediaWidth: rail.mediaWidth,
                mediaHeight: rail.mediaHeight,
                focusHorizontalInset: focusHorizontalInset,
                focusVerticalInset: focusVerticalInset,
                cardCornerRadius: cardCornerRadius,
                mediaCornerRadius: mediaCornerRadius
              ),
              showsGameName: true,
              onWatch: { selectedChannel = $0 },
              onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) }
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
  private func recommendedForYouSection(rail: ChannelRailMetrics) -> some View {
    let channels = personalized.channels

    if personalizedEnabled, !channels.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Recommended for you")
            .font(.system(size: 32, weight: .bold))

          if personalized.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(channels) { channel in
              let itemID = "foryou-\(channel.id)"
              let isFocused = focusedItemID == itemID

              StreamChannelCard(
                channel: channel,
                isFocused: isFocused,
                layout: .rail(
                  mediaWidth: rail.mediaWidth,
                  mediaHeight: rail.mediaHeight,
                  focusHorizontalInset: focusHorizontalInset,
                  focusVerticalInset: focusVerticalInset,
                  cardCornerRadius: cardCornerRadius,
                  mediaCornerRadius: mediaCornerRadius
                ),
                showsGameName: true,
                onWatch: { selectedChannel = $0 },
                onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) }
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
  private func topStreamsSection(rail: ChannelRailMetrics) -> some View {
    let followedIDs = Set(follows.channels.map(\.id))
    let personalizedLogins = Set(personalized.channels.map { $0.login.lowercased() })
    let top = recommendations.channels.filter {
      !followedIDs.contains($0.id) && !personalizedLogins.contains($0.login.lowercased())
    }

    if !top.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Top streams")
            .font(.system(size: 32, weight: .bold))

          if recommendations.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(top) { channel in
              let itemID = "topstreams-\(channel.id)"
              let isFocused = focusedItemID == itemID

              StreamChannelCard(
                channel: channel,
                isFocused: isFocused,
                layout: .rail(
                  mediaWidth: rail.mediaWidth,
                  mediaHeight: rail.mediaHeight,
                  focusHorizontalInset: focusHorizontalInset,
                  focusVerticalInset: focusVerticalInset,
                  cardCornerRadius: cardCornerRadius,
                  mediaCornerRadius: mediaCornerRadius
                ),
                showsGameName: true,
                onWatch: { selectedChannel = $0 },
                onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) }
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

      VStack(alignment: .leading, spacing: 2) {
        Text("Recommended categories")
          .font(.system(size: 32, weight: .bold))

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
                selectedSidebarTab = .browse
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
          Text("\(size.title) · \(size.subtitle)")
            .tag(size.rawValue)
        }
      }
      // Future: a "Search" entry point can be added here as another menu item.
    } label: {
      Icon(glyph: .dimensions, size: 34)
    }
    .accessibilityLabel("View settings")
  }

  private func channelRailMetrics(for availableWidth: CGFloat, trailingSafeArea: CGFloat = 0) -> ChannelRailMetrics {
    // `availableWidth` is the safe-area width. Cards begin at the left page
    // gutter, but because the horizontal rails disable scroll clipping they
    // paint rightward past the safe area, through the trailing overscan, all
    // the way to the true screen edge. The real visible span is therefore the
    // safe width, minus the single left gutter, plus the trailing overscan the
    // cards bleed into. Without adding that overscan back, a fixed ~overscan
    // slice of the next card always shows (a larger fraction on smaller cards).
    let visibleWidth = max(availableWidth - AppLayout.horizontalPadding + trailingSafeArea, 1)
    let n = targetVisibleCards
    let peek = peekCardFraction
    let baseSpacing = max(18, min(32, visibleWidth * 0.012))
    let spacing = min(baseSpacing + 4, 36)
    // Fit `n` full cards plus a `peek` sliver of the next one, with a full
    // spacing gap before each of those following cards (n gaps total). Solving
    // visibleWidth = (n + peek) * outer + n * spacing for `outer`.
    let rawOuterCardWidth = (visibleWidth - (n * spacing)) / (n + peek)
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
        Icon(glyph: .userPlus, size: 44)
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

  private func refreshPersonalizedIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshPersonalized() else { return }
    await personalized.refresh(
      follows: follows.channels,
      followedCategories: follows.followedCategories,
      history: watchHistory
    )
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

  /// After the channel page is dismissed via a "Watch Live" button (this channel
  /// or a "More like this" pick), start playback for that channel. Runs from the
  /// cover's `onDismiss` so the player cover presents cleanly after the
  /// channel-page cover has fully gone away.
  private func presentPendingWatchIfNeeded() {
    guard let channel = pendingWatchChannel else { return }
    pendingWatchChannel = nil
    selectedChannel = channel
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

  private func shouldAutoRefreshPersonalized() -> Bool {
    guard !personalized.isLoading else { return false }
    guard let lastUpdatedAt = personalized.lastUpdatedAt else { return true }
    return Date().timeIntervalSince(lastUpdatedAt) >= autoRefreshStaleInterval
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
    .frame(width: width + 20)
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

#Preview {
  HomeView(deepLinkRouter: DeepLinkRouter())
}
