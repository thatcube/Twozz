import SwiftUI

/// Settings tab: appearance (theme) controls plus account sign-in / sign-out.
struct SettingsView: View {
  @Bindable var themeManager: ThemeManager
  let auth: TwitchAuthSession
  var onRequestSignIn: () -> Void = {}
  var onAccountChanged: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 56) {
          Text("Settings")
            .font(.system(size: 56, weight: .bold))

          appearanceSection
          accountSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
      }
      .scrollClipDisabled()
    }
  }

  // MARK: - Appearance

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("Appearance")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 28) {
        ForEach(AppTheme.allCases) { theme in
          ThemeOptionCard(
            theme: theme,
            isSelected: themeManager.theme == theme
          ) {
            themeManager.theme = theme
          }
        }
      }
      .focusSection()
    }
  }

  // MARK: - Account

  private var accountSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("Account")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.secondary)

      if auth.isAuthenticated {
        HStack(spacing: 24) {
          AsyncImage(url: auth.profileImageURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
              .foregroundStyle(.secondary)
          }
          .frame(width: 88, height: 88)
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
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 24)
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
            onRequestSignIn()
          }
          .font(.headline)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 24)
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
  let action: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      VStack(spacing: 16) {
        Image(systemName: theme.symbolName)
          .font(.system(size: 40))
          .frame(height: 48)

        Text(theme.displayName)
          .font(.headline)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isSelected ? Color.green : Color.secondary)
      }
      .frame(width: 200, height: 200)
      .background(
        RoundedRectangle(cornerRadius: 22)
          .fill(isFocused ? Color.primary.opacity(0.18) : Color.primary.opacity(0.07))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22)
          .stroke(isSelected ? Color.green : Color.clear, lineWidth: 3)
      )
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .scaleEffect(isFocused ? 1.06 : 1)
    .animation(.easeOut(duration: 0.14), value: isFocused)
  }
}
