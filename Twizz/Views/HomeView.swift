import SwiftUI

struct HomeView: View {
  let deepLinkRouter: DeepLinkRouter

  private let channelRailVerticalPadding: CGFloat = 20
  private let focusVerticalInset: CGFloat = 18
  /// Mirror of the shared rail inset so the card-render sites keep one name.
  private var focusHorizontalInset: CGFloat { ChannelRailLayout.focusHorizontalInset }
  private let cardCornerRadius: CGFloat = 30
  private let mediaCornerRadius: CGFloat = 18
  private let autoRefreshStaleInterval: TimeInterval = 5 * 60

  @State private var selectedSidebarTab: SidebarTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var recommendations = RecommendationsService()
  @State private var personalized = PersonalizedRecommendationsService()
  @State private var watchHistory = WatchHistoryService()
  @State private var feedback = RecommendationFeedbackService()
  @State private var affinity = StreamerAffinityService()
  @State private var youtubeAliases = TwitchYouTubeAliasService()
  @State private var youtubeLive = YouTubeLiveSnapshotService()
  @State private var youtubeAuth = YouTubeAuthSession()
  @State private var youtubeSubscriptions = YouTubeSubscriptionsService()
  @State private var themeManager = ThemeManager()
  @State private var selectedChannel: FollowedChannel?
  @State private var channelPageTarget: ChannelPageTarget?
  @State private var pendingWatchChannel: FollowedChannel?
  /// Active multiview launch (roster). Item-based so the cover always presents
  /// with the chosen channels — `isPresented` + a separate roster var raced on
  /// first launch and showed an empty (black) wall.
  @State private var multiviewLaunch: MultiviewLaunch?
  /// Categories opened from the Home tab are pushed one level deep here, so the
  /// category view is genuinely L2 of Home rather than a tab switch into Browse.
  @State private var homePath: [TwitchCategory] = []
  @State private var showingFollowingDirectory = false
  @State private var firstFocusRequested = false
  @State private var showSignIn = false
  @State private var showYouTubeSignIn = false
  @State private var refreshToast: RefreshToastState?
  @State private var goLive = GoLiveWatcher()
  @State private var goLiveSettings = GoLiveNotificationSettings()
  /// "Top streams" — the most-viewed live channels (after the language filter),
  /// in viewer-count order, with only "Not interested" channels removed. Cached
  /// here and recomputed only when the source list or block list changes, so we
  /// don't rebuild the filter on every HomeView body pass (focus changes,
  /// scrolling, animations).
  @State private var topStreams: [FollowedChannel] = []
  /// Followed channels that are live right now — the pool multiview draws from.
  /// Memoized (rather than a computed `filter` over `follows.channels`) so the
  /// large HomeView body doesn't re-filter the whole follow list on every focus
  /// move and animation frame. Recomputed only when `follows.channels` changes.
  @State private var liveFollowedChannels: [FollowedChannel] = []

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedEnabled = true
  @AppStorage(StreamLanguagePreference.storageKey) private var streamLanguage = StreamLanguagePreference.deviceDefault()

  @Environment(\.colorScheme) private var systemColorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.glassDisabled) private var glassDisabled
  @FocusState private var focusedItemID: String?

  private let firstLaunchSignInPromptKey = "hasPromptedFirstLaunchSignIn"

  private var resolvedPalette: ThemePalette {
    themeManager.theme.palette(systemColorScheme: systemColorScheme)
  }

  private var streamCardSize: StreamCardSize {
    StreamCardSize.resolve(streamCardSizeRaw)
  }

  /// Followed channels that are live right now — the pool multiview draws from.
  private func recomputeLiveFollowed() {
    liveFollowedChannels = follows.channels.filter(\.isLive)
  }

  /// Discovery sections for the multiview setup picker: Following first (the
  /// most-wanted pool), then personalized recommendations, then popular streams.
  /// `MultiviewSetupView` filters each to live and dedupes across sections.
  private var multiviewSections: [MultiviewChannelSection] {
    var sections: [MultiviewChannelSection] = [
      MultiviewChannelSection(
        id: "following",
        title: follows.isUsingDemoData ? "Trending" : "Following",
        channels: liveFollowedChannels
      )
    ]
    if personalizedEnabled, !personalized.channels.isEmpty {
      sections.append(
        MultiviewChannelSection(id: "recommended", title: "Recommended for you", channels: personalized.channels)
      )
    }
    if !topStreams.isEmpty {
      sections.append(
        MultiviewChannelSection(id: "popular", title: "Popular right now", channels: topStreams)
      )
    } else if !recommendations.channels.isEmpty {
      sections.append(
        MultiviewChannelSection(id: "popular", title: "Popular right now", channels: recommendations.channels)
      )
    }
    return sections
  }

  /// Every live channel the in-session "Add" picker can offer — the union of all
  /// section pools, deduped, so additions aren't limited to follows.
  private var multiviewAvailablePool: [FollowedChannel] {
    var seen = Set<String>()
    return multiviewSections
      .flatMap(\.channels)
      .filter { $0.isLive && seen.insert($0.id).inserted }
  }

  enum SidebarTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case multiview = "Multiview"
    case browse = "Browse"
    case search = "Search"
    case settings = "Settings"

    var id: String { rawValue }

    var glyph: Glyph {
      switch self {
      case .home: return .home
      case .multiview: return .borderAll
      case .browse: return .layoutGrid
      case .search: return .search
      case .settings: return .settings
      }
    }

    /// Asset-catalog name for the vendored Tabler template image, so tab items
    /// use the same icon library as the rest of the app.
    var tablerImageName: String { "tb-\(glyph.rawValue)" }
  }

  var body: some View {
    TabView(selection: $selectedSidebarTab) {
      tabContainer {
        NavigationStack(path: $homePath) {
          homeTab
            .navigationDestination(for: TwitchCategory.self) { category in
              CategoryStreamsView(
                category: category,
                selectedChannel: $selectedChannel,
                channelPageTarget: $channelPageTarget
              )
            }
            .navigationDestination(isPresented: $showingFollowingDirectory) {
              FollowingDirectoryView(
                follows: follows,
                auth: auth,
                selectedChannel: $selectedChannel,
                channelPageTarget: $channelPageTarget
              )
            }
        }
      }
        .tag(SidebarTab.home)
        .tabItem {
          Label(SidebarTab.home.rawValue, image: SidebarTab.home.tablerImageName)
        }

      // The Multiview tab shows the channel picker inline so the tab bar stays
      // visible while choosing. Starting playback presents the immersive player
      // as a full-screen cover (where hiding the tab bar is expected).
      tabContainer {
        MultiviewSetupView(
          sections: multiviewSections,
          onStart: { channels in
            multiviewLaunch = MultiviewLaunch(channels: channels)
          },
          onCancel: { selectedSidebarTab = .home }
        )
      }
      .tag(SidebarTab.multiview)
      .tabItem {
        Label(SidebarTab.multiview.rawValue, image: SidebarTab.multiview.tablerImageName)
      }

      tabContainer {
        BrowseView(
          selectedChannel: $selectedChannel,
          channelPageTarget: $channelPageTarget
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
          channelPageTarget: $channelPageTarget
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
          youtubeAuth: youtubeAuth,
          youtubeSubscriptions: youtubeSubscriptions,
          follows: follows,
          goLiveSettings: goLiveSettings,
          recommendationFeedback: feedback,
          onRequestSignIn: { showSignIn = true },
          onRequestYouTubeSignIn: { showYouTubeSignIn = true },
          onClearWatchHistory: {
            watchHistory.clear()
            Task { await refreshPersonalizedIfNeeded(force: true) }
          },
          onResetNotInterested: {
            feedback.clear()
            recomputeTopStreams()
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
    .overlay(alignment: .top) {
      if let refreshToast {
        RefreshToastView(state: refreshToast)
          .padding(.top, 48)
          .transition(.motionAware(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
      }
    }
    .overlay(alignment: .topTrailing) {
      if let event = goLive.pending {
        GoLiveToastView(
          event: event,
          onWatch: { watchGoLive() }
        )
        .padding(.top, 48)
        .padding(.trailing, 48)
        .transition(.motionAware(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
      }
    }
    .animation(.motionAware(.easeOut(duration: 0.25), reduceMotion: reduceMotion), value: goLive.pending)
    .task {
      auth.restore()
      youtubeAuth.restore()
      goLive.notificationSettings = goLiveSettings
      goLive.start(using: auth)
      promptFirstLaunchSignInIfNeeded()
      // Followed channels and (anonymous) recommendations are independent, so
      // load them concurrently. Personalized recs read follows.channels, so they
      // run after the followed refresh resolves.
      async let followedDone: Void = refreshFollowedChannelsIfNeeded(force: true)
      async let recommendationsDone: Void = refreshRecommendationsIfNeeded(force: true)
      await followedDone
      recomputeLiveFollowed()
      await recommendationsDone
      await refreshPersonalizedIfNeeded(force: true)
      requestFocusIfPossible(force: true)
      openDeepLinkedChannelIfNeeded(deepLinkRouter.pendingChannelLogin)
      await youtubeSubscriptions.refresh(using: youtubeAuth)
    }
    .onChange(of: follows.channels) { _, _ in
      requestFocusIfPossible(force: false)
      recomputeLiveFollowed()
      recomputeTopStreams()
    }
    .onChange(of: recommendations.channels) { _, _ in
      recomputeTopStreams()
    }
    .onChange(of: personalized.channels) { _, _ in
      recomputeTopStreams()
    }
    .onChange(of: auth.isAuthenticated) { _, _ in
      // Re-seed the go-live baseline against the new account's follows.
      goLive.start(using: auth)
      Task {
        await refreshFollowedChannelsIfNeeded(force: true)
        requestFocusIfPossible(force: true)
      }
    }
    .onChange(of: youtubeAuth.isAuthenticated) { _, _ in
      Task { await youtubeSubscriptions.refresh(using: youtubeAuth, force: true) }
    }
    .onChange(of: selectedSidebarTab) { _, tab in
      guard tab == .home else { return }
      Task {
        async let followedDone: Void = refreshFollowedChannelsIfNeeded(force: false)
        async let recommendationsDone: Void = refreshRecommendationsIfNeeded(force: false)
        await followedDone
        await recommendationsDone
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
      PlayerView(channel: channel.login, auth: auth, goLive: goLive, posterURL: channel.thumbnailURL)
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
    .fullScreenCover(item: $multiviewLaunch) { launch in
      MultiviewPlayerView(
        channels: launch.channels,
        availableChannels: multiviewAvailablePool,
        auth: auth,
        goLive: goLive,
        onWatch: { watchHistory.record($0) }
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
    .fullScreenCover(isPresented: $showYouTubeSignIn) {
      YouTubeSignInView(auth: youtubeAuth) {
        Task { await youtubeSubscriptions.refresh(using: youtubeAuth, force: true) }
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
            performManualRefresh()
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
            .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
            .animation(AppLayout.focusScaleAnimation, value: isFocused)
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
                onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
                onNotInterested: { markNotInterested($0) }
              )
              .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                selectedChannel = channel
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
              .animation(AppLayout.focusScaleAnimation, value: isFocused)
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

  private func recomputeTopStreams() {
    let blocked = feedback.blockedLogins
    topStreams = recommendations.channels.filter {
      !blocked.contains($0.login.lowercased())
    }
  }

  @ViewBuilder
  private func topStreamsSection(rail: ChannelRailMetrics) -> some View {
    let top = topStreams

    if !top.isEmpty {
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
                onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
                onNotInterested: { markNotInterested($0) }
              )
              .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                selectedChannel = channel
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
              .animation(AppLayout.focusScaleAnimation, value: isFocused)
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
          .accessibilityAddTraits(.isHeader)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(recommendations.categories) { category in
              let itemID = "category-\(category.id)"
              let isFocused = focusedItemID == itemID

              CategoryCardView(
                category: category,
                isFocused: isFocused,
                width: categoryWidth
              )
              .contentShape(RoundedRectangle(cornerRadius: CategoryCardView.contentShapeCornerRadius))
              .focusable(true)
              .focused($focusedItemID, equals: itemID)
              .focusEffectDisabled()
              .onTapGesture {
                homePath.append(category)
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
              .animation(AppLayout.focusScaleAnimation, value: isFocused)
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

  private func channelRailMetrics(for availableWidth: CGFloat, trailingSafeArea: CGFloat = 0) -> ChannelRailMetrics {
    ChannelRailLayout.metrics(
      availableWidth: availableWidth,
      trailingSafeArea: trailingSafeArea,
      visibleCardCount: streamCardSize.visibleCardCount
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
          .fill(glassDisabled ? AnyShapeStyle(Color.twizzOpaqueGlass) : AnyShapeStyle(.ultraThinMaterial))
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

  /// Force-refreshes every Home rail and surfaces a brief toast so the viewer
  /// gets feedback that a refresh actually happened. Triggered by the header
  /// Refresh button. Ignores taps while a refresh is already running.
  private func performManualRefresh() {
    guard refreshToast == nil else { return }
    Task {
      withAnimation(.easeOut(duration: 0.25)) { refreshToast = .refreshing }
      async let followedDone: Void = refreshFollowedChannelsIfNeeded(force: true)
      async let recommendationsDone: Void = refreshRecommendationsIfNeeded(force: true)
      await followedDone
      recomputeLiveFollowed()
      await recommendationsDone
      await refreshPersonalizedIfNeeded(force: true)
      requestFocusIfPossible(force: true)
      withAnimation(.easeOut(duration: 0.25)) { refreshToast = .done }
      try? await Task.sleep(for: .seconds(1.6))
      withAnimation(.easeOut(duration: 0.25)) { refreshToast = nil }
    }
  }

  private func refreshFollowedChannelsIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshFollowedChannels() else { return }
    await follows.refresh(using: auth)
    await refreshYouTubePresence()
    publishTopShelfSnapshot()
  }

  /// Pulls the latest Twitch→YouTube alias table and live snapshot (both public,
  /// parameter-free downloads) and merges any live YouTube presence into the
  /// followed channels so dual-platform streamers render as one combined card.
  private func refreshYouTubePresence() async {
    await youtubeAliases.refreshIfNeeded()
    await youtubeLive.refreshIfNeeded()
    follows.applyYouTubePresence(aliases: youtubeAliases, live: youtubeLive)
  }

  private func refreshRecommendationsIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshRecommendations() else { return }
    await recommendations.refresh()
    publishTopShelfSnapshot()
  }

  private func refreshPersonalizedIfNeeded(force: Bool) async {
    guard force || shouldAutoRefreshPersonalized() else { return }
    await affinity.refreshIfNeeded()
    await personalized.refresh(
      follows: follows.channels,
      followedCategories: follows.followedCategories,
      followedLogins: follows.followedLogins,
      history: watchHistory,
      feedback: feedback.snapshot,
      affinity: affinity.snapshot
    )
  }

  /// Banishes a recommended channel: records the "Not interested" feedback,
  /// drops it from the rails immediately, and learns its title as a soft negative
  /// signal so look-alikes stop resurfacing.
  private func markNotInterested(_ channel: FollowedChannel) {
    feedback.markNotInterested(channel)
    personalized.remove(login: channel.login)
    recomputeTopStreams()
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

  /// Acts on the current "just went live" toast: dismisses it and starts
  /// playback for the channel. Reuses a loaded `FollowedChannel` when we already
  /// have one, otherwise a minimal placeholder (the player only needs the login).
  private func watchGoLive() {
    guard let event = goLive.pending else { return }
    goLive.watch()

    let match = (follows.channels + recommendations.channels).first {
      $0.login.caseInsensitiveCompare(event.login) == .orderedSame
    }
    selectedChannel = match ?? FollowedChannel(
      id: event.login,
      login: event.login,
      displayName: event.displayName,
      title: "",
      gameName: event.gameName,
      viewerCount: nil,
      thumbnailURL: nil,
      profileImageURL: nil,
      isLive: true
    )
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

#Preview {
  HomeView(deepLinkRouter: DeepLinkRouter())
}

// MARK: - Refresh toast

/// One multiview session launch — wraps the chosen roster so the cover can be
/// presented with `fullScreenCover(item:)`, which (unlike `isPresented` plus a
/// separate roster var) always builds its content with the channels in hand.
struct MultiviewLaunch: Identifiable {
  let id = UUID()
  let channels: [FollowedChannel]
}

enum RefreshToastState {
  case refreshing
  case done
}/// Small pill that confirms a manual Home refresh is happening / finished, so a
/// re-tap of the Home tab gives the viewer visible feedback.
private struct RefreshToastView: View {
  let state: RefreshToastState
  @Environment(\.glassDisabled) private var glassDisabled

  var body: some View {
    HStack(spacing: 14) {
      switch state {
      case .refreshing:
        ProgressView()
          .scaleEffect(0.9)
        Text("Refreshing…")
      case .done:
        Icon(glyph: .circleCheckFilled, size: 30)
          .foregroundStyle(.green)
        Text("Refreshed")
      }
    }
    .font(.headline)
    .padding(.horizontal, 30)
    .padding(.vertical, 18)
    .background {
      if glassDisabled {
        Capsule().fill(Color.twizzOpaqueGlass)
          .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
      } else if #available(tvOS 26.0, *) {
        Capsule().glassEffect(.regular, in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
  }
}
