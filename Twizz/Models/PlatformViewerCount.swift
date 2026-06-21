import SwiftUI

/// One platform's concurrent viewer count for a stream the creator is *currently
/// live on*. Shared by the Home stream card (which sums these into a single
/// combined total) and the player (which lays them out side by side with each
/// platform's logo), so the "which platforms are live, and how many are watching"
/// logic lives in one place instead of being re-derived per surface.
///
/// A platform is only represented here when the creator is live on it *and* a
/// count is known — so neither surface can ever show a count for a platform the
/// creator isn't live on.
struct PlatformViewerCount: Identifiable, Hashable {
  enum Platform: String, Hashable, CaseIterable {
    case twitch, youtube, kick

    /// The brand glyph that prefixes the count in the player's side-by-side row.
    var glyph: Glyph {
      switch self {
      case .twitch: return .brandTwitch
      case .youtube: return .brandYoutube
      case .kick: return .brandKick
      }
    }

    /// Brand tint for the logo glyph. Only used over the player's always-dark
    /// video scrim (over-video chrome, like the existing viewer readout), never
    /// on a themed panel — so a fixed brand color is the correct choice here.
    var tint: Color {
      switch self {
      case .twitch: return Color(red: 0.57, green: 0.27, blue: 1.00)
      case .youtube: return Color(red: 1.00, green: 0.00, blue: 0.00)
      case .kick: return Color(red: 0.33, green: 0.85, blue: 0.13)
      }
    }

    /// Spoken platform name for VoiceOver ("… watching on Twitch").
    var accessibilityName: String {
      switch self {
      case .twitch: return "Twitch"
      case .youtube: return "YouTube"
      case .kick: return "Kick"
      }
    }
  }

  let platform: Platform
  let count: Int

  var id: Platform { platform }
}

extension Array where Element == PlatformViewerCount {
  /// Combined viewers across every live platform, or `nil` when none is known —
  /// the single total the Home stream card shows.
  var combinedViewerTotal: Int? {
    isEmpty ? nil : reduce(0) { $0 + $1.count }
  }
}
