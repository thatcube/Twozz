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
  case warm
  case warmer
  case warmest

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: return "None"
    case .warm: return "Warm"
    case .warmer: return "Warmer"
    case .warmest: return "Warmest"
    }
  }

  /// Hue of the warm layer (a genuine orange/red — it sits *over* the dim layer,
  /// so it can be vivid without lifting blacks much at the low alphas below).
  var tint: Color {
    switch self {
    case .none: return .clear
    case .warm: return Color(red: 1.00, green: 0.55, blue: 0.20)
    case .warmer: return Color(red: 1.00, green: 0.42, blue: 0.12)
    case .warmest: return Color(red: 1.00, green: 0.30, blue: 0.06)
    }
  }

  /// Peak opacity of the warm layer at the deepest point of night. Kept modest
  /// so the warm cast reads on the bright parts of the image while dark areas
  /// stay dark.
  var peakOpacity: Double {
    switch self {
    case .none: return 0.0
    case .warm: return 0.12
    case .warmer: return 0.18
    case .warmest: return 0.26
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
  case subtle
  case medium
  case strong
  case max

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .subtle: return "Subtle"
    case .medium: return "Medium"
    case .strong: return "Strong"
    case .max: return "Max"
    }
  }

  /// Peak black-layer opacity at the deepest point of night.
  var peakOpacity: Double {
    switch self {
    case .subtle: return 0.30
    case .medium: return 0.52
    case .strong: return 0.72
    case .max: return 0.90
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
  /// How long the wash takes to fade fully in after sunset / fully out before
  /// sunrise. Mirrors the gentle ramp f.lux/Night Shift use.
  private static let transition: TimeInterval = 90 * 60

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
    formatter.timeZone = region.timeZone
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter.string(from: previewDate)
  }

  /// Animate a full midnight → midnight day in `duration` seconds, sweeping the
  /// overlay through the real sunset/sunrise ramp so the viewer can watch how it
  /// warms and dims across a day, then return to live.
  func runDayNightPreview(duration: TimeInterval = 9) {
    guard isEnabled else { return }
    previewTimer?.invalidate()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = region.timeZone
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

  /// Hue of the warm layer (alpha applied separately via `currentWarmOpacity`).
  var currentWarmTint: Color { warmth.tint }

  /// Whether the overlay is painting anything right now.
  var isActiveNow: Bool { currentDimOpacity > 0.001 || currentWarmOpacity > 0.001 }

  // MARK: Schedule

  /// Today's sunset and the next sunrise for the selected region, used to show a
  /// human-readable status in Settings.
  func scheduleSummary(now: Date = Date()) -> String {
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
      return "Active now (\(percent)%). \(region.name) sunrise \(sunrise)."
    }
    return "Idle until sunset (\(sunset)) in \(region.name)."
  }

  // MARK: Ramp math

  private func intensity(at date: Date) -> Double {
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

  /// Triangle-clamped ramp: 0 at `dusk`, up over `transition`, hold at 1, down
  /// over `transition` to 0 at `dawn`. Taking the min of the two legs also
  /// gracefully handles short summer nights shorter than `2 × transition`.
  private func ramp(now: Date, dusk: Date, dawn: Date) -> Double {
    guard now > dusk, now < dawn else { return 0 }
    let up = now.timeIntervalSince(dusk) / Self.transition
    let down = dawn.timeIntervalSince(now) / Self.transition
    return Swift.max(0, Swift.min(1, Swift.min(up, down)))
  }
}
