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
  var onRequestSignIn: () -> Void = {}
  var onAccountChanged: () -> Void = {}
  var onRepublishTopShelf: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var showSignOutConfirm = false
  @State private var topShelfStatus = TopShelfStore.diagnosticsSummary()
  @FocusState private var focusedTheme: AppTheme?
  @FocusState private var focusedCardSize: StreamCardSize?

  @AppStorage(StreamCardSize.storageKey) private var streamCardSizeRaw = StreamCardSize.fallback.rawValue
  @AppStorage("showChatByDefault") private var showChatByDefault = true

  private let labelColumnWidth: CGFloat = 360

  var body: some View {
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

          preferencesGroup
          accountSection
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

  // MARK: - Preferences group (Appearance + Stream Cards + Chat)

  private var preferencesGroup: some View {
    VStack(spacing: 0) {
      appearanceRow
        .padding(.vertical, 20)

      groupDivider

      streamCardRow
        .padding(.vertical, 20)

      groupDivider

      chatRow
        .padding(.vertical, 20)
    }
    .padding(.horizontal, 28)
    .glassPanel()
  }

  private var groupDivider: some View {
    Divider()
      .overlay(Color.primary.opacity(0.12))
  }

  private var appearanceRow: some View {
    settingRow(
      title: "Appearance",
      subtitle: "Theme used throughout the app."
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
    .defaultFocus($focusedTheme, AppTheme.system)
  }

  private var streamCardRow: some View {
    settingRow(
      title: "Stream Cards",
      subtitle: "How large stream cards appear on Home and Browse."
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
      title: "Chat",
      subtitle: "Show chat automatically when you open a stream."
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

  /// A single preference row: fixed-width label column on the left, a
  /// horizontal run of selectable pills on the right.
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
          AsyncImage(url: auth.profileImageURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Image(systemName: "person.crop.circle.fill")
              .resizable()
              .scaledToFit()
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
        .glassPanel()
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
          Image(systemName: "person.crop.circle.badge.plus")
            .font(.system(size: 40))
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
        .glassPanel()
        .focusSection()
      }
    }
  }

// MARK: - Theme option card

  private var topShelfSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Top Shelf")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(.secondary)

        Text("Diagnostics for the stream cards shown above the app on the Home screen.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 24) {
        Image(systemName: "rectangle.topthird.inset.filled")
          .font(.system(size: 44))
          .foregroundStyle(Color(red: 0.58, green: 0.41, blue: 0.96))

        VStack(alignment: .leading, spacing: 6) {
          Text("Snapshot status")
            .font(.title3.weight(.semibold))
          Text(topShelfStatus)
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 24)

        Button("Republish") {
          onRepublishTopShelf()
          topShelfStatus = TopShelfStore.diagnosticsSummary()
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
    .glassPanel()
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

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Image(systemName: "checkmark")
        .font(.subheadline.weight(.bold))
        .opacity(isSelected ? 1 : 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }
}

// MARK: - Native styling helpers

extension View {
  /// Frosted Liquid Glass panel (tvOS 26+) with a material fallback.
  @ViewBuilder
  fileprivate func glassPanel() -> some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    if #available(tvOS 26.0, *) {
      self.glassEffect(.regular, in: shape)
    } else {
      self.background(.ultraThinMaterial, in: shape)
    }
  }

  /// Selectable option styling: native Liquid Glass with the active option
  /// rendered prominent. Falls back to bordered styles before tvOS 26.
  @ViewBuilder
  fileprivate func settingPillStyle(isSelected: Bool) -> some View {
    if #available(tvOS 26.0, *) {
      if isSelected {
        self.buttonStyle(.glassProminent)
      } else {
        self.buttonStyle(.glass)
      }
    } else {
      if isSelected {
        self.buttonStyle(.borderedProminent)
      } else {
        self.buttonStyle(.bordered)
      }
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
