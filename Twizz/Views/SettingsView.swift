import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Settings tab: appearance (theme) controls plus account sign-in / sign-out.
///
/// Laid out as a tvOS-native grouped "form": each preference is a single
/// horizontal row — a left-aligned label/description with its choices rendered
/// as compact, focusable pills on the right. This keeps the whole screen
/// dense enough that every section (including Account) is visible at once.
struct SettingsView: View {
  @Bindable var themeManager: ThemeManager
  let auth: TwitchAuthSession
  var youtubeAuth: YouTubeAuthSession
  var youtubeSubscriptions: YouTubeSubscriptionsService
  var follows: FollowedChannelsService
  var goLiveSettings: GoLiveNotificationSettings
  var recommendationFeedback: RecommendationFeedbackService
  var onRequestSignIn: () -> Void = {}
  var onRequestYouTubeSignIn: () -> Void = {}
  var onClearWatchHistory: () -> Void = {}
  var onResetNotInterested: () -> Void = {}
  var onAccountChanged: () -> Void = {}
  var onRepublishTopShelf: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false
  @State private var showYouTubeSignOutConfirm = false
  @State private var showClearHistoryConfirm = false
  @State private var showResetNotInterestedConfirm = false
  @State private var topShelfStatus = TopShelfStore.diagnosticsSummary()
  @FocusState private var focusedTheme: AppTheme?
  @FocusState private var focusedCardSize: StreamCardSize?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage("showChatByDefault") private var showChatByDefault = true
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedRecommendationsEnabled = true
  @AppStorage(StreamLanguagePreference.storageKey) private var streamLanguage = StreamLanguagePreference.deviceDefault()
  @AppStorage(GoLiveNotificationPreferences.enabledKey) private var goLiveAlertsEnabled = true
  @AppStorage("disableLiquidGlass") private var disableLiquidGlass = false
  @AppStorage(YouTubePreferences.showSubscriptionsKey) private var showYouTubeSubscriptions = true
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private let labelColumnWidth: CGFloat = 420

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(
          colors: palette.backgroundColors,
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 28) {
            Text("Settings")
              .font(.system(size: 38, weight: .bold))
              .accessibilityAddTraits(.isHeader)

            preferencesGroup
            accountSection
            youTubeAccountSection
            topShelfSection
            AboutSection()
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 32)
        }
        .scrollClipDisabled()
      }
    }
  }

  // MARK: - Preferences group (Appearance + Stream Cards + Chat)

  private var preferencesGroup: some View {
    VStack(spacing: 0) {
      appearanceRow
        .padding(.vertical, 16)

      groupDivider

      streamCardRow
        .padding(.vertical, 16)

      groupDivider

      chatRow
        .padding(.vertical, 16)

      groupDivider

      languageRow
        .padding(.vertical, 16)

      groupDivider

      recommendationsRow
        .padding(.vertical, 16)

      groupDivider

      goLiveAlertsRow
        .padding(.vertical, 16)

      groupDivider

      reduceTransparencyRow
        .padding(.vertical, 16)
    }
    .padding(.horizontal, 28)
    .glassPanel(disabled: glassDisabled)
  }

  private var groupDivider: some View {
    Divider()
      .overlay(Color.primary.opacity(0.12))
  }

  private var appearanceRow: some View {
    settingRow(
      title: "Appearance",
      subtitle: nil
    ) {
      ForEach(AppTheme.allCases) { theme in
        Button {
          themeManager.theme = theme
        } label: {
          SettingPill(title: theme.displayName, isSelected: themeManager.theme == theme)
        }
        .settingPillStyle(isSelected: themeManager.theme == theme)
        .focused($focusedTheme, equals: theme)
      }
    }
  }

  private var streamCardRow: some View {
    settingRow(
      title: "Stream card size",
      subtitle: nil
    ) {
      ForEach(StreamCardSize.allCases) { size in
        Button {
          streamCardSizeRaw = size.rawValue
        } label: {
          SettingPill(
            title: size.title,
            subtitle: size.subtitle,
            isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size
          )
        }
        .settingPillStyle(isSelected: StreamCardSize.resolve(streamCardSizeRaw) == size)
        .focused($focusedCardSize, equals: size)
      }
    }
  }

  private var chatRow: some View {
    settingRow(
      title: "Open chat by default",
      subtitle: nil
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          showChatByDefault = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: showChatByDefault == on)
        }
        .settingPillStyle(isSelected: showChatByDefault == on)
      }
    }
  }

  private var languageRow: some View {
    settingRow(
      title: "Stream Language",
      subtitle: "Only show streams in this language."
    ) {
      Menu {
        Picker("Stream Language", selection: $streamLanguage) {
          ForEach(StreamLanguagePreference.options, id: \.value) { option in
            Text(option.name).tag(option.value)
          }
        }
        .pickerStyle(.inline)
      } label: {
        SettingPill(title: StreamLanguagePreference.displayName(streamLanguage), isSelected: false, showsMenuIndicator: true)
      }
      .prominentActionButtonStyle()
    }
  }

  private var recommendationsRow: some View {
    settingRow(
      title: "Recommendations",
      subtitle: "Based on who you follow and watch. History stays on this Apple TV."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          personalizedRecommendationsEnabled = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: personalizedRecommendationsEnabled == on)
        }
        .settingPillStyle(isSelected: personalizedRecommendationsEnabled == on)
      }

      Button {
        showClearHistoryConfirm = true
      } label: {
        SettingPill(title: "Clear History", isSelected: false)
      }
      .settingPillStyle(isSelected: false)

      if recommendationFeedback.hasFeedback {
        Button {
          showResetNotInterestedConfirm = true
        } label: {
          SettingPill(title: "Reset Not Interested", isSelected: false)
        }
        .settingPillStyle(isSelected: false)
      }
    }
    .confirmationDialog(
      "Clear watch history?",
      isPresented: $showClearHistoryConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) {
        onClearWatchHistory()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes the watch history stored on this device.")
    }
    .confirmationDialog(
      "Reset “Not Interested”?",
      isPresented: $showResetNotInterestedConfirm,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) {
        onResetNotInterested()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Channels you marked “Not interested” can be recommended again.")
    }
  }

  /// A single preference row: fixed-width label column on the left, a
  /// horizontal run of selectable pills on the right.
  private var goLiveAlertsRow: some View {
    settingRow(
      title: "Go Live Alerts",
      subtitle: "In-app pop-up on this Apple TV when a channel you follow goes live. Doesn't change Twitch notifications on your other devices."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          goLiveAlertsEnabled = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: goLiveAlertsEnabled == on)
        }
        .settingPillStyle(isSelected: goLiveAlertsEnabled == on)
      }

      NavigationLink {
        GoLiveAlertsSettingsView(follows: follows, settings: goLiveSettings, auth: auth)
      } label: {
        SettingPill(title: "Choose Channels", isSelected: false)
      }
      .settingPillStyle(isSelected: false)
      .disabled(!goLiveAlertsEnabled)
      .opacity(goLiveAlertsEnabled ? 1 : 0.4)
    }
  }

  /// Reduce Transparency toggle: swaps translucent Liquid Glass surfaces for
  /// opaque, high-contrast fills app-wide. The OS "Reduce Transparency"
  /// accessibility setting forces this on regardless of the in-app choice.
  private var reduceTransparencyRow: some View {
    settingRow(
      title: "Reduce Transparency",
      subtitle: reduceTransparency
        ? "Translucent panels are replaced with solid, high-contrast fills. Forced on by the system Reduce Transparency setting."
        : "Replace translucent Liquid Glass panels with solid, high-contrast fills for better legibility."
    ) {
      ForEach([true, false], id: \.self) { on in
        Button {
          disableLiquidGlass = on
        } label: {
          SettingPill(title: on ? "On" : "Off", isSelected: disableLiquidGlass == on)
        }
        .settingPillStyle(isSelected: disableLiquidGlass == on)
        .disabled(reduceTransparency)
        .opacity(reduceTransparency ? 0.4 : 1)
      }
    }
  }

  private func settingRow<Content: View>(
    title: String,
    subtitle: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 32) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 32, weight: .bold))
        if let subtitle {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(width: labelColumnWidth, alignment: .leading)

      HStack(spacing: 16) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
  }

  private var accountSection: some View {
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
          .prominentActionButtonStyle()
          .tint(.red)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(disabled: glassDisabled)
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
          Icon(glyph: .userPlus, size: 40)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 4) {
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
          .prominentActionButtonStyle()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(disabled: glassDisabled)
        .focusSection()
      }
    }
  }

  @ViewBuilder
  private var youTubeAccountSection: some View {
    if youtubeAuth.isConfigured {
      let youTubeRed = Color(red: 1.0, green: 0.0, blue: 0.0)
      if youtubeAuth.isAuthenticated {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 20) {
            Icon(glyph: .brandYoutube, size: 44)
              .foregroundStyle(youTubeRed)

            VStack(alignment: .leading, spacing: 4) {
              Text("YouTube connected")
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
            .prominentActionButtonStyle()
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
        .glassPanel(disabled: glassDisabled)
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
          Icon(glyph: .brandYoutube, size: 40)
            .foregroundStyle(youTubeRed)

          VStack(alignment: .leading, spacing: 4) {
            Text("Connect YouTube")
              .font(.title3.weight(.bold))
            Text("Sign in to bring your subscribed YouTube streamers into Twizz.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 24)

          Button("Sign In") {
            onRequestYouTubeSignIn()
          }
          .font(.headline)
          .prominentActionButtonStyle()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(disabled: glassDisabled)
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

// MARK: - Theme option card

  private var topShelfSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Top Shelf")
          .font(.system(size: 32, weight: .bold))
          .accessibilityAddTraits(.isHeader)
          .foregroundStyle(.secondary)

        Text("Diagnostics for the stream cards shown above the app on the Home screen.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        Icon(glyph: .cards, size: 44)
          .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))

        VStack(alignment: .leading, spacing: 6) {
          Text("Snapshot status")
            .font(.title3.weight(.semibold))
          Text(topShelfStatus)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 24)

        VStack(spacing: 16) {
          Button("Republish") {
            onRepublishTopShelf()
            topShelfStatus = TopShelfStore.diagnosticsSummary()
          }
          .font(.headline)
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 24)
          .fill(Color.primary.opacity(0.07))
      )
      .focusSection()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      onRepublishTopShelf()
      topShelfStatus = TopShelfStore.diagnosticsSummary()
    }
  }
}

// MARK: - About

/// Footer panel showing app identity, version, open-source info, and a QR
/// code linking to the GitHub repo (tvOS has no browser, so a scannable code
/// is the way to hand a URL to a phone). Focusable so the tvOS focus engine
/// can scroll it into view at the bottom of the list.
private struct AboutSection: View {
  @FocusState private var isFocused: Bool
  @Environment(\.glassDisabled) private var glassDisabled

  private static let repoURL = "https://github.com/thatcube/Twizz"

  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 32) {
      VStack(alignment: .leading, spacing: 16) {
        Image("TwizzPixelLogo")
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(width: 72, height: 72)

        Text("About")
          .font(.system(size: 32, weight: .bold))
          .accessibilityAddTraits(.isHeader)

        VStack(alignment: .leading, spacing: 10) {
          infoRow("Name", "Twizz")
          infoRow("Version", version)
          infoRow("Build", build)
        }

        Text("Twizz is free and open source. It's an unofficial Twitch client for Apple TV, not affiliated with or endorsed by Twitch.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(spacing: 12) {
        QRCodeView(string: Self.repoURL)
          .frame(width: 160, height: 160)

        Text("Scan to view the\nGitHub repo or donate")
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }
    }
    .padding(28)
    .glassPanel(disabled: glassDisabled)
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.primary.opacity(isFocused ? 0.45 : 0), lineWidth: 2)
    )
    .scaleEffect(isFocused ? 1.01 : 1)
    .focusable()
    .focused($isFocused)
    .animation(.easeOut(duration: 0.15), value: isFocused)
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack(spacing: 16) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      Text(value)
      Spacer(minLength: 0)
    }
    .font(.headline)
  }
}

/// Renders a QR code for an arbitrary string using CoreImage. The generated
/// image is nearest-neighbor scaled so the code stays crisp at display size.
private struct QRCodeView: View {
  let string: String

  var body: some View {
    if let image = Self.makeQRCode(from: string) {
      Image(uiImage: image)
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          Image("GitHubMark")
            .resizable()
            .scaledToFit()
            .frame(width: 34, height: 34)
            .padding(7)
            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    } else {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.2))
    }
  }

  private static func makeQRCode(from string: String) -> UIImage? {
    let context = CIContext()
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

// MARK: - Selectable option pill

/// Compact label used inside a setting row. Focus is handled by the native
/// Liquid Glass button style; the active option is marked with a trailing
/// checkmark (reserved width so pills stay aligned), matching the tvOS
/// Settings selection idiom.
private struct SettingPill: View {
  let title: String
  var subtitle: String? = nil
  let isSelected: Bool
  /// When true the pill is a dropdown trigger (a `Menu` label), so it shows a
  /// trailing up/down selector chevron instead of the selection checkmark slot.
  var showsMenuIndicator: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }

      if showsMenuIndicator {
        Icon(glyph: .selector, size: 40)
      } else if isSelected {
        Icon(glyph: .check, size: 26)
      }
    }
  }
}

// MARK: - Native styling helpers

extension View {
  /// Frosted Liquid Glass panel (tvOS 26+) with a material fallback.
  @ViewBuilder
  fileprivate func glassPanel(disabled: Bool) -> some View {
    modifier(SettingsGlassPanelModifier(disabled: disabled))
  }

  /// Selectable option styling. Applies a single native button style
  /// **unconditionally** (it ignores `isSelected` for styling), so the active
  /// option is indicated only by `SettingPill`'s trailing checkmark — matching
  /// the tvOS Settings idiom and giving the genuine native focus state.
  ///
  /// Why not vary the style by selection: swapping styles (e.g. `.glass` ↔
  /// `.glassProminent`) changes the view's identity, so toggling an option
  /// destroys the focused pill and tvOS snaps focus back to the first item.
  /// Keeping one stable style preserves identity, so focus stays put.
  @ViewBuilder
  fileprivate func settingPillStyle(isSelected _: Bool) -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.bordered)
    }
  }

  /// Prominent action button: Liquid Glass prominent on tvOS 26+, bordered
  /// prominent otherwise.
  @ViewBuilder
  fileprivate func prominentActionButtonStyle() -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glassProminent)
    } else {
      self.buttonStyle(.borderedProminent)
    }
  }
}

/// Backs the Settings section panels. When transparency is reduced (`disabled`)
/// the panel becomes opaque — but it must follow the active theme rather than the
/// shared near-black `twizzOpaqueGlass`, so the Light theme stays light instead of
/// darkening just because transparency was turned off. Dark/OLED resolve to the
/// same near-black fill + hairline as before, so they are unchanged.
private struct SettingsGlassPanelModifier: ViewModifier {
  let disabled: Bool
  @Environment(\.themePalette) private var palette

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    if disabled {
      content
        .background(palette.cardOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.cardOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content.background(.ultraThinMaterial, in: shape)
    }
  }
}
