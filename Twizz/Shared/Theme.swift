import SwiftUI

// MARK: - AppLayout

/// Shared layout metrics so every screen lines up to the same gutters.
/// There should be no per-page horizontal padding overrides — use these.
enum AppLayout {
  /// The single horizontal page gutter shared by every top-level view.
  static let horizontalPadding: CGFloat = 24

  /// The single focus/hover zoom applied to every interactive content card
  /// (channels, categories, search results, etc.) so the scale is consistent
  /// everywhere instead of varying per surface.
  static let focusedCardScale: CGFloat = 1.07

  /// Shared focus/hover animation used by interactive cards.
  static var focusScaleAnimation: Animation? {
    return .easeOut(duration: 0.14)
  }
}

// MARK: - AppTheme

/// User-selectable appearance options exposed in Settings.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
  case system
  case dark
  case oled
  case light

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: return "System"
    case .dark: return "Dark"
    case .oled: return "OLED"
    case .light: return "Light"
    }
  }

  var symbolName: String {
    switch self {
    case .system: return "circle.lefthalf.filled"
    case .dark: return "moon.fill"
    case .oled: return "moon.stars.fill"
    case .light: return "sun.max.fill"
    }
  }

  /// Forced color scheme to hand SwiftUI. `nil` (System) follows the device.
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark, .oled: return .dark
    }
  }

  /// Resolves the concrete palette. When set to `.system`, the device's current
  /// scheme decides between the Dark (dark side) and Light palettes.
  func palette(systemColorScheme: ColorScheme) -> ThemePalette {
    switch self {
    case .system: return systemColorScheme == .dark ? .dark : .light
    case .dark: return .dark
    case .oled: return .oled
    case .light: return .light
    }
  }
}

// MARK: - ThemeManager

/// Persists the selected theme and broadcasts changes to the view tree.
@MainActor
@Observable
final class ThemeManager {
  private let storageKey = "appTheme"

  var theme: AppTheme {
    didSet { UserDefaults.standard.set(theme.rawValue, forKey: storageKey) }
  }

  init() {
    let raw = UserDefaults.standard.string(forKey: storageKey)
    theme = raw.flatMap(AppTheme.init(rawValue:)) ?? .system
  }
}

// MARK: - ThemePalette

/// The concrete colors a resolved theme paints with. Non-focused text and
/// surfaces lean on `Color.primary`/`.secondary` (which auto-invert via the
/// forced color scheme); the palette only needs to describe the background and
/// the "lifted" focused-card treatment that flips against the background.
struct ThemePalette: Equatable {
  /// Vertical background gradient stops for the main app chrome.
  let backgroundColors: [Color]
  /// Fill used behind a focused card (a strong contrast "lift").
  let liftSurface: Color
  /// Opaque fill behind an *unfocused* card when glass is disabled (Reduce
  /// Transparency / in-app toggle). Theme-aware so light mode stays white
  /// instead of falling back to the shared near-black `twizzOpaqueGlass`.
  let cardOpaqueSurface: Color
  /// Hairline border drawn around an unfocused opaque card so it reads against
  /// a same-colored background (e.g. white card on a white light-mode page).
  let cardOpaqueBorder: Color
  /// Primary text drawn on top of `liftSurface`.
  let liftPrimaryText: Color
  /// Secondary text drawn on top of `liftSurface`.
  let liftSecondaryText: Color
  /// Backdrop behind the video / side-chat letterbox in the player.
  let playerBackdrop: Color
  /// Background of the side-layout chat panel (only differs in light themes).
  let chatSideSurface: Color
  /// Primary message text on the side-layout chat panel.
  let chatSidePrimaryText: Color
  /// Optional brand-purple glow painted at the top-center of the app
  /// background. `nil` disables it (e.g. OLED stays pure black).
  let topGlow: Color?

  static let oled = ThemePalette(
    backgroundColors: [.black, .black],
    liftSurface: .white,
    cardOpaqueSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
    cardOpaqueBorder: Color.white.opacity(0.16),
    liftPrimaryText: .black.opacity(0.92),
    liftSecondaryText: .black.opacity(0.62),
    playerBackdrop: .black,
    chatSideSurface: Color(white: 0.07).opacity(0.96),
    chatSidePrimaryText: .white,
    topGlow: nil
  )

  static let dark = ThemePalette(
    backgroundColors: [
      Color(red: 0.13, green: 0.13, blue: 0.14),
      Color(red: 0.09, green: 0.09, blue: 0.10),
    ],
    liftSurface: .white,
    cardOpaqueSurface: Color(red: 0.10, green: 0.10, blue: 0.12),
    cardOpaqueBorder: Color.white.opacity(0.16),
    liftPrimaryText: .black.opacity(0.92),
    liftSecondaryText: .black.opacity(0.62),
    playerBackdrop: .black,
    chatSideSurface: Color(white: 0.07).opacity(0.96),
    chatSidePrimaryText: .white,
    topGlow: ThemePalette.brandPurple.opacity(0.075)
  )

  static let light = ThemePalette(
    backgroundColors: [
      Color(white: 1.0),
      Color(white: 0.97),
    ],
    liftSurface: .white,
    cardOpaqueSurface: .white,
    cardOpaqueBorder: Color.black.opacity(0.12),
    liftPrimaryText: .black.opacity(0.90),
    liftSecondaryText: .black.opacity(0.60),
    playerBackdrop: .white,
    chatSideSurface: Color(white: 1.0).opacity(0.98),
    chatSidePrimaryText: Color(white: 0.12),
    topGlow: ThemePalette.brandPurple.opacity(0.05)
  )

  /// Twitch brand purple (#9146FF).
  static let brandPurple = Color(red: 0.569, green: 0.275, blue: 1.0)
}

// MARK: - App background

/// The shared app background: a vertical base gradient with an optional,
/// very subtle brand-purple glow blooming from the top-center. The glow is
/// driven by `ThemePalette.topGlow`, so OLED (nil) renders pure black.
struct AppBackground: View {
  let palette: ThemePalette

  var body: some View {
    LinearGradient(
      colors: palette.backgroundColors,
      startPoint: .top,
      endPoint: .bottom
    )
    .overlay(alignment: .top) {
      if let glow = palette.topGlow {
        RadialGradient(
          gradient: Gradient(colors: [glow, .clear]),
          center: .top,
          startRadius: 0,
          endRadius: 820
        )
      }
    }
    .ignoresSafeArea()
  }
}

// MARK: - Environment plumbing

private struct ThemePaletteKey: EnvironmentKey {
  static let defaultValue: ThemePalette = .oled
}

extension EnvironmentValues {
  var themePalette: ThemePalette {
    get { self[ThemePaletteKey.self] }
    set { self[ThemePaletteKey.self] = newValue }
  }
}
