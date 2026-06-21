import SwiftUI

/// Preferences group: appearance (theme), stream card size, open-chat default,
/// stream language, recommendations, go-live alerts, and reduce transparency.
struct SettingsPreferencesSection: View {
  var onClearWatchHistory: () -> Void = {}
  var onResetNotInterested: () -> Void = {}

  @Environment(AppEnvironment.self) private var environment
  private var themeManager: ThemeManager { environment.themeManager }
  private var auth: TwitchAuthSession { environment.auth }
  private var follows: FollowedChannelsService { environment.follows }
  private var goLiveSettings: GoLiveNotificationSettings { environment.goLiveSettings }
  private var recommendationFeedback: RecommendationFeedbackService { environment.feedback }

  @State private var showClearHistoryConfirm = false
  @State private var showResetNotInterestedConfirm = false
  @FocusState private var focusedTheme: AppTheme?
  @FocusState private var focusedCardSize: StreamCardSize?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage(PersistenceKey.showChatByDefault) private var showChatByDefault = true
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedRecommendationsEnabled = true
  @AppStorage(StreamLanguagePreference.storageKey) private var streamLanguage = StreamLanguagePreference.deviceDefault()
  @AppStorage(GoLiveNotificationPreferences.enabledKey) private var goLiveAlertsEnabled = true
  @AppStorage(PersistenceKey.preferYouTubeSource) private var preferYouTubeSource = true
  @AppStorage(PersistenceKey.disableLiquidGlass) private var disableLiquidGlass = false

  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    VStack(spacing: 0) {
      appearanceRow
        .padding(.vertical, 16)

      groupDivider

      streamCardRow
        .padding(.vertical, 16)

      groupDivider

      chatRow
        .padding(.vertical, 16)

      groupDivider

      languageRow
        .padding(.vertical, 16)

      groupDivider

      recommendationsRow
        .padding(.vertical, 16)

      groupDivider

      goLiveAlertsRow
        .padding(.vertical, 16)

      groupDivider

      preferYouTubeSourceRow
        .padding(.vertical, 16)

      groupDivider

      reduceTransparencyRow
        .padding(.vertical, 16)
    }
    .padding(.horizontal, 28)
    .settingsGlassPanel(disabled: glassDisabled)
  }

  private var groupDivider: some View {
    Divider()
      .overlay(Color.primary.opacity(0.12))
  }

  private var appearanceRow: some View {
    SettingRow(
      title: "Appearance",
      subtitle: nil
    ) {
      ForEach(AppTheme.allCases) { theme in
        Button {
          themeManager.theme = theme
        } label: {
          SettingPill(title: theme.displayName, isSelected: themeManager.theme == theme)
        }
        .settingPillStyle(isSelected: themeManager.theme == theme)
        .focused($focusedTheme, equals: theme)
      }
    }
  }

  private var streamCardRow: some View {
    SettingRow(
      title: "Stream card size",
      subtitle: nil
    ) {
      ForEach(StreamCardSize.allCases) { size in
        Button {
          streamCardSizeRaw = size.rawValue
        } label: {
          SettingPill(
            title: size.title,
            subtitle: size.subtitle,
            isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size
          )
        }
        .settingPillStyle(isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size)
        .focused($focusedCardSize, equals: size)
      }
    }
  }

  private var chatRow: some View {
    SettingRow(
      title: "Open chat by default",
      subtitle: nil
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          showChatByDefault = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: showChatByDefault == on)
        }
        .settingPillStyle(isSelected: showChatByDefault == on)
      }
    }
  }

  private var languageRow: some View {
    SettingRow(
      title: "Stream Language",
      subtitle: "Only show streams in this language."
    ) {
      Menu {
        Picker("Stream Language", selection: $streamLanguage) {
          ForEach(StreamLanguagePreference.options, id: \.value) { option in
            Text(option.name).tag(option.value)
          }
        }
        .pickerStyle(.inline)
      } label: {
        SettingPill(title: StreamLanguagePreference.displayName(streamLanguage), isSelected: false, showsMenuIndicator: true)
      }
      .settingsProminentActionButtonStyle()
    }
  }

  private var recommendationsRow: some View {
    SettingRow(
      title: "Recommendations",
      subtitle: "Based on who you follow and watch. History stays on this Apple TV."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          personalizedRecommendationsEnabled = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: personalizedRecommendationsEnabled == on)
        }
        .settingPillStyle(isSelected: personalizedRecommendationsEnabled == on)
      }

      Button {
        showClearHistoryConfirm = true
      } label: {
        SettingPill(title: "Clear History", isSelected: false)
      }
      .settingPillStyle(isSelected: false)

      if recommendationFeedback.hasFeedback {
        Button {
          showResetNotInterestedConfirm = true
        } label: {
          SettingPill(title: "Reset Not Interested", isSelected: false)
        }
        .settingPillStyle(isSelected: false)
      }
    }
    .confirmationDialog(
      "Clear watch history?",
      isPresented: $showClearHistoryConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) {
        onClearWatchHistory()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes the watch history stored on this device.")
    }
    .confirmationDialog(
      "Reset “Not Interested”?",
      isPresented: $showResetNotInterestedConfirm,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) {
        onResetNotInterested()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Channels you marked “Not interested” can be recommended again.")
    }
  }

  private var goLiveAlertsRow: some View {
    SettingRow(
      title: "Go Live Alerts",
      subtitle: "In-app pop-up on this Apple TV when a channel you follow goes live. Doesn't change Twitch notifications on your other devices."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          goLiveAlertsEnabled = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: goLiveAlertsEnabled == on)
        }
        .settingPillStyle(isSelected: goLiveAlertsEnabled == on)
      }

      NavigationLink {
        GoLiveAlertsSettingsView(follows: follows, settings: goLiveSettings, auth: auth)
      } label: {
        SettingPill(title: "Choose Channels", isSelected: false)
      }
      .settingPillStyle(isSelected: false)
      .disabled(!goLiveAlertsEnabled)
      .opacity(goLiveAlertsEnabled ? 1 : 0.4)
    }
  }

  /// When a creator is simulcasting live on YouTube, default playback to the
  /// YouTube source (generally lower latency than the proxied Twitch path).
  /// Off leaves Twitch as the default; either way the in-player Stream Source
  /// picker still lets the viewer switch per stream.
  private var preferYouTubeSourceRow: some View {
    SettingRow(
      title: "Prefer YouTube source",
      subtitle: "When a channel is live on YouTube too, start on YouTube for lower latency. You can still switch sources while watching."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          preferYouTubeSource = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: preferYouTubeSource == on)
        }
        .settingPillStyle(isSelected: preferYouTubeSource == on)
      }
    }
  }

  /// Reduce Transparency toggle: swaps translucent Liquid Glass surfaces for
  /// opaque, high-contrast fills app-wide. The OS "Reduce Transparency"
  /// accessibility setting forces this on regardless of the in-app choice.
  private var reduceTransparencyRow: some View {
    SettingRow(
      title: "Reduce Transparency",
      subtitle: reduceTransparency
        ? "Translucent panels are replaced with solid, high-contrast fills. Forced on by the system Reduce Transparency setting."
        : "Replace translucent Liquid Glass panels with solid, high-contrast fills for better legibility."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          disableLiquidGlass = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: disableLiquidGlass == on)
        }
        .settingPillStyle(isSelected: disableLiquidGlass == on)
        .disabled(reduceTransparency)
        .opacity(reduceTransparency ? 0.4 : 1)
      }
    }
  }
}
