import CoreImage.CIFilterBuiltins
import SDWebImage
import SDWebImageSwiftUI
import SwiftUI
import UIKit

/// Full-screen account / sign-in page presented from the top-right profile button.
/// When signed out it offers two side-by-side options separated by an "OR" divider:
/// scan a QR code with a phone, or visit the activation URL and type the device code.
/// Everything is in oversized type so it can be read and scanned from across the room.
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
      }
    }
    .padding(96)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Option: scan QR

  private var qrOption: some View {
    VStack(spacing: 40) {
      Text("Scan with your phone")
        .font(.system(size: 48, weight: .bold))

      qrCodeView
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Option: enter a code

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
            .font(.system(size: 84, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))
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
    .frame(height: 620)
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
    .frame(width: 500, height: 500)
    .padding(32)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 36))
  }

  @ViewBuilder
  private var codeView: some View {
    if let code = auth.activationCode {
      Text(code)
        .font(.system(size: 156, weight: .black, design: .monospaced))
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
      SignInWaitingView()
    } else if let status = auth.statusMessage {
      Text(status)
        .font(.title3)
        .foregroundStyle(.secondary)
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

/// Casual "we're waiting on you" status shown while polling Twitch for
/// authorization. Cycles through a set of playful, Twitch-flavored phrases —
/// each paired with a real third-party emote (7TV / BTTV / FFZ) so the app's
/// native emote support is on show right from the sign-in screen.
private struct SignInWaitingView: View {
  private struct Line {
    let text: String
    let emote: String
  }

  private static let lines: [Line] = [
    Line(text: "Waiting on you", emote: "peepoHappy"),
    Line(text: "Any second now", emote: "monkaS"),
    Line(text: "We're so back", emote: "FeelsAmazingMan"),
    Line(text: "No rush, chat", emote: "FeelsGoodMan"),
    Line(text: "Easy clap", emote: "EZ"),
    Line(text: "Hop in already", emote: "AYAYA"),
    Line(text: "Vibing till you're in", emote: "ffzJam"),
    Line(text: "Let's gooo", emote: "PepePls"),
  ]

  @State private var index = 0
  @State private var emoteURLs: [String: URL] = [:]
  @State private var visible = true

  private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  private var line: Line { Self.lines[index % Self.lines.count] }

  var body: some View {
    HStack(spacing: 24) {
      PulsingDots()

      HStack(spacing: 18) {
        Text(line.text)
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(.secondary)

        emoteView
      }
      .opacity(visible ? 1 : 0)
      .animation(.easeInOut(duration: 0.35), value: visible)
    }
    .frame(minHeight: 64)
    .task {
      let catalog = await EmoteCatalogService.shared.globalCatalog()
      emoteURLs = catalog
      // Warm the image cache up front so emotes appear instantly as they cycle,
      // rather than downloading on first display.
      let urls = Self.lines.compactMap { catalog[$0.emote] }
      SDWebImagePrefetcher.shared.prefetchURLs(urls)
    }
    .onReceive(timer) { _ in
      withAnimation(.easeInOut(duration: 0.35)) { visible = false }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        index += 1
        withAnimation(.easeInOut(duration: 0.35)) { visible = true }
      }
    }
  }

  @ViewBuilder
  private var emoteView: some View {
    if let url = emoteURLs[line.emote] {
      AnimatedImage(url: url)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(height: 56)
        .fixedSize(horizontal: true, vertical: false)
    }
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
