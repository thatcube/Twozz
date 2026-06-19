import SwiftUI

/// Shared glass card surface used by reusable browsing/channel cards.
/// Uses native Liquid Glass on modern tvOS and a lightweight fallback on older
/// versions.
struct TwizzLiquidGlassCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  let isFocused: Bool
  let palette: ThemePalette
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

    if #available(tvOS 26.0, *), isFocused || glassWhenUnfocused {
      content
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
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
