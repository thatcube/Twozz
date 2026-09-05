import SwiftUI

/// Global settings use a persistent category rail so the viewer sees one
/// coherent group at a time instead of a single wall of unrelated controls.
struct SettingsView: View {
  var onRequestSignIn: () -> Void = {}
  var onRequestYouTubeSignIn: () -> Void = {}
  var onClearWatchHistory: () -> Void = {}
  var onResetNotInterested: () -> Void = {}
  var onAccountChanged: () -> Void = {}
  var onRepublishTopShelf: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var selectedPane = SettingsPane.theme

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(
          colors: palette.backgroundColors,
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        GeometryReader { proxy in
          HStack(alignment: .top, spacing: 0) {
            SettingsPaneRail(selection: $selectedPane)
              .frame(width: min(600, max(500, proxy.size.width * 0.33)))

            Divider()
              .overlay(Color.primary.opacity(0.12))
              .padding(.horizontal, 32)

            SettingsPaneDetail(
              pane: selectedPane,
              onRequestSignIn: onRequestSignIn,
              onRequestYouTubeSignIn: onRequestYouTubeSignIn,
              onClearWatchHistory: onClearWatchHistory,
              onResetNotInterested: onResetNotInterested,
              onAccountChanged: onAccountChanged
            )
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 32)
        }
      }
    }
  }
}

private enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
  case theme
  case cards
  case nightShift
  case streamLanguage
  case recommendations
  case watching
  case goLiveAlerts
  case accounts
  case about

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .theme: "Theme"
    case .cards: "Cards"
    case .nightShift: "Circadian Mode"
    case .streamLanguage: "Stream Language"
    case .recommendations: "Recommendations"
    case .watching: "Watching"
    case .goLiveAlerts: "Go Live Alerts"
    case .accounts: "Accounts"
    case .about: "About"
    }
  }

  var description: LocalizedStringResource? {
    switch self {
    case .theme:
      "Choose the app theme and how translucent surfaces are rendered."
    case .cards:
      "Control how stream cards are sized and presented."
    case .nightShift:
      "Warms and dims the display at night to help you sleep."
    case .streamLanguage:
      "Only show live streams in the language you choose."
    case .recommendations:
      "Personalize Home using follows and watch history stored on this Apple TV."
    case .watching:
      "Choose the defaults used when a stream starts."
    case .goLiveAlerts:
      "Choose when Twozz alerts you that a followed channel is live."
    case .accounts:
      "Manage your Twitch and YouTube connections."
    case .about:
      nil
    }
  }
}

private struct SettingsPaneRail: View {
  @Binding var selection: SettingsPane
  @FocusState private var focusedPane: SettingsPane?
  @Namespace private var focusScope

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Settings")
        .font(.title2.weight(.bold))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 6) {
          ForEach(SettingsPane.allCases) { pane in
            Button {
              selection = pane
            } label: {
              Text(pane.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPaneButtonStyle(isSelected: selection == pane))
            .focused($focusedPane, equals: pane)
            .focusEffectDisabled()
            .prefersDefaultFocus(pane == selection, in: focusScope)
            .accessibilityAddTraits(selection == pane ? .isSelected : [])
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
      }
      .scrollClipDisabled()
      .focusScope(focusScope)
    }
    .onChange(of: focusedPane) { _, pane in
      guard let pane else { return }
      selection = pane
    }
  }
}

private struct SettingsPaneButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    SettingsPaneButtonBody(configuration: configuration, isSelected: isSelected)
  }
}

private struct SettingsPaneButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let isSelected: Bool

  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme

  private var focusFill: Color {
    colorScheme == .dark ? .white : .black
  }

  private var focusForeground: Color {
    colorScheme == .dark ? .black : .white
  }

  var body: some View {
    configuration.label
      .foregroundStyle(isFocused ? focusForeground : Color.primary)
      .background {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(
            isFocused
              ? focusFill
              : Color.accentColor.opacity(isSelected ? 0.16 : 0)
          )
          .padding(.horizontal, isFocused ? -12 : 0)
          .padding(.vertical, isFocused ? -4 : 0)
          .shadow(
            color: .black.opacity(isFocused ? 0.28 : 0),
            radius: isFocused ? 14 : 0,
            y: isFocused ? 6 : 0
          )
      }
      .overlay(alignment: .leading) {
        if isSelected && !isFocused {
          Capsule(style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 4, height: 26)
        }
      }
      .opacity(configuration.isPressed ? 0.86 : 1)
  }
}

private struct SettingsPaneDetail: View {
  let pane: SettingsPane
  let onRequestSignIn: () -> Void
  let onRequestYouTubeSignIn: () -> Void
  let onClearWatchHistory: () -> Void
  let onResetNotInterested: () -> Void
  let onAccountChanged: () -> Void

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 38) {
        VStack(alignment: .leading, spacing: 10) {
          Text(pane.title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)

          if let description = pane.description {
            Text(description)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        switch pane {
        case .theme:
          SettingsPreferencesSection(
            group: .theme
          )
        case .cards:
          SettingsPreferencesSection(group: .cards)
        case .nightShift:
          SettingsNightShiftSection()
        case .streamLanguage:
          SettingsPreferencesSection(
            group: .streamLanguage
          )
        case .recommendations:
          SettingsPreferencesSection(
            group: .recommendations,
            onClearWatchHistory: onClearWatchHistory,
            onResetNotInterested: onResetNotInterested
          )
        case .watching:
          SettingsPreferencesSection(group: .watching)
        case .goLiveAlerts:
          SettingsPreferencesSection(group: .alerts)
        case .accounts:
          SettingsAccountSection(
            onRequestSignIn: onRequestSignIn,
            onAccountChanged: onAccountChanged
          )
          SettingsYouTubeAccountSection(
            onRequestYouTubeSignIn: onRequestYouTubeSignIn,
            onAccountChanged: onAccountChanged
          )
        case .about:
          SettingsAboutSection(showsTitle: false)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.top, 8)
      .padding(.horizontal, 20)
      .padding(.bottom, 48)
    }
    .id(pane)
    .scrollClipDisabled()
  }
}
