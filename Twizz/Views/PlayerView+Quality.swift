import AVKit
import SwiftUI

// Quality picker: the option list and button label, plus resolving the active
// variant name on the adaptive master playlist and applying a selection.
extension PlayerView {
  /// The active latency-vs-quality profile, decoded from its stored raw value.
  var livePlaybackProfile: LivePlaybackProfile {
    get { LivePlaybackProfile(rawValue: livePlaybackProfileRaw) ?? .default }
    nonmutating set { livePlaybackProfileRaw = newValue.rawValue }
  }

  /// Concrete buffer / catch-up tuning for the current profile and pin state.
  var activeLivePlaybackPolicy: LivePlaybackPolicy {
    LivePlaybackPolicy.live(profile: livePlaybackProfile, isPinned: preferredQuality != "Auto")
  }

  /// Applies the active policy to the live item without swapping the source —
  /// used when only the profile changes (the master URL stays the same).
  func applyActiveLivePlaybackPolicy() {
    player.currentItem?.preferredForwardBufferDuration =
      activeLivePlaybackPolicy.preferredForwardBufferDuration
    applyLiveLatencyCorrection()
  }

  var qualityOptions: [String] {
    [LivePlaybackProfile.lowerLatency.pickerLabel,
     LivePlaybackProfile.higherQuality.pickerLabel]
      + (playback?.qualities.map(\.name) ?? [])
  }

  /// The option string the picker should show a checkmark against. While on the
  /// adaptive master ("Auto") that's whichever profile row is active; a pinned
  /// rendition selects itself.
  var selectedQualityOption: String {
    preferredQuality == "Auto" ? livePlaybackProfile.pickerLabel : preferredQuality
  }

  /// Text shown on the player's quality button: the selected variant (e.g.
  /// "1080p60"), or "Auto (1080p60)" reflecting the live adaptive resolution.
  var qualityButtonLabel: String {
    if preferredQuality == "Auto" {
      if let resolvedQualityName {
        return "Auto (\(resolvedQualityName))"
      }
      return "Auto"
    }
    return Self.shortQualityName(preferredQuality)
  }

  /// Every label the quality button could ever display for the current stream.
  /// The button reserves the width of the widest of these so the in-player
  /// title's available space stays constant as the live label changes (e.g.
  /// "Auto" -> "Auto (1080p60)"), preventing distracting title font reflow.
  var qualityButtonLabelCandidates: [String] {
    var labels: Set<String> = ["Auto"]
    let videoVariants = (playback?.qualities ?? []).filter { !$0.isAudioOnly }
    for quality in videoVariants {
      let short = Self.shortQualityName(quality.name)
      labels.insert(short)
      labels.insert("Auto (\(short))")
    }
    return labels.sorted()
  }

  /// Drops the "(Source)" suffix so the button reads "1080p60", not
  /// "1080p60 (Source)".
  static func shortQualityName(_ name: String) -> String {
    name.replacingOccurrences(of: " (Source)", with: "")
      .replacingOccurrences(of: " (source)", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// Parses the vertical resolution from a variant name, e.g. "1080p60" -> 1080.
  static func verticalResolution(from name: String) -> Int? {
    let lower = name.lowercased()
    guard let pIndex = lower.firstIndex(of: "p") else { return nil }
    let digits = lower[lower.startIndex..<pIndex].filter(\.isNumber)
    return Int(digits)
  }

  /// Maps AVPlayer's current presentation size to the closest known variant
  /// name while on the adaptive ("Auto") master playlist.
  func updateResolvedQuality() {
    let resolved = computeResolvedQualityName()
    // Assign only on change: this runs every second, and rewriting the same
    // `@State` value still re-executes the player body (flashing focus).
    if resolvedQualityName != resolved {
      resolvedQualityName = resolved
    }
  }

  func computeResolvedQualityName() -> String? {
    guard preferredQuality == "Auto" else {
      return nil
    }
    guard let playback else { return resolvedQualityName }

    let videoVariants = playback.qualities.filter { !$0.isAudioOnly }
    // Named variants that advertise a parseable resolution, e.g. "720p60".
    let namedCandidates: [(Int, String)] = videoVariants.compactMap { quality in
      guard let resolution = Self.verticalResolution(from: quality.name) else { return nil }
      return (resolution, Self.shortQualityName(quality.name))
    }

    // Preferred path: match the live adaptive resolution to the nearest named
    // variant so we keep its exact label (including frame rate).
    if let size = player.currentItem?.presentationSize, size.height > 0 {
      let height = Int(size.height.rounded())
      if let best = namedCandidates.min(by: { abs($0.0 - height) < abs($1.0 - height) }) {
        return best.1
      }
      // Variants don't expose a parseable resolution (e.g. transcoding
      // disabled, source named "chunked"): derive the label from the decoded
      // frame height directly so it still shows something accurate.
      return "\(height)p"
    }

    // Presentation size not yet known. If the stream offers a single video
    // rendition, Auto is effectively that rendition — show it rather than
    // leaving the label stuck on a bare "Auto".
    if videoVariants.count == 1 {
      return Self.shortQualityName(videoVariants[0].name)
    }
    return resolvedQualityName
  }

  /// Display label for a quality option. The two Auto rows already carry their
  /// full labels ("Auto (Lower Latency)" / "Auto (Higher Quality)"), and a pinned
  /// rendition shows its own name, so options are surfaced verbatim.
  func qualityDisplayLabel(_ option: String) -> String {
    option
  }

  func selectQuality(at index: Int) {
    guard qualityOptions.indices.contains(index) else { return }
    let option = qualityOptions[index]
    if let profile = LivePlaybackProfile.allCases.first(where: { $0.pickerLabel == option }) {
      // One of the two Auto rows: stay on the adaptive master, just switch the
      // latency-vs-quality profile and re-apply its buffer/catch-up policy.
      livePlaybackProfile = profile
      if preferredQuality != "Auto" {
        preferredQuality = "Auto"
        applyQualityPreference("Auto")
      } else {
        applyActiveLivePlaybackPolicy()
      }
    } else {
      preferredQuality = option
      applyQualityPreference(option)
    }
    updateResolvedQuality()
    focus = .quality
    scheduleHide()
  }
}
