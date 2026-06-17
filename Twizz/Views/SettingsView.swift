import SwiftUI

/// Settings tab: appearance (theme) controls plus account sign-in / sign-out.
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

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 36) {
          Text("Settings")
            .font(.system(size: 40, weight: .bold))

          appearanceSection
          streamCardSection
          accountSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.vertical, 36)
      }
      .scrollClipDisabled()
    }
  }

  // MARK: - Appearance

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Appearance")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 24) {
        ForEach(AppTheme.allCases) { theme in
          Button {
            themeManager.theme = theme
          } label: {
            ThemeOptionCard(
              theme: theme,
              isSelected: themeManager.theme == theme
            )
          }
          .buttonStyle(.card)
          .focused($focusedTheme, equals: theme)
        }
      }
    }
    // Spatial navigation fix: span the section across the entire screen width.
    // This ensures a downward swipe from the right-aligned Tab Bar item hits
    // this container's bounding box instead of falling through to Sign In.
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
    .defaultFocus($focusedTheme, AppTheme.system)
  }

  // MARK: - Stream cards

  private var streamCardSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Stream Cards")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.secondary)

        Text("Choose how large stream cards appear across Home and Browse.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        ForEach(StreamCardSize.allCases) { size in
          Button {
            streamCardSizeRaw = size.rawValue
          } label: {
            StreamCardSizeOptionCard(
              size: size,
              isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size
            )
          }
          .buttonStyle(.card)
          .focused($focusedCardSize, equals: size)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
  }

  // MARK: - Account

  private var accountSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Account")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)

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

          VStack(alignment: .leading, spacing: 6) {
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
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 20)
            .fill(Color.primary.opacity(0.07))
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

          VStack(alignment: .leading, spacing: 6) {
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
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 20)
            .fill(Color.primary.opacity(0.07))
        )
        .focusSection()
      }
    }
  }
}

// MARK: - Theme option card

private struct ThemeOptionCard: View {
  let theme: AppTheme
  let isSelected: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: theme.symbolName)
        .font(.system(size: 34))
        .frame(height: 40)

      Text(theme.displayName)
        .font(.headline)

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.title3)
        .foregroundStyle(isSelected ? Color.green : Color.secondary)
    }
    .frame(width: 190)
    .padding(.vertical, 22)
    .overlay(
      RoundedRectangle(cornerRadius: 22)
        .stroke(isSelected ? Color.green : Color.clear, lineWidth: 3)
    )
  }
}

// MARK: - Stream card size option card

private struct StreamCardSizeOptionCard: View {
  let size: StreamCardSize
  let isSelected: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: size.symbolName)
        .font(.system(size: 34))
        .frame(height: 40)

      VStack(spacing: 2) {
        Text(size.title)
          .font(.headline)
        Text(size.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.title3)
        .foregroundStyle(isSelected ? Color.green : Color.secondary)
    }
    .frame(width: 190)
    .padding(.vertical, 22)
    .overlay(
      RoundedRectangle(cornerRadius: 22)
        .stroke(isSelected ? Color.green : Color.clear, lineWidth: 3)
    )
  }
}
