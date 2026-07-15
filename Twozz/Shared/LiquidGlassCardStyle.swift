import SwiftUI
import UIKit

/// Shared glass card surface used by reusable browsing/channel cards.
/// Uses native Liquid Glass on modern tvOS and a lightweight fallback on older
/// versions.
struct TwozzLiquidGlassCardModifier: ViewModifier {
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

  /// tvOS 27 can hang SwiftUI's main thread when `.glassEffect` wraps focusable
  /// card content containing async images and text. Drawing glass on a clear
  /// background underlay avoids that layout loop while preserving real refraction.
  @available(tvOS 26.0, *)
  private func glassUnderlay() -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return Color.clear
      .glassEffect(
        isFocused ? .regular.tint(palette.focusedCardGlassTint) : .regular,
        in: .rect(cornerRadius: cornerRadius)
      )
      .background {
        if isFocused && palette.isLight {
          shape.fill(palette.cardOpaqueSurface)
        }
      }
  }

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
    } else if #available(tvOS 26.0, *) {
      content
        .background {
          if isFocused {
            glassUnderlay()
          } else if glassWhenUnfocused {
            shape.fill(.ultraThinMaterial)
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
  func twozzLiquidGlassCard(cornerRadius: CGFloat, isFocused: Bool, palette: ThemePalette, glassWhenUnfocused: Bool = true) -> some View {
    modifier(
      TwozzLiquidGlassCardModifier(
        cornerRadius: cornerRadius,
        isFocused: isFocused,
        palette: palette,
        glassWhenUnfocused: glassWhenUnfocused
      )
    )
  }

  /// Draws the same frosted hairline around every clipped artwork surface.
  func twozzMediaEdge(cornerRadius: CGFloat) -> some View {
    modifier(TwozzMediaEdgeModifier(cornerRadius: cornerRadius))
  }

  /// Plozz's borderless "Posters" focus treatment: a glass band blooms around
  /// the artwork without changing its layout footprint.
  func twozzFocusHalo(
    cornerRadius: CGFloat,
    focusScale: CGFloat,
    isFocused: Bool
  ) -> some View {
    modifier(
      TwozzFocusHaloModifier(
        cornerRadius: cornerRadius,
        focusScale: focusScale,
        isFocused: isFocused
      )
    )
  }
}

private struct TwozzMediaEdgeModifier: ViewModifier {
  let cornerRadius: CGFloat

  @Environment(\.themePalette) private var palette

  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .inset(by: -0.5)
        .stroke(mediaEdgeColor, lineWidth: 1.5)
    }
  }

  private var mediaEdgeColor: Color {
    let base = UIColor(palette.backgroundColors.last ?? .black)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let lift: CGFloat = 0.09
    return Color(
      red: Double(red + (1 - red) * lift),
      green: Double(green + (1 - green) * lift),
      blue: Double(blue + (1 - blue) * lift)
    )
  }
}

private struct TwozzFocusHaloModifier: ViewModifier {
  let cornerRadius: CGFloat
  let focusScale: CGFloat
  let isFocused: Bool

  @Environment(\.themePalette) private var palette

  func body(content: Content) -> some View {
    let inset = CardMetrics.focusHaloInset
    content
      .background {
        Color.clear
          .twozzLiquidGlassCard(
            cornerRadius: cornerRadius + inset,
            isFocused: true,
            palette: palette,
            glassWhenUnfocused: false
          )
          .padding(-inset)
          .shadow(
            color: .black.opacity(
              palette.isLight
                ? CardMetrics.focusShadowOpacityLight
                : CardMetrics.focusShadowOpacity
            ),
            radius: CardMetrics.focusShadowRadius,
            y: CardMetrics.focusShadowY
          )
          .opacity(isFocused ? 1 : 0)
      }
      .scaleEffect(isFocused ? focusScale : 1)
  }
}

/// Whether a focused card should paint its text in the palette's opaque "lift"
/// colors (which pair with the opaque `liftSurface` fill) instead of the
/// translucent-glass `Color.primary`/`.secondary`. True whenever a focused card
/// is rendering an opaque surface: glass is disabled (the in-app toggle OR the OS
/// Reduce Transparency setting, unioned into `glassDisabled`), or the platform
/// predates Liquid Glass. Shared by every card so the three copies can't drift.
func twozzUsesLiftFocusedText(isFocused: Bool, glassDisabled: Bool) -> Bool {
  guard isFocused else { return false }
  if glassDisabled { return true }
  if #available(tvOS 26.0, *) { return false }
  return true
}
