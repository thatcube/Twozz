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

  /// App-level composition root: the long-lived, app-global services. Owned by
  /// `AppEnvironment` (instantiated once in `TwizzApp`) and injected here via
  /// `.environment(_:)`, so HomeView is no longer the de-facto composition root.
  @Environment(AppEnvironment.self) private var environment

  // Thin forwarding accessors so the rest of HomeView keeps reading these
  // services by their familiar names while ownership lives in `environment`.
  private var auth: TwitchAuthSession { environment.auth }
  private var follows: FollowedChannelsService { environment.follows }
  private var recommendations: RecommendationsService { environment.recommendations }
  private var personalized: PersonalizedRecommendationsService { environment.personalized }
  private var watchHistory: WatchHistoryService { environment.watchHistory }
  private var feedback: RecommendationFeedbackService { environment.feedback }
  private var affinity: StreamerAffinityService { environment.affinity }
  private var youtubeAliases: TwitchYouTubeAliasService { environment.youtubeAliases }
  private var youtubeLive: YouTubeLiveSnapshotService { environment.youtubeLive }
  private var youtubeConcurrentViewers: YouTubeConcurrentViewersService {
    environment.youtubeConcurrentViewers
  }
  private var youtubeAuth: YouTubeAuthSession { environment.youtubeAuth }
  private var youtubeSubscriptions: YouTubeSubscriptionsService { environment.youtubeSubscriptions }
  private var youtubeResolver: YouTubeLiveResolver { environment.youtubeResolver }
  private var themeManager: ThemeManager { environment.themeManager }
  private var goLive: GoLiveWatcher { environment.goLive }
  private var goLiveSettings: GoLiveNotificationSettings { environment.goLiveSettings }
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
  @State private var youtubePlayback: YouTubePlaybackTarget?
  @AppStorage(YouTubePreferences.showSubscriptionsKey) private var showYouTubeSubscriptions = true
  @State private var refreshToast: RefreshToastState?
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
                selectedChannel: $selectedChannel,
                channelPageTarget: $channelPageTarget
              )
              .environment(environment)
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
      await refreshYouTubeSubscriptionLiveness()
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
      Task {
        await youtubeSubscriptions.refresh(using: youtubeAuth, force: true)
        await refreshYouTubeSubscriptionLiveness(force: true)
      }
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
        Task {
          await youtubeSubscriptions.refresh(using: youtubeAuth, force: true)
          await refreshYouTubeSubscriptionLiveness(force: true)
        }
      }
      .environment(\.themePalette, resolvedPalette)
      .preferredColorScheme(themeManager.theme.preferredColorScheme)
    }
    .fullScreenCover(item: $youtubePlayback) { target in
      YouTubeLivePlayerView(videoID: target.videoID, title: target.title)
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

  /// Shared rail layout constants handed to each extracted Home section so they
  /// build the same card layout HomeView used inline.
  private var railStyle: HomeRailStyle {
    HomeRailStyle(
      focusHorizontalInset: focusHorizontalInset,
      focusVerticalInset: focusVerticalInset,
      cardCornerRadius: cardCornerRadius,
      mediaCornerRadius: mediaCornerRadius,
      railVerticalPadding: channelRailVerticalPadding
    )
  }

  private var homeTab: some View {
    GeometryReader { proxy in
      let rail = channelRailMetrics(
        for: proxy.size.width,
        trailingSafeArea: proxy.safeAreaInsets.trailing
      )

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 72) {
          HomeFollowingSection(
            channels: followingRowChannels,
            rail: rail,
            style: railStyle,
            showingFollowingDirectory: $showingFollowingDirectory,
            onRefresh: { performManualRefresh() },
            onWatch: { openFollowingChannel($0) },
            onGoToChannel: { channel in
              if isYouTubeOnly(channel) {
                playYouTube(channel)
              } else {
                channelPageTarget = ChannelPageTarget(channel: channel)
              }
            },
            focusedItemID: $focusedItemID
          )
          HomeRecommendedForYouSection(
            personalizedEnabled: personalizedEnabled,
            rail: rail,
            style: railStyle,
            onWatch: { selectedChannel = $0 },
            onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
            onNotInterested: { markNotInterested($0) },
            focusedItemID: $focusedItemID
          )
          HomeTopStreamsSection(
            channels: topStreams,
            rail: rail,
            style: railStyle,
            onWatch: { selectedChannel = $0 },
            onGoToChannel: { channelPageTarget = ChannelPageTarget(channel: $0) },
            onNotInterested: { markNotInterested($0) },
            focusedItemID: $focusedItemID
          )
          HomeRecommendedCategoriesSection(
            rail: rail,
            style: railStyle,
            homePath: $homePath,
            focusedItemID: $focusedItemID
          )
          HomeAuthBanner(onSignIn: { showSignIn = true })
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  // MARK: - YouTube subscriptions

  /// Normalizes a streamer name for cross-platform identity matching: lowercased
  /// with everything but letters/digits stripped, so "Ludwig" (Twitch) and
  /// "Ludwig" (YouTube), or "fuslie"/"Fuslie", collapse to the same key.
  private func normalizedStreamerKey(_ name: String) -> String {
    name.lowercased().unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }.map(String.init).joined()
  }

  /// Identity keys for streamers already shown on the Following (Twitch) rail —
  /// by YouTube channel ID (enriched presence or alias table) and by normalized
  /// display name / login — so a streamer live on both platforms is never
  /// duplicated as a separate YouTube card.
  private var twitchRepresentedKeys: (channelIDs: Set<String>, names: Set<String>) {
    var channelIDs = Set(follows.channels.compactMap { $0.youtube?.channelID })
    var names = Set<String>()
    for channel in follows.channels {
      if let mapped = youtubeAliases.youtubeChannelID(forTwitchLogin: channel.login) {
        channelIDs.insert(mapped)
      }
      names.insert(normalizedStreamerKey(channel.displayName))
      names.insert(normalizedStreamerKey(channel.login))
    }
    names.remove("")
    return (channelIDs, names)
  }

  /// Subscribed YouTube streamers who are live right now, as standard cards, with
  /// any streamer already on the Following (Twitch) rail removed so there's a
  /// single card per streamer. Rendered with the shared `LiveBadge` like every
  /// other card — `isLive`/`viewerCount` carry the YouTube live state.
  private var liveYouTubeSubscriptionCards: [FollowedChannel] {
    guard showYouTubeSubscriptions else { return [] }
    let represented = twitchRepresentedKeys
    return youtubeSubscriptions.subscriptions.compactMap { sub in
      guard let presence = youtubeResolver.presence(forChannelID: sub.channelID),
        presence.isLive,
        !represented.channelIDs.contains(sub.channelID),
        !represented.names.contains(normalizedStreamerKey(sub.title))
      else { return nil }

      let thumbnailURL = presence.videoID.flatMap {
        URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg")
      }
      var channel = FollowedChannel(
        id: "yt-\(sub.channelID)",
        login: sub.channelID,
        displayName: sub.title,
        title: presence.title ?? "",
        gameName: "",
        viewerCount: presence.viewerCount,
        thumbnailURL: thumbnailURL,
        profileImageURL: sub.thumbnailURL,
        isLive: true
      )
      channel.youtube = presence
      return channel
    }
  }

  /// The single Following rail: Twitch follows plus the deduped, currently-live
  /// YouTube-only subscriptions.
  private var followingRowChannels: [FollowedChannel] {
    follows.channels + liveYouTubeSubscriptionCards
  }

  /// A merged card that should play via YouTube (no Twitch equivalent).
  private func isYouTubeOnly(_ channel: FollowedChannel) -> Bool {
    channel.id.hasPrefix("yt-")
  }

  private func openFollowingChannel(_ channel: FollowedChannel) {
    if isYouTubeOnly(channel) {
      playYouTube(channel)
    } else {
      selectedChannel = channel
    }
  }

  private func refreshYouTubeSubscriptionLiveness(force: Bool = false) async {
    guard youtubeAuth.isAuthenticated, showYouTubeSubscriptions else { return }
    let ids = youtubeSubscriptions.subscriptions.map(\.channelID)
    await youtubeResolver.refresh(channelIDs: ids, using: youtubeAuth, force: force)
  }

  private func playYouTube(_ channel: FollowedChannel) {
    guard let videoID = channel.youtube?.videoID else { return }
    watchHistory.record(channel)
    youtubePlayback = YouTubePlaybackTarget(
      videoID: videoID,
      title: channel.displayName)
  }

  private func recomputeTopStreams() {
    let blocked = feedback.blockedLogins
    topStreams = recommendations.channels.filter {
      !blocked.contains($0.login.lowercased())
    }
  }

  private func channelRailMetrics(for availableWidth: CGFloat, trailingSafeArea: CGFloat = 0) -> ChannelRailMetrics {
    ChannelRailLayout.metrics(
      availableWidth: availableWidth,
      trailingSafeArea: trailingSafeArea,
      visibleCardCount: streamCardSize.visibleCardCount
    )
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
    await enrichYouTubeViewerCounts()
    follows.applyYouTubePresence(aliases: youtubeAliases, live: youtubeLive)
  }

  /// Fills in real "watching now" counts for channels the snapshot reports live
  /// on YouTube but without a viewer number (the official feed the CI snapshot
  /// uses frequently omits it). Scrapes the anonymous watch page per live video,
  /// bounded/throttled by `YouTubeConcurrentViewersService`, then merges the
  /// counts back into the shared snapshot so both the Home cards and the player
  /// show the YouTube viewers in the combined total.
  private func enrichYouTubeViewerCounts() async {
    let liveVideos = youtubeLive.presences.values
      .filter { $0.isLive }
      .compactMap { presence -> (channelID: String, videoID: String)? in
        guard let videoID = presence.videoID, !videoID.isEmpty else { return nil }
        return (presence.channelID, videoID)
      }
    guard !liveVideos.isEmpty else { return }

    await youtubeConcurrentViewers.refresh(videoIDs: liveVideos.map(\.videoID))

    var countsByChannelID: [String: Int] = [:]
    for entry in liveVideos {
      if let count = youtubeConcurrentViewers.count(forVideoID: entry.videoID) {
        countsByChannelID[entry.channelID] = count
      }
    }
    youtubeLive.applyConcurrentViewerCounts(countsByChannelID)
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
    .environment(AppEnvironment())
}

// MARK: - Home presentation helpers

/// One multiview session launch — wraps the chosen roster so the cover can be
/// presented with `fullScreenCover(item:)`, which (unlike `isPresented` plus a
/// separate roster var) always builds its content with the channels in hand.
struct MultiviewLaunch: Identifiable {
  let id = UUID()
  let channels: [FollowedChannel]
}

/// A YouTube-only live stream the viewer chose to play (no Twitch equivalent),
/// identified by its live video ID.
struct YouTubePlaybackTarget: Identifiable {
  let id = UUID()
  let videoID: String
  let title: String?
}
