import SwiftUI

/// Shared building blocks for the Settings screen sections. These were factored
/// out of `SettingsView` so each section can live in its own file while keeping
/// the exact same controls, layout, focus behavior, and styling.

// MARK: - Setting row

/// A single preference row: fixed-width label column on the left, a
/// horizontal run of selectable pills on the right.
struct SettingRow<Content: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder var content: () -> Content

  private let labelColumnWidth: CGFloat = 500

  var body: some View {
    HStack(alignment: .center, spacing: 32) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 32, weight: .bold))
        if let subtitle {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(width: labelColumnWidth, alignment: .leading)

      HStack(spacing: 16) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
  }
}

// MARK: - Selectable option pill

/// Compact label used inside a setting row. Focus is handled by the native
/// Liquid Glass button style; the active option is marked with a trailing
/// checkmark (reserved width so pills stay aligned), matching the tvOS
/// Settings selection idiom.
struct SettingPill: View {
  let title: String
  var subtitle: String? = nil
  let isSelected: Bool
  /// When true the pill is a dropdown trigger (a `Menu` label), so it shows a
  /// trailing up/down selector chevron instead of the selection checkmark slot.
  var showsMenuIndicator: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }

      if showsMenuIndicator {
        Icon(glyph: .selector, size: 40)
      } else if isSelected {
        Icon(glyph: .check, size: 26)
      }
    }
  }
}

// MARK: - Native styling helpers

extension View {
  /// Frosted Liquid Glass panel (tvOS 26+) with a material fallback.
  @ViewBuilder
  func settingsGlassPanel(disabled: Bool) -> some View {
    modifier(SettingsGlassPanelModifier(disabled: disabled))
  }

  /// Selectable option styling. Applies a single native button style
  /// **unconditionally** (it ignores `isSelected` for styling), so the active
  /// option is indicated only by `SettingPill`'s trailing checkmark — matching
  /// the tvOS Settings idiom and giving the genuine native focus state.
  ///
  /// Why not vary the style by selection: swapping styles (e.g. `.glass` ↔
  /// `.glassProminent`) changes the view's identity, so toggling an option
  /// destroys the focused pill and tvOS snaps focus back to the first item.
  /// Keeping one stable style preserves identity, so focus stays put.
  @ViewBuilder
  func settingPillStyle(isSelected _: Bool) -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.bordered)
    }
  }

  /// Prominent action button: Liquid Glass prominent on tvOS 26+, bordered
  /// prominent otherwise.
  @ViewBuilder
  func settingsProminentActionButtonStyle() -> some View {
    if #available(tvOS 26.0, *) {
      self.buttonStyle(.glassProminent)
    } else {
      self.buttonStyle(.borderedProminent)
    }
  }
}

/// Backs the Settings section panels. When transparency is reduced (`disabled`)
/// the panel becomes opaque — but it must follow the active theme rather than the
/// shared near-black `twozzOpaqueGlass`, so the Light theme stays light instead of
/// darkening just because transparency was turned off. Dark/OLED resolve to the
/// same near-black fill + hairline as before, so they are unchanged.
private struct SettingsGlassPanelModifier: ViewModifier {
  let disabled: Bool
  @Environment(\.themePalette) private var palette

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    if disabled {
      content
        .background(palette.cardOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.cardOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content.background(.ultraThinMaterial, in: shape)
    }
  }
}
