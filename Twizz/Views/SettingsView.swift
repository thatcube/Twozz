import SwiftUI

/// Settings tab: appearance (theme) controls plus account sign-in / sign-out.
///
/// Laid out as a tvOS-native grouped "form": each preference is a single
/// horizontal row — a left-aligned label/description with its choices rendered
/// as compact, focusable pills on the right. This keeps the whole screen
/// dense enough that every section (including Account) is visible at once.
///
/// The screen is split into focused section views that live in
/// `Twizz/Views/Settings/`; this type wires them together and forwards the
/// host callbacks. Each section reads the services it needs from the app-level
/// `AppEnvironment` injected into the environment.
struct SettingsView: View {
  var onRequestSignIn: () -> Void = {}
  var onRequestYouTubeSignIn: () -> Void = {}
  var onClearWatchHistory: () -> Void = {}
  var onResetNotInterested: () -> Void = {}
  var onAccountChanged: () -> Void = {}
  var onRepublishTopShelf: () -> Void = {}

  @Environment(\.themePalette) private var palette

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(
          colors: palette.backgroundColors,
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 28) {
            Text("Settings")
              .font(.system(size: 38, weight: .bold))
              .accessibilityAddTraits(.isHeader)

            SettingsPreferencesSection(
              onClearWatchHistory: onClearWatchHistory,
              onResetNotInterested: onResetNotInterested
            )
            SettingsAccountSection(
              onRequestSignIn: onRequestSignIn,
              onAccountChanged: onAccountChanged
            )
            SettingsYouTubeAccountSection(
              onRequestYouTubeSignIn: onRequestYouTubeSignIn,
              onAccountChanged: onAccountChanged
            )
            SettingsTopShelfSection(
              onRepublishTopShelf: onRepublishTopShelf
            )
            SettingsAboutSection()
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 32)
        }
        .scrollClipDisabled()
      }
    }
  }
}
