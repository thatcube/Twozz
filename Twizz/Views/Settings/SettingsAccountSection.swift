import SwiftUI

/// Twitch account panel: shows the signed-in user with a sign-out action, or a
/// sign-in prompt when not authenticated.
struct SettingsAccountSection: View {
  var onRequestSignIn: () -> Void = {}
  var onAccountChanged: () -> Void = {}

  @Environment(AppEnvironment.self) private var environment
  private var auth: TwitchAuthSession { environment.auth }

  @State private var showSignOutConfirm = false
  @Environment(\.glassDisabled) private var glassDisabled

  var body: some View {
    Group {
      if auth.isAuthenticated {
        HStack(spacing: 20) {
          CachedAsyncImage(url: auth.profileImageURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Icon(glyph: .userCircle, size: 64)
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
          .settingsProminentActionButtonStyle()
          .tint(.red)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlassPanel(disabled: glassDisabled)
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
          Image("twitch-logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 52)

          VStack(alignment: .leading, spacing: 4) {
            Text("Sign in with Twitch")
              .font(.title3.weight(.bold))
            Text("See the channels you follow and send messages in chat.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 24)

          Button("Sign In") {
            onRequestSignIn()
          }
          .font(.headline)
          .settingsProminentActionButtonStyle()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlassPanel(disabled: glassDisabled)
        .focusSection()
      }
    }
  }
}
