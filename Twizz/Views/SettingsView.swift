import SwiftUI

/// Settings tab: appearance (theme) controls plus account sign-in / sign-out.
///
/// Laid out as a tvOS-native grouped "form": each preference is a single
/// horizontal row — a left-aligned label/description with its choices rendered
/// as compact, focusable pills on the right. This keeps the whole screen
/// dense enough that every section (including Account) is visible at once.
struct SettingsView: View {
  @Bindable var themeManager: ThemeManager
  let auth: TwitchAuthSession
  var onRequestSignIn: () -> Void = {}
  var onAccountChanged: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false
  @FocusState private var focusedTheme: AppTheme?
  @FocusState private var focusedCardSize: StreamCardSize?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue

  private let labelColumnWidth: CGFloat = 360

  var body: some View {
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

          preferencesGroup
          accountSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.vertical, 32)
      }
      .scrollClipDisabled()
    }
  }

  // MARK: - Preferences group (Appearance + Stream Cards)

  private var preferencesGroup: some View {
    VStack(spacing: 0) {
      appearanceRow
        .padding(.vertical, 20)

      Divider()
        .overlay(Color.primary.opacity(0.12))

      streamCardRow
        .padding(.vertical, 20)
    }
    .padding(.horizontal, 28)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Color.primary.opacity(0.05))
    )
  }

  private var appearanceRow: some View {
    settingRow(
      title: "Appearance",
      subtitle: "Theme used throughout the app."
    ) {
      ForEach(AppTheme.allCases) { theme in
        Button {
          themeManager.theme = theme
        } label: {
          SettingPill(
            systemImage: theme.symbolName,
            title: theme.displayName,
            isSelected: themeManager.theme == theme
          )
        }
        .buttonStyle(.card)
        .focused($focusedTheme, equals: theme)
      }
    }
    .defaultFocus($focusedTheme, AppTheme.system)
  }

  private var streamCardRow: some View {
    settingRow(
      title: "Stream Cards",
      subtitle: "How large stream cards appear on Home and Browse."
    ) {
      ForEach(StreamCardSize.allCases) { size in
        Button {
          streamCardSizeRaw = size.rawValue
        } label: {
          SettingPill(
            systemImage: size.symbolName,
            title: size.title,
            subtitle: size.subtitle,
            isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size
          )
        }
        .buttonStyle(.card)
        .focused($focusedCardSize, equals: size)
      }
    }
  }

  /// A single preference row: fixed-width label column on the left, a
  /// horizontal run of selectable pills on the right.
  private func settingRow<Content: View>(
    title: String,
    subtitle: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 32) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title3.weight(.semibold))
        if let subtitle {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(width: labelColumnWidth, alignment: .leading)

      HStack(spacing: 16) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
  }

  // MARK: - Account

  private var accountSection: some View {
    Group {
      if auth.isAuthenticated {
        HStack(spacing: 20) {
          AsyncImage(url: auth.profileImageURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
              .foregroundStyle(.secondary)
          }
          .frame(width: 64, height: 64)
          .clipShape(Circle())

          VStack(alignment: .leading, spacing: 4) {
            Text(auth.userDisplayName ?? auth.userLogin ?? "Twitch user")
              .font(.title3.weight(.semibold))
            Text("Signed in")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 24)

          Button("Sign Out", role: .destructive) {
            showSignOutConfirm = true
          }
          .font(.headline)
          .buttonStyle(.borderedProminent)
          .tint(.red)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.primary.opacity(0.05))
        )
        .focusSection()
        .confirmationDialog(
          "Sign out of Twitch?",
          isPresented: $showSignOutConfirm,
          titleVisibility: .visible
        ) {
          Button("Sign Out", role: .destructive) {
            auth.signOut()
            onAccountChanged()
          }
          Button("Cancel", role: .cancel) {}
        }
      } else {
        HStack(spacing: 24) {
          Image(systemName: "person.crop.circle.badge.plus")
            .font(.system(size: 40))
            .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))

          VStack(alignment: .leading, spacing: 4) {
            Text("Sign in with Twitch")
              .font(.title3.weight(.bold))
            Text("Connect your account to see the channels you follow and join the chat.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 24)

          Button("Sign In") {
            onRequestSignIn()
          }
          .font(.headline)
          .buttonStyle(.borderedProminent)
          .tint(Color(red: 0.58, green: 0.41, blue: 0.96))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.primary.opacity(0.05))
        )
        .focusSection()
      }
    }
  }
}

// MARK: - Selectable option pill

/// Compact, focusable choice used inside a setting row. Shows an icon, a
/// title (with optional secondary line) and a trailing selection indicator
/// that never shifts layout between selected/unselected states.
private struct SettingPill: View {
  let systemImage: String
  let title: String
  var subtitle: String? = nil
  let isSelected: Bool

  private let accent = Color(red: 0.58, green: 0.41, blue: 0.96)

  var body: some View {
    HStack(spacing: 18) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.body)
        .foregroundStyle(isSelected ? accent : Color.secondary)
    }
    .padding(.horizontal, 26)
    .padding(.vertical, 16)
  }
}
