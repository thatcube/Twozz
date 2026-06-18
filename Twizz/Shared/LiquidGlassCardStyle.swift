import SwiftUI

/// Shared glass card surface used by reusable browsing/channel cards.
/// Uses native Liquid Glass on modern tvOS and a lightweight fallback on older
/// versions.
struct TwizzLiquidGlassCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  let isFocused: Bool
  let palette: ThemePalette

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if #available(tvOS 26.0, *) {
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
  func twizzLiquidGlassCard(cornerRadius: CGFloat, isFocused: Bool, palette: ThemePalette) -> some View {
    modifier(
      TwizzLiquidGlassCardModifier(
        cornerRadius: cornerRadius,
        isFocused: isFocused,
        palette: palette
      )
    )
  }
}
