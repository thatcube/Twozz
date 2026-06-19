import SwiftUI

/// Full-screen channel "launchpad". Opened from the player's avatar button and
/// from the press-and-hold "Go to Channel" action on channel cards.
///
/// It pairs a glanceable header (banner, avatar, identity, live summary) with
/// rows of *actionable* content — top clips, past broadcasts, and an algorithmic
/// "More like this" rail — so the page earns its place on a lean-back TV instead
/// of being a dead info card. tvOS has no browser, so social links are plain text.
struct ChannelPageView: View {
  let target: ChannelPageTarget
  /// Watches a live channel — either *this* channel (the live card) or one picked
  /// from the "More like this" rail. The presenter decides what "watch" means
  /// (open the player, or switch the already-open player to that channel).
  var onWatchChannel: ((FollowedChannel) -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette

  @State private var profile: ChannelProfile?
  @State private var isLoadingProfile = true
  @State private var profileFailed = false

  @State private var content: ChannelContent?
  @State private var isLoadingContent = true
  @State private var recommendations: [FollowedChannel] = []
  @State private var isLoadingRecs = true

  @State private var onDemandItem: OnDemandItem?
  @FocusState private var focusedID: String?
  /// Namespace for default-focus anchoring in this page's focus scope.
  @Namespace private var focusNamespace
  @State private var didSetInitialFocus = false

  /// Measured height of the identity hero card, so it can straddle the banner's
  /// bottom edge by exactly 50% regardless of its dynamic content.
  @State private var heroHeight: CGFloat = 0

  private let avatarSize: CGFloat = 96
  private let tileWidth: CGFloat = 360
  private var tileMediaHeight: CGFloat { tileWidth * 9 / 16 }
  // Match the rail-card metrics used across the rest of the app (HomeView).
  private let focusHInset: CGFloat = 18
  private let focusVInset: CGFloat = 18
  private let cardCorner: CGFloat = 30
  private let mediaCorner: CGFloat = 18
  private let heroCorner: CGFloat = 28
  /// Full-bleed banner height. The hero identity card overlaps its bottom edge by
  /// half, and a mirrored, blurred reflection fills the rest of the page below it.
  private let bannerHeight: CGFloat = 380

  private var hasBanner: Bool { profile?.bannerImageURL != nil }

  /// Keep the page non-focusable until its primary async sections are ready.
  /// The freezes happen when the user starts navigating while profile/content
  /// rows are still being inserted and measured. Home/Browse build their rails
  /// from already-set arrays; this gate gives the channel page the same stable
  /// first focus pass.
  private var isPrimaryContentReady: Bool {
    !isLoadingProfile && !isLoadingContent
  }

  /// Which tile should claim focus when the page first settles: the live card if
  /// the channel is live, otherwise the first clip, otherwise the first VOD. Fed
  /// to `.prefersDefaultFocus` per tile; recomputes as content streams in so the
  /// engine anchors focus once the first actionable tile exists.
  private var defaultFocusID: String? {
    if profile?.isLive == true { return "live" }
    if let clip = content?.clips.first { return "clip-\(clip.slug)" }
    if let vod = content?.videos.first { return "vod-\(vod.id)" }
    return nil
  }

  private var headerName: String {
    profile?.displayName ?? target.displayName ?? target.login
  }

  private var headerAvatarURL: URL? {
    profile?.profileImageURL ?? target.profileImageURL
  }

  /// Twitch's anonymous live preview thumbnail for this channel, used by the
  /// interactive live card. Refreshed each presentation via a cache-busting id.
  private var liveThumbnailURL: URL? {
    let login = (profile?.login ?? target.login).lowercased()
    guard !login.isEmpty else { return nil }
    return URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(login)-640x360.jpg")
  }

  var body: some View {
    GeometryReader { geo in
      let safeTop = geo.safeAreaInsets.top
      // Full screen height, including the overscan-safe insets that tvOS adds.
      let fullHeight = geo.size.height + safeTop + geo.safeAreaInsets.bottom

      ZStack(alignment: .top) {
        LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom)
          .ignoresSafeArea()

        // Edge-to-edge banner with a mirrored reflection beneath it, sitting
        // behind the scrolling content and bleeding past the safe area.
        bannerBackdrop(fullHeight: fullHeight)

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 30) {
            if isPrimaryContentReady {
              heroCard
              liveOrLastCard
              clipsRow
              vodsRow
              similarRow
              aboutAndLinks
            } else {
              initialLoadingView
            }
          }
          // Push content down so the identity card straddles the banner's
          // bottom edge by 50%. The banner starts at the true screen top, so we
          // subtract the safe-area inset the ScrollView already applies.
          .padding(.top, hasBanner ? max(bannerHeight - safeTop - heroHeight / 2, 0) : 40)
          .padding(.bottom, 140)
          .focusScope(focusNamespace)
        }
        .scrollClipDisabled()
      }
    }
    .onExitCommand { dismiss() }
    .onChange(of: defaultFocusID) { _, _ in
      applyInitialFocusIfNeeded()
    }
    .task(id: target.id) {
      didSetInitialFocus = false
      focusedID = nil
      await loadAll()
      applyInitialFocusIfNeeded()
    }
    .fullScreenCover(item: $onDemandItem) { item in
      OnDemandPlayerView(item: item, channelLogin: profile?.login ?? target.login)
        .environment(\.themePalette, palette)
    }
  }

  // MARK: - Banner

  /// Edge-to-edge channel banner topped over a vertically-mirrored, blurred
  /// reflection that fills the rest of the screen — like the wash under the
  /// Apple TV home dock. Bleeds past the overscan-safe area on every side and
  /// renders behind the scrolling content. Purely decorative.
  @ViewBuilder
  private func bannerBackdrop(fullHeight: CGFloat) -> some View {
    if let bannerURL = profile?.bannerImageURL {
      VStack(spacing: 0) {
        CachedAsyncImage(url: bannerURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Rectangle().fill(.white.opacity(0.06))
        }
        .frame(height: bannerHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(
          LinearGradient(
            colors: [.clear, .clear, Color.black.opacity(0.28)],
            startPoint: .top,
            endPoint: .bottom
          )
        )

        CachedAsyncImage(url: bannerURL) { image in
          image.resizable()
        } placeholder: {
          Color.clear
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(fullHeight - bannerHeight, 0))
        .scaleEffect(x: 1, y: -1, anchor: .center)
        .blur(radius: 70)
        .clipped()
        // Fade the reflection out toward the bottom with a mask (rather than a
        // dark overlay) so it can blend additively.
        .mask(
          LinearGradient(
            colors: [.white, .white.opacity(0.6), .clear],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .opacity(0.6)
        // Flatten the mirror + 70pt blur + mask + opacity into a single Metal
        // texture that's rasterized when the banner loads, rather than being
        // re-evaluated by the compositor on every dirty region during scroll and
        // focus animations. The additive blend below then runs on the cached
        // texture instead of re-running the blur.
        .drawingGroup()
        // Add the reflection's light to the dark background instead of averaging
        // toward it, so a bright/white banner glows in its own color rather than
        // washing out to gray.
        .blendMode(.plusLighter)
      }
      .frame(maxWidth: .infinity, alignment: .top)
      .ignoresSafeArea()
      .allowsHitTesting(false)
    }
  }

  // MARK: - Hero card (channel identity)

  private var heroCard: some View {
    HStack(alignment: .center, spacing: 22) {
      avatar

      VStack(alignment: .leading, spacing: 12) {
        Text(headerName)
          .font(.system(size: 46, weight: .heavy))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)

        infoChips
      }

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .twizzLiquidGlassCard(
      cornerRadius: heroCorner,
      isFocused: false,
      palette: palette
    )
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
    .padding(.horizontal, AppLayout.horizontalPadding)
  }

  private var initialLoadingView: some View {
    VStack(alignment: .leading, spacing: 14) {
      ProgressView()
      Text("Loading channel…")
        .font(.title3.weight(.semibold))
      Text("Preparing clips and past broadcasts")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .twizzLiquidGlassCard(cornerRadius: heroCorner, isFocused: false, palette: palette)
    .padding(.horizontal, AppLayout.horizontalPadding)
  }

  private var avatar: some View {
    Group {
      if let headerAvatarURL {
        CachedAsyncImage(url: headerAvatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          avatarPlaceholder
        }
      } else {
        avatarPlaceholder
      }
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3))
    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
  }

  private var avatarPlaceholder: some View {
    ZStack {
      Circle().fill(.white.opacity(0.16))
      Icon(glyph: .userCircle, size: avatarSize * 0.6)
        .foregroundStyle(.white.opacity(0.85))
    }
  }

  /// Small, glanceable identity facts under the channel name: partner/affiliate
  /// status, followers, and join date — intentionally understated.
  @ViewBuilder
  private var infoChips: some View {
    if let profile {
      HStack(spacing: 10) {
        if profile.isPartner {
          infoChip("Partner", systemImage: "checkmark.seal.fill", tint: Color(red: 0.58, green: 0.41, blue: 0.96))
        } else if profile.isAffiliate {
          infoChip("Affiliate", systemImage: "rosette", tint: Color(red: 0.30, green: 0.55, blue: 0.95))
        }
        if let followers = profile.followerCount {
          infoChip("\(Self.compactCount(followers)) followers", systemImage: "heart.fill")
        }
        if let joined = profile.createdAt {
          infoChip("Joined \(Self.monthYear(joined))", systemImage: "calendar")
        }
      }
    } else if isLoadingProfile {
      HStack(spacing: 10) {
        ProgressView()
        Text("Loading channel…").font(.callout).foregroundStyle(.secondary)
      }
    } else if profileFailed {
      Text("Couldn't load this channel's details right now.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func infoChip(_ text: String, systemImage: String, tint: Color? = nil) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint ?? .secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Capsule().fill(Color.primary.opacity(0.08)))
  }

  // MARK: - Live / last-broadcast card

  @ViewBuilder
  private var liveOrLastCard: some View {
    if let profile, profile.isLive {
      liveCard(profile)
    } else if let profile, profile.lastBroadcastTitle != nil || profile.lastBroadcastGame != nil {
      lastBroadcastCard(profile)
    }
  }

  /// Full-width, focusable card for a live channel. Selecting it watches the
  /// stream (open the player, or return to it when opened from the player).
  private func liveCard(_ profile: ChannelProfile) -> some View {
    let id = "live"
    return FocusableTile(
      id: id,
      focusedID: $focusedID,
      cornerRadius: heroCorner,
      focusedScale: 1.01,
      prefersDefaultFocus: defaultFocusID == id,
      focusNamespace: focusNamespace,
      onSelect: { onWatchChannel?(followedChannel(from: profile)) }
    ) { isFocused in
      HStack(spacing: 20) {
        liveThumbnail

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            liveBadge
            if let uptime = Self.uptime(since: profile.liveStartedAt) {
              metaDot
              Text("Live for \(uptime)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            if let viewers = profile.liveViewerCount {
              metaDot
              Text("\(Self.plainCount(viewers)) viewers").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
          }

          if let title = profile.liveTitle, !title.isEmpty {
            Text(title)
              .font(.headline)
              .foregroundStyle(.primary)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          if let game = profile.liveGame, !game.isEmpty {
            Label(game, systemImage: "gamecontroller.fill")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "play.circle.fill")
          .font(.system(size: 40))
          .foregroundStyle(.primary.opacity(0.9))
      }
      .padding(18)
      .frame(maxWidth: .infinity)
      .twizzLiquidGlassCard(
        cornerRadius: heroCorner,
        isFocused: isFocused,
        palette: palette
      )
      .shadow(color: .black.opacity(isFocused ? 0.36 : 0), radius: 22, y: 12)
    }
    .padding(.horizontal, AppLayout.horizontalPadding)
  }

  private var liveThumbnail: some View {
    CachedAsyncImage(url: liveThumbnailURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Rectangle().fill(Color.primary.opacity(0.10))
    }
    .frame(width: 248, height: 139.5)
    .clipShape(RoundedRectangle(cornerRadius: 14))
  }

  private func lastBroadcastCard(_ profile: ChannelProfile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(lastSeenLabel(profile.lastBroadcastStartedAt))
        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
      if let title = profile.lastBroadcastTitle, !title.isEmpty {
        Text(title)
          .font(.headline).foregroundStyle(.primary)
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      }
      if let game = profile.lastBroadcastGame, !game.isEmpty {
        Label(game, systemImage: "gamecontroller.fill")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .twizzLiquidGlassCard(
      cornerRadius: heroCorner,
      isFocused: false,
      palette: palette
    )
    .padding(.horizontal, AppLayout.horizontalPadding)
  }

  private var liveBadge: some View {
    HStack(spacing: 8) {
      Circle().fill(.red).frame(width: 11, height: 11)
      Text("LIVE").font(.subheadline.weight(.bold)).foregroundStyle(.red)
    }
  }

  private var metaDot: some View {
    Text("·").font(.subheadline).foregroundStyle(.secondary)
  }

  // MARK: - Clips row

  @ViewBuilder
  private var clipsRow: some View {
    if let clips = content?.clips, !clips.isEmpty {
      contentRow(title: "Clips") {
        ForEach(clips) { clip in
          let itemID = "clip-\(clip.slug)"
          FocusableTile(
            id: itemID,
            focusedID: $focusedID,
            cornerRadius: cardCorner,
            focusedScale: AppLayout.focusedCardScale,
            prefersDefaultFocus: defaultFocusID == itemID,
            focusNamespace: focusNamespace,
            onSelect: { onDemandItem = .clip(slug: clip.slug, title: clip.title) }
          ) { isFocused in
            MediaContentCard(
              title: clip.title,
              subtitle: clipSubtitle(clip),
              thumbnailURL: clip.thumbnailURL,
              durationText: Self.shortDuration(clip.durationSeconds),
              isFocused: isFocused,
              mediaWidth: tileWidth,
              mediaHeight: tileMediaHeight,
              focusHorizontalInset: focusHInset,
              focusVerticalInset: focusVInset,
              cardCornerRadius: cardCorner,
              mediaCornerRadius: mediaCorner
            )
          }
        }
      }
    } else if isLoadingContent {
      loadingRow(title: "Clips")
    }
  }

  private func clipSubtitle(_ clip: ChannelClip) -> String {
    var parts: [String] = ["\(Self.compactCount(clip.viewCount)) views"]
    if let game = clip.gameName { parts.append(game) }
    return parts.joined(separator: " · ")
  }

  // MARK: - VODs row

  @ViewBuilder
  private var vodsRow: some View {
    if let videos = content?.videos, !videos.isEmpty {
      contentRow(title: "Past Broadcasts") {
        ForEach(videos) { vod in
          let itemID = "vod-\(vod.id)"
          FocusableTile(
            id: itemID,
            focusedID: $focusedID,
            cornerRadius: cardCorner,
            focusedScale: AppLayout.focusedCardScale,
            prefersDefaultFocus: defaultFocusID == itemID,
            focusNamespace: focusNamespace,
            onSelect: { onDemandItem = .vod(id: vod.id, title: vod.title) }
          ) { isFocused in
            MediaContentCard(
              title: vod.title,
              subtitle: vodSubtitle(vod),
              thumbnailURL: vod.thumbnailURL,
              durationText: Self.longDuration(vod.lengthSeconds),
              isFocused: isFocused,
              mediaWidth: tileWidth,
              mediaHeight: tileMediaHeight,
              focusHorizontalInset: focusHInset,
              focusVerticalInset: focusVInset,
              cardCornerRadius: cardCorner,
              mediaCornerRadius: mediaCorner
            )
          }
        }
      }
    } else if isLoadingContent {
      loadingRow(title: "Past Broadcasts")
    }
  }

  private func vodSubtitle(_ vod: ChannelVOD) -> String {
    var parts: [String] = []
    if let published = vod.publishedAt { parts.append(Self.relativeDate(published)) }
    parts.append("\(Self.compactCount(vod.viewCount)) views")
    if let game = vod.gameName { parts.append(game) }
    return parts.joined(separator: " · ")
  }

  // MARK: - More like this row

  @ViewBuilder
  private var similarRow: some View {
    if !recommendations.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("More like this")
          .font(.system(size: 26, weight: .bold))
          .padding(.horizontal, AppLayout.horizontalPadding)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 22) {
            ForEach(recommendations) { channel in
              FocusableTile(
                id: "rec-\(channel.id)",
                focusedID: $focusedID,
                cornerRadius: cardCorner,
                focusedScale: AppLayout.focusedCardScale,
                prefersDefaultFocus: false,
                focusNamespace: focusNamespace,
                onSelect: { onWatchChannel?(channel) }
              ) { isFocused in
                StreamChannelCard(
                  channel: channel,
                  isFocused: isFocused,
                  layout: .rail(
                    mediaWidth: tileWidth,
                    mediaHeight: tileMediaHeight,
                    focusHorizontalInset: focusHInset,
                    focusVerticalInset: focusVInset,
                    cardCornerRadius: cardCorner,
                    mediaCornerRadius: mediaCorner
                  ),
                  showsGameName: true
                )
                .accessibilityAddTraits(.isButton)
              }
            }
          }
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 12)
        }
        .scrollClipDisabled()
      }
      .focusSection()
    } else if isLoadingRecs && !isLoadingContent {
      loadingRow(title: "More like this")
    }
  }

  // MARK: - About + links

  @ViewBuilder
  private var aboutAndLinks: some View {
    let description = profile?.description
    let links = profile?.socialLinks ?? []
    if (description?.isEmpty == false) || !links.isEmpty {
      VStack(alignment: .leading, spacing: 18) {
        if let description, !description.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("About").font(.title3.weight(.bold))
            Text(description)
              .font(.title3).foregroundStyle(.secondary)
              .lineLimit(3)
              .frame(maxWidth: 1100, alignment: .leading)
          }
        }
        if !links.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Links").font(.title3.weight(.bold))
            HStack(spacing: 28) {
              ForEach(links.prefix(6)) { link in
                let platform = SocialPlatform.detect(url: link.url, name: link.title)
                HStack(spacing: 12) {
                  Icon(glyph: platform.glyph, size: 30)
                    .foregroundStyle(platform.tint)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).font(.callout.weight(.semibold))
                    Text(Self.prettyURL(link.url))
                      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
              }
            }
          }
        }
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.top, 4)
    }
  }

  // MARK: - Row scaffolding

  @ViewBuilder
  private func contentRow<Content: View>(
    title: String,
    @ViewBuilder _ tiles: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 26, weight: .bold))
        .padding(.horizontal, AppLayout.horizontalPadding)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 22) {
          tiles()
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.vertical, 12)
      }
      .scrollClipDisabled()
    }
    .focusSection()
  }

  private func loadingRow(title: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 26, weight: .bold))
      HStack(spacing: 14) {
        ProgressView()
        Text("Loading…").foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, AppLayout.horizontalPadding)
  }

  // MARK: - Loading

  private func loadAll() async {
    isLoadingProfile = true
    profileFailed = false
    isLoadingContent = true
    isLoadingRecs = true
    profile = nil
    content = nil
    recommendations = []

    async let profileTask = ChannelProfileService.fetch(login: target.login)
    async let contentTask = ChannelContentService.load(login: target.login)

    let (loadedProfile, loadedContent) = await (profileTask, contentTask)
    profile = loadedProfile
    profileFailed = loadedProfile == nil
    content = loadedContent
    isLoadingProfile = false
    isLoadingContent = false
    applyInitialFocusIfNeeded()

    if let signals = loadedContent?.signals {
      // Let the page become interactive before kicking off the heavy multi-seed
      // recommendation pass, so first focus/render isn't competing with scoring.
      await Task.yield()
      recommendations = await SimilarChannelsEngine.recommend(using: signals)
    } else {
      recommendations = []
    }
    isLoadingRecs = false
  }

  private func applyInitialFocusIfNeeded() {
    guard !didSetInitialFocus, focusedID == nil, let defaultFocusID else { return }
    didSetInitialFocus = true
    focusedID = defaultFocusID
  }

  private func followedChannel(from profile: ChannelProfile) -> FollowedChannel {
    FollowedChannel(
      id: profile.login,
      login: profile.login,
      displayName: profile.displayName,
      title: profile.liveTitle ?? "",
      gameName: profile.liveGame ?? "Live",
      viewerCount: profile.liveViewerCount,
      thumbnailURL: nil,
      profileImageURL: profile.profileImageURL,
      isLive: profile.isLive
    )
  }

  // MARK: - Formatting helpers

  /// Formatters are expensive to allocate and these run for every card subtitle
  /// on every redraw, so they're cached once and reused. All access is on the
  /// main actor (SwiftUI view bodies), so sharing single instances is safe.
  private static let decimalFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
  }()
  private static let relativeAbbrevFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()
  private static let relativeFullFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()
  private static let monthYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM yyyy"
    return f
  }()

  private func lastSeenLabel(_ date: Date?) -> String {
    guard let date else { return "Offline" }
    return "Last live \(Self.relativeFullFormatter.localizedString(for: date, relativeTo: Date()))"
  }

  static func relativeDate(_ date: Date) -> String {
    relativeAbbrevFormatter.localizedString(for: date, relativeTo: Date())
  }

  static func shortDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
  }

  static func longDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }

  static func compactCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: return trimmed(Double(value) / 1_000_000) + "M"
    case 1_000...: return trimmed(Double(value) / 1_000) + "K"
    default: return decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
  }

  static func plainCount(_ value: Int) -> String {
    decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  private static func trimmed(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(rounded)) }
    return String(format: "%.1f", rounded)
  }

  static func monthYear(_ date: Date) -> String {
    monthYearFormatter.string(from: date)
  }

  static func uptime(since start: Date?) -> String? {
    guard let start else { return nil }
    let seconds = max(0, Date().timeIntervalSince(start))
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }

  static func prettyURL(_ url: String) -> String {
    var result = url
    for prefix in ["https://", "http://", "www."] where result.hasPrefix(prefix) {
      result = String(result.dropFirst(prefix.count))
    }
    if result.hasSuffix("/") { result = String(result.dropLast()) }
    return result
  }
}

/// Focusable wrapper that uses a single page-level focus binding, matching the
/// rest of the app's stable tvOS focus pattern.
private struct FocusableTile<Content: View>: View {
  let id: String
  @FocusState.Binding var focusedID: String?
  let cornerRadius: CGFloat
  let focusedScale: CGFloat
  let prefersDefaultFocus: Bool
  let focusNamespace: Namespace.ID
  let onSelect: () -> Void
  @ViewBuilder let content: (Bool) -> Content

  private var isFocused: Bool { focusedID == id }

  var body: some View {
    content(isFocused)
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
      .focusable(true)
      .focused($focusedID, equals: id)
      .prefersDefaultFocus(prefersDefaultFocus, in: focusNamespace)
      .focusEffectDisabled()
      .onTapGesture(perform: onSelect)
      .scaleEffect(isFocused ? focusedScale : 1)
      .animation(AppLayout.focusScaleAnimation, value: isFocused)
      .zIndex(isFocused ? 2 : 0)
  }
}
