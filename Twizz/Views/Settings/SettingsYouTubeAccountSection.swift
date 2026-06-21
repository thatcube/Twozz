import SwiftUI

/// YouTube account panel: shown only when YouTube is configured. Displays the
/// connected account with a subscriptions toggle and sign-out, or a sign-in
/// prompt when not authenticated.
struct SettingsYouTubeAccountSection: View {
  var onRequestYouTubeSignIn: () -> Void = {}
  var onAccountChanged: () -> Void = {}

  @Environment(AppEnvironment.self) private var environment
  private var youtubeAuth: YouTubeAuthSession { environment.youtubeAuth }
  private var youtubeSubscriptions: YouTubeSubscriptionsService { environment.youtubeSubscriptions }

  @State private var showYouTubeSignOutConfirm = false
  @AppStorage(YouTubePreferences.showSubscriptionsKey) private var showYouTubeSubscriptions = true
  @Environment(\.glassDisabled) private var glassDisabled

  @ViewBuilder
  var body: some View {
    if youtubeAuth.isConfigured {
      if youtubeAuth.isAuthenticated {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 20) {
            CachedAsyncImage(url: youtubeAuth.profileImageURL) { image in
              image.resizable().scaledToFill()
            } placeholder: {
              Image("youtube-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
              Text(youtubeAuth.userDisplayName ?? "YouTube connected")
                .font(.title3.weight(.semibold))
              Text(youTubeSubscriptionSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 24)

            Button("Sign Out", role: .destructive) {
              showYouTubeSignOutConfirm = true
            }
            .font(.headline)
            .settingsProminentActionButtonStyle()
            .tint(.red)
          }

          Toggle(isOn: $showYouTubeSubscriptions) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Show YouTube subscriptions")
                .font(.headline)
              Text("Include channels you subscribe to on YouTube alongside your Twitch follows.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlassPanel(disabled: glassDisabled)
        .focusSection()
        .confirmationDialog(
          "Sign out of YouTube?",
          isPresented: $showYouTubeSignOutConfirm,
          titleVisibility: .visible
        ) {
          Button("Sign Out", role: .destructive) {
            youtubeAuth.signOut()
            onAccountChanged()
          }
          Button("Cancel", role: .cancel) {}
        }
      } else {
        HStack(spacing: 24) {
          Image("youtube-logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 52)

          VStack(alignment: .leading, spacing: 4) {
            Text("Sign in with YouTube")
              .font(.title3.weight(.bold))
            Text("See the channels you’re subscribed to.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 24)

          Button("Sign In") {
            onRequestYouTubeSignIn()
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

  private var youTubeSubscriptionSubtitle: String {
    let count = youtubeSubscriptions.subscriptions.count
    if youtubeSubscriptions.isLoading && count == 0 {
      return "Loading your subscriptions…"
    }
    if count == 0 {
      return "Signed in"
    }
    return "\(count) subscription\(count == 1 ? "" : "s")"
  }
}
