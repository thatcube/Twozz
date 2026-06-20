import SwiftUI

/// Shared glass card surface used by reusable browsing/channel cards.
/// Uses native Liquid Glass on modern tvOS and a lightweight fallback on older
/// versions.
struct TwizzLiquidGlassCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  let isFocused: Bool
  let palette: ThemePalette
  @Environment(\.glassDisabled) private var glassDisabled
  /// When false, the live Liquid Glass material is rendered only while the card
  /// is focused; unfocused cards fall back to a cheap translucent fill. Each
  /// `.glassEffect` is a real-time backdrop sample, so on dense screens (e.g. the
  /// channel page's clip/VOD rails, where 6–8 tiles are visible at once and all
  /// re-sample the moving backdrop on scroll) keeping glass on every tile is a
  /// major source of GPU overdraw. Defaults to true to preserve existing visuals
  /// everywhere else in the app.
  var glassWhenUnfocused: Bool = true

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if glassDisabled {
      // Reduce Transparency: opaque, high-contrast fill instead of glass.
      content
        .background {
          shape.fill(isFocused ? palette.liftSurface : palette.cardOpaqueSurface)
        }
        .overlay {
          shape.strokeBorder(isFocused ? Color.clear : palette.cardOpaqueBorder, lineWidth: 1)
        }
        .clipShape(shape)
    } else if #available(tvOS 26.0, *), isFocused || glassWhenUnfocused {
      content
        .glassEffect(
          isFocused ? .regular.tint(palette.focusedCardGlassTint) : .regular,
          in: .rect(cornerRadius: cornerRadius)
        )
        .background {
          // A focused card casts a drop shadow. In Light mode the translucent
          // glass lets that shadow bleed *through* the surface, reading as a
          // muddy haze inside the card instead of a clean lift. Give the focused
          // Light-theme card an opaque backing so the shadow stays behind it.
          // Dark/OLED don't show this, so they keep the pure translucent glass.
          if isFocused && palette.isLight {
            shape.fill(palette.cardOpaqueSurface)
          }
        }
        .clipShape(shape)
    } else {
      content
        .background {
          shape.fill(isFocused ? palette.liftSurface : Color.primary.opacity(0.07))
        }
        .overlay {
          shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(shape)
    }
  }
}

extension View {
  func twizzLiquidGlassCard(cornerRadius: CGFloat, isFocused: Bool, palette: ThemePalette, glassWhenUnfocused: Bool = true) -> some View {
    modifier(
      TwizzLiquidGlassCardModifier(
        cornerRadius: cornerRadius,
        isFocused: isFocused,
        palette: palette,
        glassWhenUnfocused: glassWhenUnfocused
      )
    )
  }
}

/// Whether a focused card should paint its text in the palette's opaque "lift"
/// colors (which pair with the opaque `liftSurface` fill) instead of the
/// translucent-glass `Color.primary`/`.secondary`. True whenever a focused card
/// is rendering an opaque surface: glass is disabled (the in-app toggle OR the OS
/// Reduce Transparency setting, unioned into `glassDisabled`), or the platform
/// predates Liquid Glass. Shared by every card so the three copies can't drift.
func twizzUsesLiftFocusedText(isFocused: Bool, glassDisabled: Bool) -> Bool {
  guard isFocused else { return false }
  if glassDisabled { return true }
  if #available(tvOS 26.0, *) { return false }
  return true
}
