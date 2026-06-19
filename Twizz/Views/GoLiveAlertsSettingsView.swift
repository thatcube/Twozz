import SwiftUI

/// Settings sub-page: choose which followed channels surface the in-app
/// "just went live" toast.
///
/// Opt-out model — every followed channel alerts by default, and the viewer
/// toggles off the ones they don't want. tvOS has no system notifications, so
/// the explanatory copy makes clear these alerts are *in-app on this Apple TV*
/// only and don't change the viewer's Twitch notifications on other devices.
struct GoLiveAlertsSettingsView: View {
  var follows: FollowedChannelsService
  let settings: GoLiveNotificationSettings

  @Environment(\.themePalette) private var palette
  @AppStorage(GoLiveNotificationPreferences.enabledKey) private var alertsEnabled = true

  private var broadcasters: [FollowedBroadcasterSummary] { follows.followedBroadcasters }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      List {
        masterSection
        channelsSection
      }
    }
    .navigationTitle("Go Live Alerts")
  }

  private var masterSection: some View {
    Section {
      Toggle(isOn: $alertsEnabled) {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("Go Live Alerts")
              .font(.headline)
            Text("Show an in-app pop-up when a followed channel goes live.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Icon(glyph: .broadcast, size: 30)
        }
      }
    } footer: {
      Text("These alerts appear only in Twizz on this Apple TV. They don't change your Twitch notifications on your phone or computer.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var channelsSection: some View {
    Section {
      if broadcasters.isEmpty {
        emptyState
      } else {
        ForEach(broadcasters) { channel in
          Toggle(isOn: binding(for: channel)) {
            Text(channel.displayName)
              .font(.headline)
              .lineLimit(1)
          }
          .disabled(!alertsEnabled)
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
    .opacity(alertsEnabled ? 1 : 0.4)
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

  /// Per-channel switch. Reading `settings.isMuted` registers an observation so
  /// the row reflects changes; writing goes through the store, which persists.
  private func binding(for channel: FollowedBroadcasterSummary) -> Binding<Bool> {
    Binding(
      get: { !settings.isMuted(login: channel.login) },
      set: { settings.setAlerting($0, login: channel.login) }
    )
  }
}
