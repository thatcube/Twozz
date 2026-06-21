import SwiftUI

/// Top Shelf diagnostics panel: shows the snapshot status for the stream cards
/// rendered above the app on the Home screen, with a republish action.
struct SettingsTopShelfSection: View {
  var onRepublishTopShelf: () -> Void = {}

  @State private var topShelfStatus = TopShelfStore.diagnosticsSummary()

  var body: some View {
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
