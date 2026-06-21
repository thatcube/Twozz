import SDWebImage
import SDWebImageSwiftUI
import SwiftUI

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
    BrandQRCodeView(payload: payload, logoName: "twitch-logo")
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
}

/// Casual "we're waiting on you" status shown while polling Twitch *or* YouTube
/// for authorization (shared by `SignInView` and `YouTubeSignInView`). Cycles
/// through a broad, randomized set of playful stream-culture phrases — each
/// paired with a real 7TV emote so the app's native emote support is on show
/// right from the sign-in screen. `accent` tints the pulsing dots to match the
/// host screen.
///
/// Emotes are pinned by 7TV ID — specifically the most-used (canonical) variant
/// of each name, resolved via 7TV's popularity sort — rather than looked up by
/// name, which can land on an obscure re-upload. They're warmed into SDWebImage's
/// disk cache on appear, and a phrase only enters rotation once its emote is
/// confirmed cached, so the emote slot is never blank.
struct SignInWaitingView: View {
  var accent: Color = Color(red: 0.58, green: 0.41, blue: 0.96)

  private struct Line {
    let text: String
    /// Canonical 7TV emote ID (most-used variant), pinned so it always loads.
    let emote: String

    var url: URL? { URL(string: "https://cdn.7tv.app/emote/\(emote)/2x.webp") }
  }

  private static let lines: [Line] = [
    Line(text: "Waiting on you", emote: "01F6RC8C1G0003SBEQ3QZTEE99"),        // peepoHappy
    Line(text: "Any second now", emote: "01F78CHJ2G0005TDSTZFBDGMK4"),        // monkaS
    Line(text: "We're so back", emote: "01FAPBB2400009222ZMH0DD1HS"),         // FeelsAmazingMan
    Line(text: "No rush, chat", emote: "01F7YR10C00004BT9YH569GV48"),         // FeelsGoodMan
    Line(text: "Easy clap", emote: "01F9FS6EEG0006XXD6DX0K9Y04"),            // EZ
    Line(text: "Hop in already", emote: "01F8CTQCZ800099FQVFJ9XQRM1"),        // AYAYA
    Line(text: "Vibing till you're in", emote: "01F6MQ33FG000FFJ97ZB8MWV52"), // catJAM
    Line(text: "Let's gooo", emote: "01FAJSRS8000093YGWG35GMV60"),           // PepePls
    Line(text: "Is it loading yet", emote: "01F6N2GFVR000F76KNAAVCSDGX"),     // PauseChamp
    Line(text: "Two more minutes", emote: "01F6ME7ADR0000WDA7ERT9H30R"),      // Copium
    Line(text: "Trust the process", emote: "01F6NACCD80006SZ7ZW5FMWKWK"),     // Prayge
    Line(text: "First!", emote: "01F61B1440000991F7SWQNMVX7"),               // KEKW
    Line(text: "Still here, still hyping", emote: "01F6NET6G00009JYTB75QDKV1S"), // peepoClap
    Line(text: "Big if true", emote: "01EZTD6KQ800012PTN006Q50PV"),          // Pepega
    Line(text: "Patiently malding", emote: "01F6ASPNM00009TPCEMWQTT4XX"),     // Madge
    Line(text: "Buffering good vibes", emote: "01GF1Y2Q5G0000BGNJSP34TQRD"),  // widepeepoHappy
    Line(text: "Nodders while we wait", emote: "01F6MDFCSR0000WDA7ERT623YT"), // NODDERS
    Line(text: "Chat's been patient", emote: "01EZPG1FN80001SNAW00ADK2DY"),   // Sadge
    Line(text: "Hold the W", emote: "01EZTCN91800012PTN006Q50PR"),           // Pog
    Line(text: "Clip it when you're in", emote: "01F6NE9AER000CKKT9BSDYGT0J"), // Clap
    Line(text: "We're aware, hop in", emote: "01FFWH9WV80000JT8GHDKHJNZC"),   // Aware
    Line(text: "Bedge, it's past your bedtime", emote: "01F6MXJD8R000F76KNAAV5HDGD"), // Bedge
    Line(text: "Just here chatting", emote: "01FAK9C8MR0004HKF2ZK1YPQ5A"),    // Chatting
    Line(text: "Hmm, any moment now", emote: "01F6MA6Y100002B6P5MWZ5D916"),   // Hmm
    Line(text: "ratJAM till you load", emote: "01F6QV6G8R0000TEKRM6BFG0Z3"),  // ratJAM
    Line(text: "monkaW the suspense", emote: "01F6NPHCN0000BEKN8ZXWQNSDC"),   // monkaW
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
  /// and only after the image actually exists. Bounded to a few concurrent
  /// downloads so the sign-in screen doesn't kick off ~two dozen requests at once
  /// (which starved the auth-polling network calls and spiked memory on tvOS).
  private func warmEmotes() {
    let emoteLines = Self.lines
    Task { @MainActor in
      await withTaskGroup(of: (String, Bool).self) { group in
        let maxConcurrent = 4
        var nextIndex = 0

        func startNext() {
          while nextIndex < emoteLines.count {
            let line = emoteLines[nextIndex]
            nextIndex += 1
            guard let url = line.url else { continue }
            let emote = line.emote
            group.addTask { (emote, await Self.warm(url)) }
            return
          }
        }

        for _ in 0..<maxConcurrent { startNext() }
        for await (emote, finished) in group {
          if finished { ready.insert(emote) }
          startNext()
        }
      }
    }
  }

  /// Load a single emote into SDWebImage's cache, bridging its completion handler
  /// into `async` so `warmEmotes` can bound concurrency. Returns whether the load
  /// finished with an image available.
  private static func warm(_ url: URL) async -> Bool {
    await withCheckedContinuation { continuation in
      SDWebImageManager.shared.loadImage(with: url, options: [.retryFailed], progress: nil) {
        _, _, _, _, finished, _ in
        continuation.resume(returning: finished)
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
