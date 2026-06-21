import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Footer panel showing app identity, version, open-source info, and a QR
/// code linking to the GitHub repo (tvOS has no browser, so a scannable code
/// is the way to hand a URL to a phone). Focusable so the tvOS focus engine
/// can scroll it into view at the bottom of the list.
struct SettingsAboutSection: View {
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
    .settingsGlassPanel(disabled: glassDisabled)
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
