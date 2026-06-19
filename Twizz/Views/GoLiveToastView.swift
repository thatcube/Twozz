import SwiftUI

/// Interactive "just went live" toast. Presentational only: the caller positions
/// it (top-trailing), so the same view serves both Home and the player without
/// depending on either's focus model.
///
/// The toast takes focus on its `Watch` button when it appears — mirroring the
/// raid banner — so the viewer can act with a single press instead of hunting
/// for it. The owner's auto-dismiss countdown keeps running regardless, so an
/// ignored toast still clears itself.
struct GoLiveToastView: View {
  let event: GoLiveEvent
  /// Invoked when the viewer presses `Watch`.
  let onWatch: () -> Void

  @FocusState private var watchFocused: Bool

  /// Large channel avatar; the toast's height tracks it (avatar + equal inset).
  private let avatarSize: CGFloat = 76
  /// Equal gap between the avatar and the toast's top, bottom, and leading edges.
  private let avatarInset: CGFloat = 16

  var body: some View {
    HStack(spacing: 16) {
      avatar

      VStack(alignment: .leading, spacing: 2) {
        Text(event.headline)
          .font(.headline).bold()
          .foregroundStyle(.primary)
        if let subtitle = event.subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Button(action: onWatch) {
        HStack(spacing: 10) {
          Icon(glyph: .playerPlayFilled, size: 22)
          Text("Watch")
        }
        .font(.headline)
      }
      .buttonStyle(.borderedProminent)
      .focused($watchFocused)
    }
    .padding(.leading, avatarInset)
    .padding(.vertical, avatarInset)
    .padding(.trailing, 24)
    .background {
      if #available(tvOS 26.0, *) {
        Capsule().glassEffect(.regular, in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    .task {
      // Let the move/opacity transition settle before claiming focus, so tvOS
      // reliably lands on the button instead of dropping the request mid-animation.
      try? await Task.sleep(for: .milliseconds(350))
      watchFocused = true
    }
  }

  private var avatar: some View {
    CachedAsyncImage(url: event.profileImageURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Circle().fill(.ultraThinMaterial)
        Icon(glyph: .broadcast, size: avatarSize * 0.45)
          .foregroundStyle(.red)
      }
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
  }
}
