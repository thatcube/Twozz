import SwiftUI

/// The signed-out call-to-action card shown at the bottom of the Home tab. Only
/// rendered while the viewer isn't authenticated; tapping "Sign In" asks
/// `HomeView` to present the Twitch sign-in cover.
struct HomeAuthBanner: View {
  let onSignIn: () -> Void

  @Environment(AppEnvironment.self) private var environment
  @Environment(\.glassDisabled) private var glassDisabled
  private var auth: TwitchAuthSession { environment.auth }

  var body: some View {
    if !auth.isAuthenticated {
      HStack(spacing: 28) {
        Icon(glyph: .userPlus, size: 44)
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
          onSignIn()
        }
        .font(.headline)
      }
      .padding(.vertical, 32)
      .padding(.horizontal, 40)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 28)
          .fill(glassDisabled ? AnyShapeStyle(Color.twizzOpaqueGlass) : AnyShapeStyle(.ultraThinMaterial))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 28)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      )
      .padding(.top, 12)
      .focusSection()
    }
  }
}
