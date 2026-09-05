import SwiftUI

/// Circadian Mode: a warm, f.lux-style screen tint that can follow sunset or a
/// manual schedule. The controls are arranged as compact vertical rows so the
/// pane stays legible at TV distance and never depends on one very wide line.
struct SettingsNightShiftSection: View {
  @Environment(AppEnvironment.self) private var environment
  private var nightShift: NightShiftManager { environment.nightShift }

  private let controlHeight: CGFloat = 44
  private let rowLabelWidth: CGFloat = 150

  private enum NSControl: Hashable {
    case location
    case onDown, onUp
    case offDown, offUp
    case fadeDown, fadeUp
    case dimnessDown, dimnessUp
    case warmthDown, warmthUp
    case preview

    /// True for the Dimness/Warmth stepper arrows, which drive the live preview.
    var previewsLive: Bool {
      switch self {
      case .dimnessDown, .dimnessUp, .warmthDown, .warmthUp: return true
      default: return false
      }
    }
  }

  private enum CircadianMode: CaseIterable, Hashable {
    case off
    case auto
    case manual

    var title: LocalizedStringResource {
      switch self {
      case .off: "Off"
      case .auto: "Auto"
      case .manual: "Manual"
      }
    }

    var detail: LocalizedStringResource {
      switch self {
      case .off: "The picture is never dimmed or warmed."
      case .auto: "Follows sunset and sunrise for your selected location."
      case .manual: "Runs between the times you choose each day."
      }
    }
  }

  @FocusState private var focusedControl: NSControl?
  @FocusState private var focusedMode: CircadianMode?

  private var mode: CircadianMode {
    guard nightShift.isEnabled else { return .off }
    return nightShift.scheduleMode == .solar ? .auto : .manual
  }

  private var describedMode: CircadianMode {
    focusedMode ?? mode
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 54) {
      VStack(alignment: .leading, spacing: 18) {
        ChatFlowLayout(itemSpacing: 14, rowSpacing: 12) {
          ForEach(CircadianMode.allCases, id: \.self) { option in
            Button {
              selectMode(option)
            } label: {
              HStack(spacing: 10) {
                Text(option.title)
                  .font(.body.weight(.medium))
                if mode == option {
                  Icon(glyph: .check, size: 24)
                }
              }
            }
            .settingPillStyle(isSelected: mode == option)
            .focused($focusedMode, equals: option)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        Text(describedMode.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.opacity)
          .frame(maxWidth: 720, alignment: .leading)
      }

      if nightShift.isEnabled {
        VStack(alignment: .leading, spacing: 24) {
          sectionHeader("Schedule")

          if nightShift.scheduleMode == .solar {
            controlRow("Location") {
              locationMenu
            }
          } else {
            controlRow("Turns On") {
              timeStepper(
                minutes: nightShift.manualOnMinutes,
                down: .onDown,
                up: .onUp,
                commit: { nightShift.manualOnMinutes = $0 }
              )
            }
            controlRow("Turns Off") {
              timeStepper(
                minutes: nightShift.manualOffMinutes,
                down: .offDown,
                up: .offUp,
                commit: { nightShift.manualOffMinutes = $0 }
              )
            }
          }

          controlRow("Fade") {
            stepper(
              levels: NightShiftManager.fadeOptions,
              selected: clampedFade,
              display: { NightShiftManager.fadeLabel(minutes: $0) },
              down: .fadeDown,
              up: .fadeUp,
              valueWidth: 90,
              commit: { nightShift.fadeMinutes = $0 }
            )
          }
        }

        VStack(alignment: .leading, spacing: 24) {
          sectionHeader("Appearance")

          controlRow("Darkness") {
            stepper(
              levels: NightShiftDimness.allCases,
              selected: nightShift.dimness,
              display: { $0.displayName },
              down: .dimnessDown,
              up: .dimnessUp,
              commit: { nightShift.dimness = $0 }
            )
          }

          controlRow("Warmth") {
            stepper(
              levels: NightShiftWarmth.allCases,
              selected: nightShift.warmth,
              display: { $0.displayName },
              down: .warmthDown,
              up: .warmthUp,
              commit: { nightShift.warmth = $0 }
            )
          }

          controlRow("Preview") {
            HStack(spacing: 24) {
              DayNightDial(
                intensity: nightShift.currentIntensity,
                progress: nightShift.previewProgress
              )
              .frame(width: 160, height: 84)

              previewButton
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: focusedControl) { _, control in
      nightShift.isPreviewing = control?.previewsLive ?? false
    }
    .onChange(of: nightShift.isEnabled) { _, enabled in
      if !enabled { nightShift.isPreviewing = false }
    }
    .onDisappear {
      nightShift.isPreviewing = false
    }
  }

  private func selectMode(_ newMode: CircadianMode) {
    switch newMode {
    case .off:
      nightShift.isEnabled = false
    case .auto:
      nightShift.isEnabled = true
      nightShift.scheduleMode = .solar
    case .manual:
      nightShift.isEnabled = true
      nightShift.scheduleMode = .manual
    }
  }

  /// `fadeMinutes` snapped to the nearest available preset, so the Fade stepper
  /// always has a valid index even if a persisted value falls between options.
  private var clampedFade: Int {
    NightShiftManager.fadeOptions.min(by: {
      abs($0 - nightShift.fadeMinutes) < abs($1 - nightShift.fadeMinutes)
    }) ?? 90
  }

  /// Compact "fast-forward a day" trigger; the simulated clock replaces the label
  /// while a sweep is running.
  private var previewButton: some View {
    Button {
      nightShift.runDayNightPreview()
    } label: {
      Text(nightShift.previewProgress == nil ? "Preview a day" : nightShift.previewClockText)
        .font(.body.weight(.medium))
        .monospacedDigit()
        .frame(height: controlHeight)
    }
    .settingPillStyle(isSelected: false)
    .focused($focusedControl, equals: .preview)
  }

  private var locationMenu: some View {
    Menu {
      regionPicker
    } label: {
      HStack(spacing: 12) {
        Text(nightShift.region.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Icon(glyph: .selector, size: 30)
      }
      .frame(maxWidth: 420, alignment: .leading)
      .frame(height: controlHeight)
    }
    .settingPillStyle(isSelected: false)
    .focused($focusedControl, equals: .location)
  }
  private func stepper<Level: Hashable>(
  private func stepper<Level: Hashable>(
    levels: [Level],
    selected: Level,
    display: (Level) -> String,
    down: NSControl,
    up: NSControl,
    valueWidth: CGFloat = 150,
    commit: @escaping (Level) -> Void
  ) -> some View {
    let index = levels.firstIndex(of: selected) ?? 0
    return HStack(spacing: 14) {
      stepArrow(.chevronLeft, focus: down, enabled: index > 0) {
        if index > 0 { commit(levels[index - 1]) }
      }
      stepperValue(display(selected), width: valueWidth)
      stepArrow(.chevronRight, focus: up, enabled: index < levels.count - 1) {
        if index < levels.count - 1 { commit(levels[index + 1]) }
      }
    }
  }

  private func timeStepper(
    minutes: Int,
    down: NSControl,
    up: NSControl,
    commit: @escaping (Int) -> Void
  ) -> some View {
    let step = NightShiftManager.manualStepMinutes
    return HStack(spacing: 14) {
      stepArrow(.chevronLeft, focus: down, enabled: true) {
        commit(wrappedMinutes(minutes - step))
      }
      stepperValue(nightShift.clockLabel(minutes: minutes), width: 150)
      stepArrow(.chevronRight, focus: up, enabled: true) {
        commit(wrappedMinutes(minutes + step))
      }
    }
  }

  private func wrappedMinutes(_ raw: Int) -> Int {
    ((raw % 1440) + 1440) % 1440
  }

  private func stepperValue(_ text: String, width: CGFloat) -> some View {
    Text(text)
      .font(.body.weight(.semibold))
      .lineLimit(1)
      .frame(minWidth: width)
      .frame(height: controlHeight)
  }

  /// One arrow of a stepper. Stays focusable at the ends (so focus — and any live
  /// preview — isn't lost when you reach Min/Max); it just dims and no-ops there.
  private func stepArrow(
    _ glyph: Glyph,
    focus: NSControl,
    enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Icon(glyph: glyph, size: 36)
        .frame(width: 40, height: controlHeight)
        .opacity(enabled ? 1 : 0.3)
    }
    .settingPillStyle(isSelected: false)
    .focused($focusedControl, equals: focus)
  }

  private func sectionHeader(_ title: LocalizedStringResource) -> some View {
    Text(title)
      .font(.subheadline.weight(.bold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .tracking(1.6)
  }

  private func controlRow<Content: View>(
    _ title: LocalizedStringResource,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 28) {
      Text(title)
        .font(.headline)
        .frame(width: rowLabelWidth, alignment: .leading)

      content()

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusSection()
  }

  private var regionPicker: some View {
    Picker("Location", selection: regionSelection) {
      ForEach(NightShiftRegion.sortedCatalog) { region in
        Text(region.name).tag(region.id)
      }
    }
    .pickerStyle(.inline)
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
