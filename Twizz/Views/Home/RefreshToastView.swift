import SwiftUI

/// State for the Home refresh toast: a brief pill that confirms a manual refresh
/// is happening / finished, so a re-tap of the Home tab gives visible feedback.
enum RefreshToastState {
  case refreshing
  case done
}

/// Small pill that confirms a manual Home refresh is happening / finished, so a
/// re-tap of the Home tab gives the viewer visible feedback.
struct RefreshToastView: View {
  let state: RefreshToastState
  @Environment(\.glassDisabled) private var glassDisabled

  var body: some View {
    HStack(spacing: 14) {
      switch state {
      case .refreshing:
        ProgressView()
          .scaleEffect(0.9)
        Text("Refreshing…")
      case .done:
        Icon(glyph: .circleCheckFilled, size: 30)
          .foregroundStyle(.green)
        Text("Refreshed")
      }
    }
    .font(.headline)
    .padding(.horizontal, 30)
    .padding(.vertical, 18)
    .background {
      if glassDisabled {
        Capsule().fill(Color.twizzOpaqueGlass)
          .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
      } else if #available(tvOS 26.0, *) {
        Capsule().glassEffect(.regular, in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
  }
}
