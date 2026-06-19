import SwiftUI

/// Settings sub-page: choose which followed channels surface the in-app
/// "just went live" toast.
///
/// Opt-out model — every followed channel alerts by default, and the viewer
/// toggles off the ones they don't want. tvOS has no system notifications, so
/// these alerts are *in-app on this Apple TV* only and don't change the viewer's
/// Twitch notifications on other devices (explained on the parent Settings row).
///
/// This is a second-level detail page, so it hides the top tab bar and presents
/// as a focused full-screen list. The master Go Live Alerts on/off lives on the
/// parent Settings row, not here — this page is just the per-channel picker.
struct GoLiveAlertsSettingsView: View {
  var follows: FollowedChannelsService
  let settings: GoLiveNotificationSettings
  let auth: TwitchAuthSession

  @Environment(\.themePalette) private var palette
  @State private var searchText = ""

  /// The full follow list (live + offline) from the shared Following directory,
  /// sorted by name so the picker is easy to scan. Reuses `loadDirectory` rather
  /// than fetching the follow list a second time.
  private var broadcasters: [FollowedChannel] {
    follows.directory.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  /// `broadcasters` narrowed by the search field — matches display name or login,
  /// case-insensitively — so ~100 follows stay findable.
  private var filteredBroadcasters: [FollowedChannel] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return broadcasters }
    return broadcasters.filter {
      $0.displayName.localizedCaseInsensitiveContains(query)
        || $0.login.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      List {
        bulkActionsSection
        channelsSection
      }
    }
    .navigationTitle("Go Live Alerts")
    .toolbar(.hidden, for: .tabBar)
    .searchable(
      text: $searchText,
      placement: .automatic,
      prompt: "Search channels"
    )
    .task { await follows.loadDirectory(using: auth) }
  }

  /// Whether a search query is currently narrowing the list.
  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Channels a bulk action affects: the visible (filtered) rows. With no search
  /// this is every follow; while searching it's just the matches, so the viewer
  /// can "find a group, toggle them."
  private var bulkTargets: [FollowedChannel] {
    filteredBroadcasters
  }

  /// Top-of-list "Enable All" / "Disable All" controls. Map onto the existing
  /// opt-out muted set: Disable All mutes every visible channel, Enable All
  /// unmutes them. Scope follows the search field (see `bulkTargets`).
  @ViewBuilder
  private var bulkActionsSection: some View {
    if !bulkTargets.isEmpty {
      Section {
        HStack(spacing: 24) {
          Button {
            settings.setAlerting(true, logins: bulkTargets.map(\.login))
          } label: {
            Text("Enable All")
              .frame(maxWidth: .infinity)
          }
          Button {
            settings.setAlerting(false, logins: bulkTargets.map(\.login))
          } label: {
            Text("Disable All")
              .frame(maxWidth: .infinity)
          }
        }
        .frame(maxWidth: .infinity)
      } footer: {
        Text(bulkScopeDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Footer copy clarifying what the bulk buttons act on, including the future-
  /// follow caveat of the opt-out model.
  private var bulkScopeDescription: String {
    if isSearching {
      let count = bulkTargets.count
      return "Enable All / Disable All apply to the \(count) channel\(count == 1 ? "" : "s") matching your search."
    }
    return "Enable All / Disable All apply to every channel you follow now. Channels you follow later start on."
  }

  @ViewBuilder
  private var channelsSection: some View {
    Section {
      if broadcasters.isEmpty {
        if follows.isLoadingDirectory {
          loadingState
        } else {
          emptyState
        }
      } else if filteredBroadcasters.isEmpty {
        noMatchesState
      } else {
        ForEach(filteredBroadcasters) { channel in
          Toggle(isOn: binding(for: channel)) {
            channelLabel(channel)
          }
        }
      }
    } header: {
      Text("Channels")
    } footer: {
      if !broadcasters.isEmpty {
        Text("Channels left on will alert you when they go live.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func channelLabel(_ channel: FollowedChannel) -> some View {
    HStack(spacing: 16) {
      avatar(for: channel)
      VStack(alignment: .leading, spacing: 2) {
        Text(channel.displayName)
          .font(.headline)
          .lineLimit(1)
        if channel.login.caseInsensitiveCompare(channel.displayName) != .orderedSame {
          Text("@\(channel.login)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func avatar(for channel: FollowedChannel) -> some View {
    CachedAsyncImage(url: channel.profileImageURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Circle().fill(.ultraThinMaterial)
        Icon(glyph: .userCircle, size: 30)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 56, height: 56)
    .clipShape(Circle())
  }

  private var loadingState: some View {
    HStack(spacing: 16) {
      ProgressView()
      Text("Loading your follows…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    HStack(spacing: 16) {
      Icon(glyph: .userCircle, size: 30)
        .foregroundStyle(.secondary)
      Text("No followed channels yet. Sign in and follow channels to choose which ones alert you.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 8)
  }

  private var noMatchesState: some View {
    Text("No channels match “\(searchText)”.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.vertical, 8)
  }

  /// Per-channel switch. Reading `settings.isMuted` registers an observation so
  /// the row reflects changes; writing goes through the store, which persists.
  private func binding(for channel: FollowedChannel) -> Binding<Bool> {
    Binding(
      get: { !settings.isMuted(login: channel.login) },
      set: { settings.setAlerting($0, login: channel.login) }
    )
  }
}
