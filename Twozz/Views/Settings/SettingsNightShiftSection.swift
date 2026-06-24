import SwiftUI

/// Night Shift group: a warm, f.lux-style screen wash that fades in after sunset
/// and out before sunrise, based on the viewer's chosen region. tvOS can't warm
/// the system display, so this tints the app's own content (player included).
struct SettingsNightShiftSection: View {
  @Environment(AppEnvironment.self) private var environment
  private var nightShift: NightShiftManager { environment.nightShift }

  @Environment(\.glassDisabled) private var glassDisabled

  /// Which control currently holds focus. Focusing Dimness or Warmth flips the
  /// overlay to full strength so the change is visible live as you pick options;
  /// other controls leave the live schedule untouched.
  private enum NSControl: Hashable { case location, dimness, warmth, preview }
  @FocusState private var focusedControl: NSControl?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingRow(
        title: "Night Shift",
        subtitle: nightShift.scheduleSummary()
      ) {
        ForEach([true, false], id: \.self) { on in
          Button {
            nightShift.isEnabled = on
          } label: {
            SettingPill(title: on ? "On" : "Off", isSelected: nightShift.isEnabled == on)
          }
          .settingPillStyle(isSelected: nightShift.isEnabled == on)
        }
      }
      .padding(.vertical, 16)

      if nightShift.isEnabled {
        groupDivider

        HStack(alignment: .bottom, spacing: 36) {
          labeledMenu("Location", value: nightShift.region.name, focus: .location) { regionPicker }
          labeledMenu("Dimness", value: nightShift.dimness.displayName, focus: .dimness) { dimnessPicker }
          labeledMenu("Warmth", value: nightShift.warmth.displayName, focus: .warmth) { warmthPicker }

          Spacer(minLength: 24)

          DayNightDial(
            intensity: nightShift.currentIntensity,
            progress: nightShift.previewProgress
          )
          .frame(width: 120, height: 64)

          previewButton
        }
        .padding(.vertical, 16)
        .focusSection()
      }
    }
    .padding(.horizontal, 28)
    .settingsGlassPanel(disabled: glassDisabled)
    .onChange(of: focusedControl) { _, control in
      switch control {
      case .dimness, .warmth:
        nightShift.isPreviewing = true
      case .location, .preview:
        nightShift.isPreviewing = false
      case nil:
        break  // transient (e.g. a menu is open) — keep the current preview state
      }
    }
    .onDisappear { nightShift.isPreviewing = false }
  }

  /// Compact "fast-forward a day" trigger; the simulated clock replaces the label
  /// while a sweep is running.
  private var previewButton: some View {
    Button {
      nightShift.runDayNightPreview()
    } label: {
      Text(nightShift.previewProgress == nil ? "Preview a day" : nightShift.previewClockText)
        .font(.headline)
        .monospacedDigit()
        .frame(minWidth: 150, alignment: .leading)
    }
    .settingsProminentActionButtonStyle()
    .focused($focusedControl, equals: .preview)
  }

  /// A small inline label paired with its dropdown trigger, used to pack Location,
  /// Dimness, and Warmth onto a single line. `focus` ties the trigger into the
  /// section's focus tracking so Dimness/Warmth can drive the live preview.
  private func labeledMenu<Content: View>(
    _ label: String,
    value: String,
    focus: NSControl,
    @ViewBuilder picker: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.secondary)
      Menu {
        picker()
      } label: {
        SettingPill(title: value, isSelected: false, showsMenuIndicator: true)
      }
      .settingsProminentActionButtonStyle()
      .focused($focusedControl, equals: focus)
    }
  }

  private var regionPicker: some View {
    Picker("Location", selection: regionSelection) {
      ForEach(NightShiftRegion.sortedCatalog) { region in
        Text(region.name).tag(region.id)
      }
    }
    .pickerStyle(.inline)
  }

  private var dimnessPicker: some View {
    Picker("Dimness", selection: dimnessSelection) {
      ForEach(NightShiftDimness.allCases) { level in
        Text(level.displayName).tag(level)
      }
    }
    .pickerStyle(.inline)
  }

  private var warmthPicker: some View {
    Picker("Warmth", selection: warmthSelection) {
      ForEach(NightShiftWarmth.allCases) { level in
        Text(level.displayName).tag(level)
      }
    }
    .pickerStyle(.inline)
  }

  private var groupDivider: some View {
    Divider()
      .overlay(Color.primary.opacity(0.12))
  }

  private var dimnessSelection: Binding<NightShiftDimness> {
    Binding(
      get: { nightShift.dimness },
      set: { nightShift.dimness = $0 }
    )
  }

  private var warmthSelection: Binding<NightShiftWarmth> {
    Binding(
      get: { nightShift.warmth },
      set: { nightShift.warmth = $0 }
    )
  }

  private var regionSelection: Binding<String> {
    Binding(
      get: { nightShift.regionID },
      set: { nightShift.regionID = $0 }
    )
  }
}

// MARK: - Day/night preview dial

/// A tiny self-contained sky: a sun arcs across by day and a moon by night, with
/// the sky colour shifting day → sunset → night to mirror the actual Night Shift
/// intensity. `progress` (0…1) places the celestial body horizontally across the
/// simulated day; when nil (idle) it rests mid-arc.
private struct DayNightDial: View {
  /// 0 = full daylight, 1 = deep night. Drives sky colour + sun vs. moon.
  var intensity: Double
  /// 0…1 sweep position; nil when no preview is running.
  var progress: Double?

  private static let dayTop = (0.40, 0.68, 0.95)
  private static let dayBottom = (0.72, 0.86, 0.99)
  private static let duskTop = (0.86, 0.46, 0.30)
  private static let duskBottom = (0.99, 0.72, 0.38)
  private static let nightTop = (0.03, 0.05, 0.14)
  private static let nightBottom = (0.10, 0.13, 0.26)

  var body: some View {
    let p = progress ?? 0.5
    let sky = skyColors()
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let bodySize = h * 0.34
      let starSize = max(2.0, h * 0.045)
      let x = w * p
      let y = h * (0.84 - 0.58 * sin(.pi * p))
      let isNight = intensity > 0.5
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(colors: [sky.top, sky.bottom], startPoint: .top, endPoint: .bottom)
          )

        if intensity > 0.55 {
          ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
            Circle()
              .fill(.white.opacity(0.75))
              .frame(width: starSize, height: starSize)
              .position(x: w * star.0, y: h * star.1)
          }
        }

        Circle()
          .fill(isNight ? Color(.sRGB, red: 0.92, green: 0.94, blue: 1.0)
                        : Color(.sRGB, red: 1.0, green: 0.86, blue: 0.34))
          .frame(width: bodySize, height: bodySize)
          .shadow(
            color: (isNight ? Color.white : Color(.sRGB, red: 1.0, green: 0.8, blue: 0.3)).opacity(0.6),
            radius: 6
          )
          .position(x: x, y: y)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .animation(.linear(duration: 0.06), value: progress)
  }

  private static let stars: [(Double, Double)] = [(0.24, 0.30), (0.55, 0.48), (0.79, 0.26)]

  private func skyColors() -> (top: Color, bottom: Color) {
    let i = max(0, min(1, intensity))
    let top: (Double, Double, Double)
    let bottom: (Double, Double, Double)
    if i <= 0.5 {
      let t = i / 0.5
      top = lerp(Self.dayTop, Self.duskTop, t)
      bottom = lerp(Self.dayBottom, Self.duskBottom, t)
    } else {
      let t = (i - 0.5) / 0.5
      top = lerp(Self.duskTop, Self.nightTop, t)
      bottom = lerp(Self.duskBottom, Self.nightBottom, t)
    }
    return (color(top), color(bottom))
  }

  private func color(_ rgb: (Double, Double, Double)) -> Color {
    Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2)
  }

  private func lerp(
    _ a: (Double, Double, Double),
    _ b: (Double, Double, Double),
    _ t: Double
  ) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
  }
}
