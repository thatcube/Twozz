import SwiftUI

// MARK: - Warmth

/// How warm (toward red) the picture is tinted. This is the *color* axis only —
/// it's independent of Dimness. Painted as a separate translucent warm layer
/// over the (already-dimmed) picture, so picking a warmer setting shifts the hue
/// without changing how dim the screen is. `none` skips the warm layer entirely
/// for people who only want a dimmer, neutral screen.
///
/// Discrete levels rather than a slider because pills are the tvOS-native,
/// remote-friendly idiom (raw sliders are awkward on the Siri Remote).
enum NightShiftWarmth: String, CaseIterable, Identifiable, Codable {
  case none
  case light
  case warm
  case warmer
  case warmest
  case onFire

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: return "None"
    case .light: return "Kinda Warm"
    case .warm: return "Warm"
    case .warmer: return "Toasty"
    case .warmest: return "Roasting"
    case .onFire: return "On Fire"
    }
  }

  /// Strength of the warm tint at the deepest point of night — how far the
  /// green/blue channels are scaled down by the multiply. Higher = deeper, more
  /// saturated.
  var peakOpacity: Double {
    switch self {
    case .none: return 0.0
    case .light: return 0.30
    case .warm: return 0.55
    case .warmer: return 0.80
    case .warmest: return 0.95
    case .onFire: return 1.0
    }
  }

  /// How aggressively green is pulled down relative to blue — i.e. the **hue**.
  /// Blue is always killed fully (`×(1−warm)`); green is killed at this fraction
  /// of that rate. A low value keeps lots of green → **orange/amber**; a high
  /// value strips green too → **red**. So the scale rides orange → orange-red →
  /// near-pure-red as you climb the levels.
  var greenKill: Double {
    switch self {
    case .none: return 0.0
    case .light: return 0.50
    case .warm: return 0.50
    case .warmer: return 0.65
    case .warmest: return 0.70
    case .onFire: return 1.0
    }
  }
}

// MARK: - Dimness

/// How much the screen is dimmed — the *brightness* axis, independent of Warmth.
/// Painted as a translucent **black** layer, which works like sunglasses
/// (`result ≈ content × (1 − amount)`): it pulls down the bright parts of the
/// picture while leaving black essentially black, so dark theme doesn't light up.
/// This is the closest thing to a real brightness reduction available on tvOS,
/// which exposes no backlight/brightness API to apps.
enum NightShiftDimness: String, CaseIterable, Identifiable, Codable {
  case none
  case subtle
  case medium
  case strong
  case intense
  case max

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: return "None"
    case .subtle: return "Low"
    case .medium: return "Sorta Dark"
    case .strong: return "Dark"
    case .intense: return "Squinting"
    case .max: return "Can't See"
    }
  }

  /// Peak black-layer opacity at the deepest point of night.
  var peakOpacity: Double {
    switch self {
    case .none: return 0.0
    case .subtle: return 0.38
    case .medium: return 0.55
    case .strong: return 0.72
    case .intense: return 0.84
    case .max: return 0.90
    }
  }
}

// MARK: - Schedule mode

/// How the on/off schedule is decided. `solar` follows the chosen region's
/// sunset/sunrise (the original behaviour); `manual` uses two fixed clock times
/// the viewer picks, in the device's local time zone.
enum NightShiftScheduleMode: String, CaseIterable, Identifiable, Codable {
  case solar
  case manual

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .solar: return "Auto"
    case .manual: return "Manual"
    }
  }
}

// MARK: - Manager

/// Owns the Night Shift settings and computes the live warm-wash color the
/// overlay paints. Like `ThemeManager`, it persists its selections to
/// `UserDefaults` and broadcasts changes via `@Observable`; a one-minute timer
/// nudges `tick` so the intensity re-evaluates as the evening progresses.
@MainActor
@Observable
final class NightShiftManager {
  /// How long the wash takes to fade fully in after the on-event / out before the
  /// off-event. User-adjustable via `fadeMinutes`; mirrors the gentle ramp
  /// f.lux/Night Shift use.
  private var transitionInterval: TimeInterval { Double(fadeMinutes) * 60 }

  /// The set of fade durations (in minutes) the UI steps through.
  static let fadeOptions: [Int] = [15, 30, 45, 60, 90, 120, 180, 240, 300]

  /// Minute granularity the manual on/off time steppers nudge by.
  static let manualStepMinutes = 15

  var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: PersistenceKey.nightShiftEnabled) }
  }

  var regionID: String {
    didSet { UserDefaults.standard.set(regionID, forKey: PersistenceKey.nightShiftRegion) }
  }

  var warmth: NightShiftWarmth {
    didSet { UserDefaults.standard.set(warmth.rawValue, forKey: PersistenceKey.nightShiftWarmth) }
  }

  var dimness: NightShiftDimness {
    didSet { UserDefaults.standard.set(dimness.rawValue, forKey: PersistenceKey.nightShiftDimness) }
  }

  /// Whether the on/off schedule follows the region's sun or fixed manual times.
  var scheduleMode: NightShiftScheduleMode {
    didSet { UserDefaults.standard.set(scheduleMode.rawValue, forKey: PersistenceKey.nightShiftScheduleMode) }
  }

  /// Manual "turns on" / "turns off" clock times, stored as minutes since local
  /// midnight (0…1439). Only consulted when `scheduleMode == .manual`.
  var manualOnMinutes: Int {
    didSet { UserDefaults.standard.set(manualOnMinutes, forKey: PersistenceKey.nightShiftManualOnMinutes) }
  }

  var manualOffMinutes: Int {
    didSet { UserDefaults.standard.set(manualOffMinutes, forKey: PersistenceKey.nightShiftManualOffMinutes) }
  }

  /// How many minutes the wash takes to ramp from off to full (and back).
  var fadeMinutes: Int {
    didSet { UserDefaults.standard.set(fadeMinutes, forKey: PersistenceKey.nightShiftFadeMinutes) }
  }

  /// When true (set while the Night Shift settings screen is visible), the ramp
  /// is bypassed and the overlay paints at full strength so the user can see and
  /// calibrate what their chosen Dimness/Warmth actually looks like at deep
  /// night, instead of the gated daytime/evening value.
  var isPreviewing: Bool = false

  /// Simulated clock driven by `runDayNightPreview()`. While non-nil it overrides
  /// the live time so the overlay sweeps a whole day → night → day in a few
  /// seconds. `previewProgress` (0…1) tracks how far through that sweep we are,
  /// for the settings dial animation.
  var previewDate: Date?
  var previewProgress: Double?
  private var previewTimer: Timer?
  private var previewStart: Date = .init()
  private var previewStep = 0
  private static let previewSteps = 180

  /// Bumped by the timer so time-derived values recompute. Reading it in a
  /// computed property is what ties the overlay's redraw to the clock.
  private var tick: Date = .init()
  private var timer: Timer?

  init() {
    let defaults = UserDefaults.standard
    isEnabled = defaults.bool(forKey: PersistenceKey.nightShiftEnabled)
    regionID = defaults.string(forKey: PersistenceKey.nightShiftRegion)
      ?? NightShiftRegion.guessFromCurrentTimeZone().id
    warmth = defaults.string(forKey: PersistenceKey.nightShiftWarmth)
      .flatMap(NightShiftWarmth.init(rawValue:)) ?? .warmer
    dimness = defaults.string(forKey: PersistenceKey.nightShiftDimness)
      .flatMap(NightShiftDimness.init(rawValue:)) ?? .medium
    scheduleMode = defaults.string(forKey: PersistenceKey.nightShiftScheduleMode)
      .flatMap(NightShiftScheduleMode.init(rawValue:)) ?? .solar
    manualOnMinutes = defaults.object(forKey: PersistenceKey.nightShiftManualOnMinutes) as? Int ?? (20 * 60)
    manualOffMinutes = defaults.object(forKey: PersistenceKey.nightShiftManualOffMinutes) as? Int ?? (6 * 60)
    fadeMinutes = defaults.object(forKey: PersistenceKey.nightShiftFadeMinutes) as? Int ?? 90

    let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick = Date() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  // MARK: Resolved values

  var region: NightShiftRegion {
    NightShiftRegion.region(id: regionID) ?? NightShiftRegion.guessFromCurrentTimeZone()
  }

  /// Time zone the schedule is reckoned in: the region's zone in Auto mode, the
  /// device's local zone for manually-entered clock times.
  var activeTimeZone: TimeZone {
    switch scheduleMode {
    case .solar: return region.timeZone
    case .manual: return .current
    }
  }

  /// Short human label for the current fade duration, e.g. "90m", "1h", "1.5h".
  var fadeDescription: String { Self.fadeLabel(minutes: fadeMinutes) }

  static func fadeLabel(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    let hours = Double(minutes) / 60
    return hours == hours.rounded()
      ? "\(Int(hours))h"
      : String(format: "%.1fh", hours)
  }

  /// Formats a minutes-since-midnight value as a clock time in `timeZone`.
  func clockLabel(minutes: Int, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let normalized = ((minutes % 1440) + 1440) % 1440
    let base = calendar.startOfDay(for: Date())
    let date = calendar.date(byAdding: .minute, value: normalized, to: base) ?? base
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter.string(from: date)
  }

  /// 0…1 ramp for the current moment (0 by day, 1 deep at night). A running
  /// day-preview sweep wins; otherwise full strength while calibrating in
  /// Settings; otherwise the real schedule.
  var currentIntensity: Double {
    guard isEnabled else { return 0 }
    if let previewDate { return intensity(at: previewDate) }
    if isPreviewing { return 1 }
    return intensity(at: tick)
  }

  /// Simulated wall-clock label (in the region's time zone) for the preview
  /// sweep, e.g. "9:24 PM"; empty when no sweep is running.
  var previewClockText: String {
    guard let previewDate else { return "" }
    let formatter = DateFormatter()
    formatter.timeZone = activeTimeZone
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter.string(from: previewDate)
  }

  /// Animate a full midnight → midnight day in `duration` seconds, sweeping the
  /// overlay through the active schedule's ramp so the viewer can watch how it
  /// warms and dims across a day, then return to live.
  func runDayNightPreview(duration: TimeInterval = 9) {
    guard isEnabled else { return }
    previewTimer?.invalidate()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = activeTimeZone
    previewStart = calendar.startOfDay(for: Date())
    previewStep = 0
    previewProgress = 0
    previewDate = previewStart

    let stepInterval = duration / Double(Self.previewSteps)
    let timer = Timer(timeInterval: stepInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.advancePreview() }
    }
    RunLoop.main.add(timer, forMode: .common)
    previewTimer = timer
  }

  private func advancePreview() {
    previewStep += 1
    let fraction = min(Double(previewStep) / Double(Self.previewSteps), 1)
    previewProgress = fraction
    previewDate = previewStart.addingTimeInterval(24 * 60 * 60 * fraction)
    if fraction >= 1 {
      previewTimer?.invalidate()
      previewTimer = nil
      previewProgress = nil
      previewDate = nil
    }
  }

  /// Opacity of the **black dimming layer** right now (brightness reduction).
  var currentDimOpacity: Double {
    currentIntensity * dimness.peakOpacity
  }

  /// Opacity of the **warm color layer** right now (hue cast).
  var currentWarmOpacity: Double {
    currentIntensity * warmth.peakOpacity
  }

  /// The single opaque colour the overlay **multiplies** the whole app by. This is
  /// what makes Night Shift a true tint rather than a wash painted on top:
  /// multiplying scales each channel of the content *down* and never adds light,
  /// so black stays black (unlike source-over, which lifts darks toward the tint
  /// colour and looks bright). Mirrors the system Color Filters.
  ///
  /// - Red is kept (only scaled by dimness), so the picture warms by losing
  ///   green/blue, not by gaining red.
  /// - Blue is killed quickly with warmth (a warm screen has no blue).
  /// - Green is killed at the level's `greenKill` fraction of the blue rate, so
  ///   the leftover green is what reads as **orange/amber**. Low levels keep lots
  ///   of green (orange); the top "On Fire" level strips nearly all of it (red),
  ///   so the scale rides orange → orange-red → near-pure-red.
  /// - Daytime (both 0) resolves to white → ×1 → no change.
  ///
  ///       r = 1 − dim
  ///       g = (1 − dim) × (1 − warm × greenKill)
  ///       b = (1 − dim) × (1 − warm)
  var overlayMultiplyColor: Color {
    let dim = currentDimOpacity
    let warm = currentWarmOpacity
    let red = 1 - dim
    let green = (1 - dim) * (1 - warm * warmth.greenKill)
    let blue = (1 - dim) * (1 - warm)
    return Color(red: red, green: green, blue: blue)
  }

  /// Whether the overlay is painting anything right now.
  var isActiveNow: Bool { currentDimOpacity > 0.001 || currentWarmOpacity > 0.001 }

  // MARK: Schedule

  /// A human-readable status line for Settings, covering both schedule modes.
  func scheduleSummary(now: Date = Date()) -> String {
    let fade = fadeDescription
    switch scheduleMode {
    case .manual:
      let on = clockLabel(minutes: manualOnMinutes)
      let off = clockLabel(minutes: manualOffMinutes)
      if !isEnabled {
        return "Off. Manual: on \(on), off \(off)."
      }
      if isActiveNow {
        let percent = Int((currentIntensity * 100).rounded())
        return "Active now (\(percent)%). Manual: on \(on), off \(off) · \(fade) fade."
      }
      return "Idle until \(on). Manual · \(fade) fade."

    case .solar:
      let region = self.region
      let tz = region.timeZone
      guard let today = SolarTime.sunriseSunset(
        latitude: region.latitude, longitude: region.longitude, on: now, timeZone: tz
      ) else {
        return "Sunrise/sunset unavailable at this location today."
      }

      let formatter = DateFormatter()
      formatter.timeZone = tz
      formatter.dateFormat = "h:mm a"

      let sunset = formatter.string(from: today.sunset)
      let sunrise = formatter.string(from: today.sunrise)

      if !isEnabled {
        return "Off. \(region.name): sunset \(sunset), sunrise \(sunrise)."
      }
      if isActiveNow {
        let percent = Int((currentIntensity * 100).rounded())
        return "Active now (\(percent)%). \(region.name) sunrise \(sunrise) · \(fade) fade."
      }
      return "Idle until sunset (\(sunset)) in \(region.name) · \(fade) fade."
    }
  }

  // MARK: Ramp math

  private func intensity(at date: Date) -> Double {
    switch scheduleMode {
    case .manual:
      return manualIntensity(at: date)
    case .solar:
      return solarIntensity(at: date)
    }
  }

  /// Ramp driven by the viewer's two fixed clock times (local zone), handling the
  /// usual case where the window wraps past midnight.
  private func manualIntensity(at date: Date) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let startOfToday = calendar.startOfDay(for: date)
    // The active window may have started today or yesterday (when it wraps
    // midnight), so test both candidate start days.
    for dayOffset in [0, -1] {
      guard
        let base = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
        let on = calendar.date(byAdding: .minute, value: manualOnMinutes, to: base),
        let rawOff = calendar.date(byAdding: .minute, value: manualOffMinutes, to: base)
      else { continue }
      let off = rawOff <= on ? rawOff.addingTimeInterval(86_400) : rawOff
      if date >= on, date < off {
        return ramp(now: date, dusk: on, dawn: off)
      }
    }
    return 0
  }

  private func solarIntensity(at date: Date) -> Double {
    let region = self.region
    let tz = region.timeZone
    guard let today = SolarTime.sunriseSunset(
      latitude: region.latitude, longitude: region.longitude, on: date, timeZone: tz
    ) else {
      return 0
    }

    if date < today.sunrise {
      // Pre-dawn: the night began at yesterday's sunset.
      let yesterday = SolarTime.sunriseSunset(
        latitude: region.latitude,
        longitude: region.longitude,
        on: date.addingTimeInterval(-86_400),
        timeZone: tz
      )
      let dusk = yesterday?.sunset ?? today.sunset.addingTimeInterval(-86_400)
      return ramp(now: date, dusk: dusk, dawn: today.sunrise)
    } else if date < today.sunset {
      // Daytime.
      return 0
    } else {
      // After dusk: the night ends at tomorrow's sunrise.
      let tomorrow = SolarTime.sunriseSunset(
        latitude: region.latitude,
        longitude: region.longitude,
        on: date.addingTimeInterval(86_400),
        timeZone: tz
      )
      let dawn = tomorrow?.sunrise ?? today.sunrise.addingTimeInterval(86_400)
      return ramp(now: date, dusk: today.sunset, dawn: dawn)
    }
  }

  /// Triangle-clamped ramp: 0 at `dusk`, up over `transitionInterval`, hold at 1,
  /// down over `transitionInterval` to 0 at `dawn`. Taking the min of the two legs
  /// also gracefully handles windows shorter than `2 × transitionInterval` (the
  /// wash simply peaks below full strength).
  private func ramp(now: Date, dusk: Date, dawn: Date) -> Double {
    guard now > dusk, now < dawn else { return 0 }
    let interval = max(transitionInterval, 1)
    let up = now.timeIntervalSince(dusk) / interval
    let down = dawn.timeIntervalSince(now) / interval
    return Swift.max(0, Swift.min(1, Swift.min(up, down)))
  }
}
