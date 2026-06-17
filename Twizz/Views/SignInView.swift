import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Full-screen account / sign-in page presented from the top-right profile button.
/// When signed out it shows a large QR code, the activation URL, and the device code
/// in oversized type so it can be read and scanned from across the room.
struct SignInView: View {
  let auth: TwitchAuthSession
  var isEmbedded: Bool = false
  var onSignedIn: () -> Void = {}

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false

  private let displayURL = "twitch.tv/activate"

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
    VStack(spacing: 48) {
      VStack(spacing: 10) {
        Text("Sign in with Twitch")
          .font(.system(size: 64, weight: .bold))
        Text("Scan the code, or visit the link on your phone or computer.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      HStack(alignment: .center, spacing: 72) {
        qrCodeView

        VStack(alignment: .leading, spacing: 36) {
          VStack(alignment: .leading, spacing: 8) {
            Text("1.  Go to")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text(displayURL)
              .font(.system(size: 72, weight: .heavy, design: .rounded))
              .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("2.  Enter code")
              .font(.title2)
              .foregroundStyle(.secondary)
            codeView
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 24)

      statusArea

      if !isEmbedded {
        Button("Cancel") {
          auth.cancelSignIn()
          dismiss()
        }
        .padding(.top, 8)
      }
    }
    .padding(80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var qrCodeView: some View {
    let payload = auth.verificationURIComplete ?? auth.verificationURI ?? "https://www.twitch.tv/activate"

    Group {
      if let image = Self.makeQRCode(from: payload) {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
      } else {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.white.opacity(0.1))
          .overlay(ProgressView())
      }
    }
    .frame(width: 380, height: 380)
    .padding(24)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 28))
  }

  @ViewBuilder
  private var codeView: some View {
    if let code = auth.activationCode {
      Text(code)
        .font(.system(size: 200, weight: .black, design: .monospaced))
        .tracking(12)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    } else {
      HStack(spacing: 16) {
        ProgressView()
        Text("Getting your code…")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var statusArea: some View {
    if let error = auth.errorMessage {
      Text(error)
        .font(.headline)
        .foregroundStyle(.orange)
        .multilineTextAlignment(.center)
    } else if let status = auth.statusMessage {
      HStack(spacing: 16) {
        if auth.isAuthenticating {
          PulsingDots()
        }
        Text(status)
          .font(.headline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Signed in

  private var signedInContent: some View {
    VStack(spacing: 36) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 96))
        .foregroundStyle(.green)

      VStack(spacing: 8) {
        Text("Signed in")
          .font(.system(size: 56, weight: .bold))
        Text(auth.userDisplayName ?? auth.userLogin ?? "Twitch user")
          .font(.title2)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        if !isEmbedded {
          Button("Done") {
            dismiss()
          }
        }

        Button("Sign Out") {
          showSignOutConfirm = true
        }
      }
      .buttonStyle(.bordered)
      .padding(.top, 12)
    }
    .padding(80)
    .confirmationDialog(
      "Sign out of Twitch?",
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

  // MARK: - QR generation

  private static let ciContext = CIContext()

  private static func makeQRCode(from string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

/// Three dots that fade and scale in sequence to signal ongoing background work
/// (e.g. polling Twitch for authorization).
private struct PulsingDots: View {
  private let dotCount = 3
  @State private var isAnimating = false

  var body: some View {
    HStack(spacing: 10) {
      ForEach(0..<dotCount, id: \.self) { index in
        Circle()
          .fill(Color(red: 0.58, green: 0.41, blue: 0.96))
          .frame(width: 14, height: 14)
          .scaleEffect(isAnimating ? 1.0 : 0.4)
          .opacity(isAnimating ? 1.0 : 0.3)
          .animation(
            .easeInOut(duration: 0.6)
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 0.2),
            value: isAnimating
          )
      }
    }
    .onAppear { isAnimating = true }
  }
}

#Preview {
  SignInView(auth: TwitchAuthSession())
}
