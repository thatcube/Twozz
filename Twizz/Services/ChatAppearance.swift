import CoreGraphics
import Foundation
import SwiftUI

/// Numeric, independently-tunable chat appearance values. These are the source
/// of truth persisted via `@AppStorage`; the size presets and the migration
/// from the older enum-based settings both resolve to values here.
enum ChatAppearance {

  // MARK: - Bounds & steps (Advanced allows a wider, more expressive range)

  /// Body/name font point size.
  static let textSizeRange: ClosedRange<CGFloat> = 16...44
  static let textSizeStep: CGFloat = 2

  /// Explicit emote height when not tracking the text size.
  static let emoteSizeRange: ClosedRange<CGFloat> = 18...96
  static let emoteSizeStep: CGFloat = 2

  /// Extra spacing applied *within* a wrapped message line.
  static let lineHeightRange: ClosedRange<CGFloat> = -8...16
  static let lineHeightStep: CGFloat = 1

  /// Extra spacing inserted *between characters* (tracking). A readability aid —
  /// looser character spacing is one of the more evidence-backed dyslexia aids.
  /// Negative values tighten the text for users who prefer denser lines; the
  /// floor stops short of the point where glyphs collide and become illegible.
  static let letterSpacingRange: ClosedRange<CGFloat> = -5...12
  static let letterSpacingStep: CGFloat = 1

  /// Vertical gap *between* messages.
  static let messageSpacingRange: ClosedRange<CGFloat> = 0...32
  static let messageSpacingStep: CGFloat = 2

  /// Continuous docked-chat width.
  static let widthRange: ClosedRange<CGFloat> = 300...820
  static let widthStep: CGFloat = 20

  // MARK: - Defaults (a fresh install lands on the "Normal" preset)

  static let defaultTextSize: CGFloat = 26
  static let defaultLineHeight: CGFloat = -1
  static let defaultLetterSpacing: CGFloat = 0
  static let defaultMessageSpacing: CGFloat = 14
  static let defaultWidth: CGFloat = 460
  static let defaultEmoteAuto = true
  static let defaultEmoteSize: CGFloat = 34
  static let defaultAnimatedEmotes = true
  static let defaultFontStyle = ChatFontStyle.standard
  static let defaultShowBadges = true
  static let defaultShowPlatformBadges = true

  // MARK: - Derived values

  /// Emote height when tracking the text size (Auto mode). Reproduces the prior
  /// text→emote ratio (e.g. 26pt text → ~34pt emote).
  static func autoEmoteHeight(forTextSize textSize: CGFloat) -> CGFloat {
    (textSize * 1.3).rounded()
  }

  /// Username/badge glyph size, derived from the text size.
  static func badgeSize(forTextSize textSize: CGFloat) -> CGFloat {
    max(16, (textSize * 0.85).rounded())
  }

  /// Horizontal inset of the message list, derived from the text size.
  static func horizontalPadding(forTextSize textSize: CGFloat) -> CGFloat {
    max(16, textSize - 2)
  }

  /// Vertical inset of the message list, derived from the message spacing.
  static func verticalPadding(forMessageSpacing spacing: CGFloat) -> CGFloat {
    spacing + 4
  }

  /// Snap an arbitrary value to the nearest step within a range.
  static func snap(_ value: CGFloat, to range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    guard step > 0 else { return clamped }
    let steps = ((clamped - range.lowerBound) / step).rounded()
    return min(range.lowerBound + steps * step, range.upperBound)
  }
}

/// The readability "size" presets surfaced on the main settings page. They drive
/// only the text/emote/line-height/message-spacing cluster; chat width and
/// position are independent. Selecting a preset stamps its values; editing any
/// individual value flips the resolved preset to `nil` ("Custom").
enum ChatAppearancePreset: String, CaseIterable, Identifiable {
  case small
  case normal
  case large

  var id: String { rawValue }

  var title: String {
    switch self {
    case .small: return "Small"
    case .normal: return "Normal"
    case .large: return "Large"
    }
  }

  /// Text/line-height/message-spacing values for this preset. Emote size is
  /// always Auto for a clean preset (an explicit emote override reads as Custom).
  var values: (textSize: CGFloat, lineHeight: CGFloat, messageSpacing: CGFloat) {
    switch self {
    case .small:  return (22, -2, 10)
    case .normal: return (26, -1, 14)
    case .large:  return (30, 2, 16)
    }
  }

  /// Returns the preset matching the supplied values, or `nil` for "Custom".
  static func resolve(
    textSize: CGFloat,
    lineHeight: CGFloat,
    messageSpacing: CGFloat,
    emoteIsAuto: Bool
  ) -> ChatAppearancePreset? {
    guard emoteIsAuto else { return nil }
    return allCases.first { preset in
      let v = preset.values
      return v.textSize == textSize
        && v.lineHeight == lineHeight
        && v.messageSpacing == messageSpacing
    }
  }
}

/// Selectable typeface for chat text. Most options map onto SwiftUI's built-in
/// system font designs (which ship with the OS and scale cleanly at any size on
/// tvOS); `openDyslexic` is the one exception and resolves to the bundled
/// OpenDyslexic typeface — a face designed for readers with dyslexia, with
/// weighted letter bottoms so glyphs are harder to visually flip or rotate.
enum ChatFontStyle: String, CaseIterable, Identifiable {
  case standard
  case rounded
  case serif
  case monospaced
  case openDyslexic

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: return "Standard"
    case .rounded: return "Rounded"
    case .serif: return "Serif"
    case .monospaced: return "Mono"
    case .openDyslexic: return "Dyslexic"
    }
  }

  /// The bundled font family name, or `nil` for the system-design options.
  /// Both the Regular and Bold faces are registered under this family, so a
  /// `.weight(.bold)` request resolves to the matching face.
  private var customFontName: String? {
    switch self {
    case .openDyslexic: return "OpenDyslexic"
    default: return nil
    }
  }

  /// System font design backing the standard/rounded/serif/mono options.
  /// `openDyslexic` ships its own face, so this is only a fallback for it.
  var design: Font.Design {
    switch self {
    case .standard, .openDyslexic: return .default
    case .rounded: return .rounded
    case .serif: return .serif
    case .monospaced: return .monospaced
    }
  }

  /// Visual-size correction so switching typefaces doesn't jump in size.
  /// OpenDyslexic renders noticeably larger than the system fonts at the same
  /// point size (large x-height, heavy forms), so it's scaled down to roughly
  /// match; the system designs are already consistent with each other.
  var sizeMultiplier: CGFloat {
    switch self {
    case .openDyslexic: return 0.82
    default: return 1
    }
  }

  /// Resolve the concrete `Font` for chat text at a given size/weight. Custom
  /// (bundled) families go through `Font.custom` so they scale like the system
  /// options; everything else uses the matching system design. The size is
  /// pre-corrected by `sizeMultiplier` so each typeface lands at a comparable
  /// visual size.
  func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let resolvedSize = size * sizeMultiplier
    if let customFontName {
      return Font.custom(customFontName, size: resolvedSize).weight(weight)
    }
    return .system(size: resolvedSize, weight: weight, design: design)
  }
}

/// One-time migration from the legacy enum-based chat settings
/// (`chatTextSize`/`chatLineHeight`/`chatLineSpacing`/`chatWidthMode`) to the new
/// numeric `@AppStorage` keys, preserving each user's exact prior look. Brand-new
/// installs skip this and fall through to the numeric defaults (the Normal preset).
enum ChatAppearanceMigration {
  private static let flagKey = "chatAppearanceMigratedV1"

  static func runIfNeeded(_ defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: flagKey) else { return }
    defaults.set(true, forKey: flagKey)

    // Only migrate when the new keys are absent, so we never clobber values the
    // user has already set through the new UI.
    if defaults.object(forKey: "chatTextSizeValue") == nil,
      let raw = defaults.string(forKey: "chatTextSize") {
      let value: CGFloat
      switch raw {
      case "small": value = 22
      case "large": value = 28
      default: value = 26
      }
      defaults.set(Double(value), forKey: "chatTextSizeValue")
    }

    if defaults.object(forKey: "chatLineHeightValue") == nil,
      let raw = defaults.string(forKey: "chatLineHeight") {
      let value: CGFloat
      switch raw {
      case "tight": value = -1
      case "relaxed": value = 6
      default: value = 2
      }
      defaults.set(Double(value), forKey: "chatLineHeightValue")
    }

    if defaults.object(forKey: "chatMessageSpacingValue") == nil,
      let raw = defaults.string(forKey: "chatLineSpacing") {
      let value: CGFloat
      switch raw {
      case "tight": value = 6
      case "relaxed": value = 14
      default: value = 10
      }
      defaults.set(Double(value), forKey: "chatMessageSpacingValue")
    }

    if defaults.object(forKey: "chatWidthValue") == nil,
      let raw = defaults.string(forKey: "chatWidthMode") {
      let value: CGFloat
      switch raw {
      case "narrow": value = 380
      case "wide": value = 560
      case "extraWide": value = 680
      default: value = 460
      }
      defaults.set(Double(value), forKey: "chatWidthValue")
    }
  }
}
