import SwiftUI

/// Full-screen YouTube account sign-in, mirroring `SignInView` but driving the
/// Google device flow. When signed out it shows a QR to scan plus the activation
/// URL and device code in oversized type so it's readable across the room.
struct YouTubeSignInView: View {
  let auth: YouTubeAuthSession
  var isEmbedded: Bool = false
  var onSignedIn: () -> Void = {}

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false

  private let displayURL = "youtube.com/activate"
  private let youTubeRed = Color(red: 1.0, green: 0.0, blue: 0.0)

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      if auth.isAuthenticated {
        signedInContent
      } else {
        signInContent
      }
    }
    .onAppear {
      if !auth.isAuthenticated && !auth.isAuthenticating {
        Task { await auth.beginDeviceCodeSignIn() }
      }
    }
    .onChange(of: auth.isAuthenticated) { _, signedIn in
      if signedIn {
        onSignedIn()
        if !isEmbedded { dismiss() }
      }
    }
  }

  // MARK: - Signed out

  private var signInContent: some View {
    VStack(spacing: 64) {
      HStack(alignment: .center, spacing: 96) {
        qrOption
        orDivider
        codeOption
      }
      .padding(.horizontal, 32)
      .frame(maxWidth: .infinity)

      statusArea

      if !isEmbedded {
        Button("Cancel") {
          auth.cancelSignIn()
          dismiss()
        }
        .padding(.top, 8)
        .padding(.bottom, 48)
      }
    }
    .padding(.horizontal, 96)
    .padding(.top, 168)
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var qrOption: some View {
    VStack(spacing: 40) {
      Text("Scan with your phone")
        .font(.system(size: 48, weight: .bold))
      qrCodeView
    }
    .frame(maxWidth: .infinity)
  }

  private var codeOption: some View {
    VStack(spacing: 40) {
      Text("Or enter a code")
        .font(.system(size: 48, weight: .bold))

      VStack(spacing: 28) {
        VStack(spacing: 6) {
          Text("Go to")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text(displayURL)
            .font(.system(size: 72, weight: .heavy, design: .rounded))
            .foregroundStyle(youTubeRed)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }

        VStack(spacing: 6) {
          Text("and enter")
            .font(.title2)
            .foregroundStyle(.secondary)
          codeView
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var orDivider: some View {
    VStack(spacing: 20) {
      Rectangle()
        .fill(Color.white.opacity(0.15))
        .frame(width: 2)
        .frame(maxHeight: .infinity)
      Text("OR")
        .font(.system(size: 32, weight: .bold))
        .foregroundStyle(.secondary)
      Rectangle()
        .fill(Color.white.opacity(0.15))
        .frame(width: 2)
        .frame(maxHeight: .infinity)
    }
    .frame(height: 560)
  }

  @ViewBuilder
  private var qrCodeView: some View {
    let payload = auth.verificationURI ?? "https://www.google.com/device"
    BrandQRCodeView(payload: payload, logoName: "youtube-logo", moduleColor: youTubeRed)
  }

  @ViewBuilder
  private var codeView: some View {
    if let code = auth.activationCode {
      Text(code)
        .font(.system(size: 132, weight: .black, design: .monospaced))
        .tracking(10)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    } else {
      HStack(spacing: 16) {
        ProgressView()
        Text("Getting your code…")
          .font(.title)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var statusArea: some View {
    if let error = auth.errorMessage {
      Text(error)
        .font(.title3)
        .foregroundStyle(.orange)
        .multilineTextAlignment(.center)
    } else if auth.isAuthenticating {
      SignInWaitingView(accent: youTubeRed)
    } else if let status = auth.statusMessage {
      Text(status)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Signed in

  private var signedInContent: some View {
    VStack(spacing: 36) {
      Icon(glyph: .circleCheckFilled, size: 96)
        .foregroundStyle(.green)

      VStack(spacing: 8) {
        Text("Signed in to YouTube")
          .font(.system(size: 56, weight: .bold))
        Text("Your YouTube subscriptions are now available.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        if !isEmbedded {
          Button("Done") { dismiss() }
        }
        Button("Sign Out") { showSignOutConfirm = true }
      }
      .buttonStyle(.bordered)
      .padding(.top, 12)
    }
    .padding(80)
    .confirmationDialog(
      "Sign out of YouTube?",
      isPresented: $showSignOutConfirm,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) {
        auth.signOut()
        onSignedIn()
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    }
  }
}

#if DEBUG
#Preview {
  YouTubeSignInView(auth: YouTubeAuthSession())
    .environment(\.themePalette, AppTheme.system.palette(systemColorScheme: .dark))
}
#endif
