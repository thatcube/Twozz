import SwiftUI

struct HomeView: View {
  private let pagePadding: CGFloat = 44
  private let channelRailVerticalPadding: CGFloat = 16
  private let channelRailSpacing: CGFloat = 42
  private let focusedCardScale: CGFloat = 1.015

  @State private var selectedTopTab: TopTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var selectedChannel: FollowedChannel?
  @State private var firstFocusRequested = false

  @FocusState private var focusedChannelID: String?

  private enum TopTab: String, CaseIterable, Identifiable {
    case home = "Home"

    var id: String { rawValue }
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
      PlayerView(channel: channel.login)
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
    }
  }

  private var homeTab: some View {
    VStack(alignment: .leading, spacing: 24) {
      authBanner

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
        HStack(spacing: channelRailSpacing) {
          ForEach(follows.channels) { channel in
            let isFocused = focusedChannelID == channel.id

            FollowedChannelCard(channel: channel, isFocused: isFocused)
              .contentShape(RoundedRectangle(cornerRadius: 18))
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
    }
  }

  private var authBanner: some View {
    VStack(alignment: .leading, spacing: 10) {
      if auth.isAuthenticated {
        HStack {
          Text("Signed in as \(auth.userDisplayName ?? auth.userLogin ?? "Twitch user")")
            .font(.headline)
          Spacer()
          Button("Sign Out") {
            auth.signOut()
            Task {
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
          }
        }
      } else {
        HStack(spacing: 14) {
          Button(auth.isAuthenticating ? "Authenticating..." : "Sign In With Twitch") {
            Task {
              await auth.beginDeviceCodeSignIn()
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
          }
          .disabled(auth.isAuthenticating)

          if auth.isAuthenticating {
            Button("Cancel") {
              auth.cancelSignIn()
            }
          }
        }

        if let code = auth.activationCode, let verification = auth.verificationURI {
          Text("Go to \(verification) and enter code \(code)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let message = auth.statusMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let errorMessage = auth.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        if follows.isUsingDemoData {
          Text("Showing trending channels until you sign in with Twitch.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
        .frame(width: 560, height: 315)
        .clipShape(RoundedRectangle(cornerRadius: 18))

        LinearGradient(
          colors: [Color.clear, Color.black.opacity(0.82)],
          startPoint: .top,
          endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))

        HStack(spacing: 8) {
          Circle()
            .fill(channel.isLive ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
          Text(channel.isLive ? "LIVE" : "OFFLINE")
            .font(.caption.weight(.bold))
            .foregroundStyle(channel.isLive ? Color.white : Color.white.opacity(0.72))
          if let viewerCount = channel.viewerCount {
            Text("\(viewerCount) watching")
              .font(.caption)
              .foregroundStyle(Color.white.opacity(0.78))
          }
        }
        .padding(12)
      }

      Text(channel.displayName)
        .font(.headline)
        .lineLimit(1)

      Text(channel.title.isEmpty ? "No title" : channel.title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Text(channel.gameName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(width: 560, alignment: .leading)
    .shadow(color: Color.white.opacity(isFocused ? 0.16 : 0), radius: 14, y: 8)
  }
}

#Preview {
  HomeView()
}
