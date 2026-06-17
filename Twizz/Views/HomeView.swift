import SwiftUI

struct HomeView: View {
  private let pagePadding: CGFloat = 28
  private let channelRailVerticalPadding: CGFloat = 20
  private let targetVisibleCards: CGFloat = 4
  private let peekCardFraction: CGFloat = 0.15
  private let focusHorizontalInset: CGFloat = 18
  private let focusVerticalInset: CGFloat = 18
  private let cardCornerRadius: CGFloat = 22
  private let mediaCornerRadius: CGFloat = 18
  private let minMediaWidth: CGFloat = 220
  private let maxMediaWidth: CGFloat = 560
  private let focusedCardScale: CGFloat = 1.07

  @State private var selectedTopTab: TopTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var selectedChannel: FollowedChannel?
  @State private var firstFocusRequested = false
  @State private var showAccount = false

  @FocusState private var focusedChannelID: String?

  private enum TopTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case browse = "Browse"

    var id: String { rawValue }
  }

  private struct ChannelRailMetrics {
    let spacing: CGFloat
    let mediaWidth: CGFloat
    let mediaHeight: CGFloat
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black, Color(red: 0.09, green: 0.08, blue: 0.14)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 30) {
        topTabs

        if selectedTopTab == .home {
          homeTab
        } else if selectedTopTab == .browse {
          BrowseView(
            auth: auth,
            selectedChannel: $selectedChannel
          )
        }
      }
      .padding(pagePadding)
    }
    .task {
      auth.restore()
      await follows.refresh(using: auth)
      requestFocusIfPossible(force: true)
    }
    .onChange(of: follows.channels) { _, _ in
      requestFocusIfPossible(force: false)
    }
    .onChange(of: auth.isAuthenticated) { _, _ in
      Task {
        await follows.refresh(using: auth)
        requestFocusIfPossible(force: true)
      }
    }
    .fullScreenCover(item: $selectedChannel) { channel in
      PlayerView(channel: channel.login, auth: auth)
    }
    .fullScreenCover(isPresented: $showAccount) {
      SignInView(auth: auth) {
        Task {
          await follows.refresh(using: auth)
          requestFocusIfPossible(force: true)
        }
      }
    }
  }

  private var topTabs: some View {
    HStack(spacing: 16) {
      ForEach(TopTab.allCases) { tab in
        Button {
          selectedTopTab = tab
        } label: {
          Text(tab.rawValue)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 14)
                .fill(selectedTopTab == tab ? Color.white.opacity(0.2) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
      }

      Spacer()

      profileButton
    }
  }

  private var profileButton: some View {
    Button {
      showAccount = true
    } label: {
      Group {
        if auth.isAuthenticated, let imageURL = auth.profileImageURL {
          AsyncImage(url: imageURL) { image in
            image
              .resizable()
              .scaledToFill()
          } placeholder: {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
              .foregroundStyle(.secondary)
          }
        } else {
          Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
        }
      }
      .frame(width: 56, height: 56)
      .clipShape(Circle())
      .overlay(
        Circle()
          .stroke(Color.white.opacity(0.25), lineWidth: 2)
      )
      .padding(8)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(auth.isAuthenticated ? "Account" : "Sign in")
  }

  private var homeTab: some View {
    GeometryReader { proxy in
      let rail = channelRailMetrics(for: proxy.size.width)

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
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
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
              let isFocused = focusedChannelID == channel.id

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
              .focused($focusedChannelID, equals: channel.id)
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

        Spacer(minLength: 0)

        authBanner
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
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
          showAccount = true
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
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      )
      .padding(.top, 12)
      .focusSection()
    }
  }

  private func requestFocusIfPossible(force: Bool) {
    guard let first = follows.channels.first else { return }
    if !force && firstFocusRequested { return }

    firstFocusRequested = true
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      await MainActor.run {
        focusedChannelID = first.id
      }
    }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottomLeading) {
        AsyncImage(url: channel.thumbnailURL) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          Color.white.opacity(0.08)
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
        .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.primary)
        .lineLimit(1)

      Text(channel.title.isEmpty ? "No title" : channel.title)
        .font(.footnote)
        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.secondary)
        .lineLimit(2)
        .frame(height: 38, alignment: .topLeading)

      Text(channel.gameName)
        .font(.caption2)
        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, focusHorizontalInset)
    .padding(.vertical, focusVerticalInset)
    .frame(width: mediaWidth + (focusHorizontalInset * 2), alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: cardCornerRadius)
        .fill(isFocused ? Color.white.opacity(0.94) : Color.clear)
    }
    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
    .shadow(color: Color.black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
  }
}

#Preview {
  HomeView()
}
