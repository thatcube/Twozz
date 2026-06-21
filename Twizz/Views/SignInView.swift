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
        .padding(.bottom, 48)
      }
    }
    .padding(.horizontal, 96)
    .padding(.top, 168)
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
      Icon(glyph: .circleCheckFilled, size: 96)
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

/// Casual "we're waiting on you" status shown while polling Twitch *or* YouTube
/// for authorization (shared by `SignInView` and `YouTubeSignInView`). Cycles
/// through a broad, randomized set of playful stream-culture phrases — each
/// paired with a real 7TV emote so the app's native emote support is on show
/// right from the sign-in screen. `accent` tints the pulsing dots to match the
/// host screen.
///
/// Emotes are pinned by 7TV ID (not looked up by name in the global set, which
/// only carries a handful of these) and warmed into SDWebImage's disk cache on
/// appear. A phrase only enters rotation once its emote is confirmed cached, so
/// the emote slot is never blank.
struct SignInWaitingView: View {
  var accent: Color = Color(red: 0.58, green: 0.41, blue: 0.96)

  private struct Line {
    let text: String
    /// 7TV emote ID. Resolved once (most-popular variant) and pinned so it
    /// always loads regardless of the global emote set.
    let emote: String

    var url: URL? { URL(string: "https://cdn.7tv.app/emote/\(emote)/2x.webp") }
  }

  private static let lines: [Line] = [
    Line(text: "Waiting on you", emote: "01KTR4A3Z08TPFNFA5CRVM9319"),        // peepoHappy
    Line(text: "Any second now", emote: "01KTFW0YRNDPZ6FATQG0CQZ6A7"),        // monkaS
    Line(text: "We're so back", emote: "01JTF4D0CN6QHA3A68NNZK3FD7"),         // FeelsAmazingMan
    Line(text: "Easy clap", emote: "01KTVPGWKSKYVEY7G53DP0BPY5"),            // EZ
    Line(text: "Hop in already", emote: "01KQXPJTS2RM5TX8K1VWFKETEX"),        // AYAYA
    Line(text: "Vibing till you're in", emote: "01KTBJSRP2QAY765T51QPGVJ2B"), // catJAM
    Line(text: "Let's gooo", emote: "01K5CGV5P7C2WZFXFAD38VNF8G"),           // PepePls
    Line(text: "Is it loading yet", emote: "01KT2RGK5MH64Q75MDWJPC468V"),     // PauseChamp
    Line(text: "Two more minutes", emote: "01KTVV0RVEWNDAJ2N3VEDMV6K8"),      // Copium
    Line(text: "Trust the process", emote: "01KT72MTR32MVPWA6VCGRDN7PR"),     // Prayge
    Line(text: "First!", emote: "01KVG21PGGY1C9WT2G07ENZSCA"),               // KEKW
    Line(text: "Still here, still hyping", emote: "01KJVJXHDFJXFCJGTN4R1EKJQK"), // peepoClap
    Line(text: "Big if true", emote: "01KTM1TVMBYHS7Y4G9D3W2H97J"),          // Pepega
    Line(text: "Patiently malding", emote: "01KTT576FP1C7VKWN1VCCB98ZQ"),     // Madge
    Line(text: "Buffering good vibes", emote: "01KTCNQ8E5J8FG3QWJPC1VG1BD"),  // widepeepoHappy
    Line(text: "Nodders while we wait", emote: "01KTVV5R0FK1MB84QQ6ZXM9SJH"), // NODDERS
    Line(text: "Chat's been patient", emote: "01KV0F3BNGAR3ZMPHN586FDJ6S"),   // Sadge
    Line(text: "Hold the W", emote: "01KVGFXBX0E9DK1M9YNR0NKT7Z"),           // Pog
    Line(text: "Clip it when you're in", emote: "01KV02YD3A6XD0MTWZK056MJJC"), // Clap
    Line(text: "Just staring at the door", emote: "01KV9DYTQS7H565JXS11FYZE2C"), // Stare
    Line(text: "WAYTOODANK loading", emote: "01KQZMQM5AQK6PG7DFBAGF5V15"),    // WAYTOODANK
  ]

  @State private var deck: [Line] = SignInWaitingView.lines.shuffled()
  @State private var index = 0
  /// 7TV IDs confirmed present in the image cache. A phrase only shows once its
  /// emote is in here, so the emote never pops in blank.
  @State private var ready: Set<String> = []
  @State private var visible = true

  private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  /// The phrase to display: prefer ones whose emote is cached; fall back to the
  /// full deck only while nothing has loaded yet (very first frames).
  private var line: Line {
    let loaded = deck.filter { ready.contains($0.emote) }
    let pool = loaded.isEmpty ? deck : loaded
    return pool[index % pool.count]
  }

  var body: some View {
    HStack(spacing: 24) {
      PulsingDots(accent: accent)

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
    .task { warmEmotes() }
    .onReceive(timer) { _ in
      withAnimation(.easeInOut(duration: 0.35)) { visible = false }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        index += 1
        // Reshuffle each time we exhaust the deck so the order stays random
        // rather than repeating the same sequence on a loop.
        if index % deck.count == 0 { deck.shuffle() }
        withAnimation(.easeInOut(duration: 0.35)) { visible = true }
      }
    }
  }

  /// Download every emote into SDWebImage's (disk-backed, cross-launch) cache up
  /// front and mark each ready as it lands, so they render instantly on cycle —
  /// and only after the image actually exists.
  private func warmEmotes() {
    for emoteLine in Self.lines {
      guard let url = emoteLine.url else { continue }
      SDWebImageManager.shared.loadImage(with: url, options: [.retryFailed], progress: nil) { _, _, _, _, finished, _ in
        if finished { ready.insert(emoteLine.emote) }
      }
    }
  }

  @ViewBuilder
  private var emoteView: some View {
    if let url = line.url {
      AnimatedImage(url: url)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(height: 56)
        .fixedSize(horizontal: true, vertical: false)
    }
  }
}

/// Three dots that fade and scale in sequence to signal ongoing background work
/// (e.g. polling Twitch for authorization). `accent` tints the dots to match the
/// host sign-in screen.
struct PulsingDots: View {
  var accent: Color = Color(red: 0.58, green: 0.41, blue: 0.96)

  private let dotCount = 3
  @State private var isAnimating = false

  var body: some View {
    HStack(spacing: 10) {
      ForEach(0..<dotCount, id: \.self) { index in
        Circle()
          .fill(accent)
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
