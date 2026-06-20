import Foundation

/// Global, user-adjustable size for stream cards shown across the app
/// (the Home rails and the Browse streams grid). Fewer visible cards per
/// row means each card is rendered larger.
///
/// Persisted under ``StreamCardSize/storageKey`` and read in every surface
/// that lays out stream cards, so changing it anywhere updates the whole app.
enum StreamCardSize: String, CaseIterable, Identifiable {
  case extraLarge
  case large
  case medium
  case small
  case extraSmall

  var id: String { rawValue }

  var title: String {
    switch self {
    case .extraLarge: return "Extra Large"
    case .large: return "Large"
    case .medium: return "Medium"
    case .small: return "Small"
    case .extraSmall: return "Extra Small"
    }
  }

  /// Target number of cards visible across the available width. Fewer cards
  /// => bigger cards.
  var visibleCardCount: Int {
    switch self {
    case .extraLarge: return 2
    case .large: return 3
    case .medium: return 4
    case .small: return 5
    case .extraSmall: return 6
    }
  }

  /// Short descriptor used as a secondary label (e.g. "3 across").
  var subtitle: String {
    "\(visibleCardCount) across"
  }

  var symbolName: String {
    switch self {
    case .extraLarge: return "rectangle"
    case .large: return "rectangle.grid.1x2"
    case .medium: return "square.grid.2x2"
    case .small: return "square.grid.3x3"
    case .extraSmall: return "square.grid.4x3.fill"
    }
  }

  /// `UserDefaults`/`@AppStorage` key shared by every surface.
  static let storageKey = "streamCardSize"

  /// Default used when no preference has been saved.
  static let fallback: StreamCardSize = .large

  static func resolve(_ rawValue: String) -> StreamCardSize {
    StreamCardSize(rawValue: rawValue) ?? .fallback
  }
}
