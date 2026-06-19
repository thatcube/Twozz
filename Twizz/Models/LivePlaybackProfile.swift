import Foundation

/// User-selectable live playback profile, surfaced in the quality picker as the
/// two "Auto" options. Both keep prefetch promotion on (the real latency win) and
/// both must never stutter; they differ only in how they trade quality for
/// latency. An explicit rendition pick (e.g. "1080p60") is a third, fixed-quality
/// case that ignores the profile.
enum LivePlaybackProfile: String, CaseIterable, Identifiable {
  /// Latency priority: keep a shallow buffer near the live edge and let adaptive
  /// bitrate drop resolution to avoid a stall. Degraded quality is acceptable;
  /// stutter is not.
  case lowerLatency
  /// Quality priority: keep a deeper buffer so adaptive bitrate can settle on (and
  /// hold) the best stable resolution, accepting a little more latency. Never
  /// sacrifices quality on its own.
  case higherQuality

  var id: String { rawValue }

  /// Default for new installs. Matches the app's historical "low-latency on"
  /// stance — latency is the priority, with the no-stutter guarantee provided by
  /// ABR headroom plus the live-edge drift recovery.
  static let `default`: LivePlaybackProfile = .lowerLatency

  /// Short label used in the quality picker's two Auto rows and the button.
  var pickerLabel: String {
    switch self {
    case .lowerLatency: return "Auto · Low Latency"
    case .higherQuality: return "Auto · High Quality"
    }
  }

  /// Even shorter tag for the quality button (e.g. "Auto · LL (1080p60)").
  var shortTag: String {
    switch self {
    case .lowerLatency: return "Low Latency"
    case .higherQuality: return "Quality"
    }
  }
}

/// Concrete AVPlayer tuning derived from the active profile (and whether a single
/// rendition is hard-pinned). Centralizes the buffer / catch-up knobs that used to
/// be scattered as raw `let`s on `PlayerView`, so the latency-vs-quality tradeoff
/// lives in one place and is unit-testable.
struct LivePlaybackPolicy: Equatable {
  /// `AVPlayerItem.preferredForwardBufferDuration`. Shallower = closer to live but
  /// less jitter headroom; deeper = more stable, slightly more latency.
  var preferredForwardBufferDuration: Double
  /// Whether to nudge `player.rate` above 1.0 to drift back toward the edge when
  /// behind (imperceptible; never used to reduce quality).
  var enablesGentleCatchUp: Bool
  /// Catch-up target: the live-edge gap (seconds) to chase *down to*. Catch-up
  /// engages only while the edge gap exceeds this, and eases off as it approaches.
  var catchUpThresholdSeconds: Double
  /// Ceiling on the catch-up rate (e.g. 1.08 = at most 8% faster).
  var maxCatchUpRate: Float
  /// Proportional gain: extra rate per second of edge gap beyond the target. The
  /// further behind the edge, the faster it catches up — up to `maxCatchUpRate`.
  var catchUpRampPerSecond: Float
  /// Anti-stall floor: the slowest the player may run while easing the rate down
  /// to ride out a draining buffer. `1.0` disables the slow-down arm entirely.
  var minPlaybackRate: Float
  /// Begin easing the rate below 1.0 once the forward buffer drops under this many
  /// seconds; the rate ramps linearly from 1.0 here down to `minPlaybackRate` at an
  /// empty buffer.
  var slowdownBufferFloorSeconds: Double
  /// Only allow catch-up (speeding up) when the forward buffer is at least this
  /// healthy, so we never chase the edge while already starved.
  var catchUpHealthyBufferSeconds: Double

  /// Builds the policy for a live stream.
  /// - Parameters:
  ///   - profile: the active Auto profile.
  ///   - isPinned: true when the viewer pinned a specific rendition (not Auto).
  static func live(profile: LivePlaybackProfile, isPinned: Bool) -> LivePlaybackPolicy {
    // A pinned rendition is inherently "hold this exact quality"; it has no ABR
    // fallback, so give it a stable buffer and never fight it with catch-up.
    if isPinned {
      return LivePlaybackPolicy(
        preferredForwardBufferDuration: 8,
        enablesGentleCatchUp: false,
        catchUpThresholdSeconds: .greatestFiniteMagnitude,
        maxCatchUpRate: 1.0,
        catchUpRampPerSecond: 0,
        minPlaybackRate: 1.0,
        slowdownBufferFloorSeconds: 0,
        catchUpHealthyBufferSeconds: .greatestFiniteMagnitude
      )
    }

    switch profile {
    case .lowerLatency:
      return LivePlaybackPolicy(
        // Shallow forward buffer: sit close to the edge and, critically, resume
        // quickly after a dip instead of waiting to refill a deep buffer (that
        // deep-refill wait is what caused the long "waiting toMinimizeStalls"
        // freezes). The anti-stall slow-down covers transient dips instead.
        preferredForwardBufferDuration: 3,
        enablesGentleCatchUp: true,
        // Actively chase the live edge down to ~2s — *tighter* than the 3.5s seek
        // landing point — so catch-up always has slack to work with and visibly
        // drives the rate. This is what makes it a true low-latency profile.
        catchUpThresholdSeconds: 2,
        maxCatchUpRate: 1.12,
        catchUpRampPerSecond: 0.04,
        // Ease down toward 0.90× as the buffer drains under 1.5s so a transient
        // dip is absorbed by playing slightly slow instead of a hard stall. The
        // slow-down arm is evaluated first, so it always overrides catch-up.
        minPlaybackRate: 0.90,
        slowdownBufferFloorSeconds: 1.5,
        // Catch up once the buffer clears 2.0s (a 0.5s dead-band above the
        // slow-down floor so the two arms settle at ~2s edge gap instead of
        // flapping). Equilibrium = ~2s from the edge with a safe buffer.
        catchUpHealthyBufferSeconds: 2.0
      )
    case .higherQuality:
      return LivePlaybackPolicy(
        preferredForwardBufferDuration: 8,
        enablesGentleCatchUp: false,
        catchUpThresholdSeconds: .greatestFiniteMagnitude,
        maxCatchUpRate: 1.0,
        catchUpRampPerSecond: 0,
        minPlaybackRate: 1.0,
        slowdownBufferFloorSeconds: 0,
        catchUpHealthyBufferSeconds: .greatestFiniteMagnitude
      )
    }
  }

  /// Emergency policy for a stream detected as chronically unstable (repeated
  /// stalls in a short window — usually a struggling *broadcaster* encoder, not
  /// the viewer's bandwidth). The normal low-latency strategy actively makes this
  /// worse: catch-up and edge-resync keep yanking the playhead toward a live edge
  /// that can't sustain playback, so it stalls, rewinds, and repeats. This profile
  /// inverts the trade-off — abandon low latency, ride well behind the edge on a
  /// deep buffer so the source's jitter is absorbed. Smoothness over latency.
  static var stabilityFallback: LivePlaybackPolicy {
    LivePlaybackPolicy(
      // Deep buffer: bank a large cushion so an erratic source can't starve us.
      preferredForwardBufferDuration: 12,
      // Never chase the edge — that's what was causing the stall/rewind loop.
      enablesGentleCatchUp: false,
      catchUpThresholdSeconds: .greatestFiniteMagnitude,
      maxCatchUpRate: 1.0,
      catchUpRampPerSecond: 0,
      // Keep the anti-stall slow-down (start easing earlier, given the deep
      // buffer) as the last line of defence against the next dip.
      minPlaybackRate: 0.90,
      slowdownBufferFloorSeconds: 3.0,
      catchUpHealthyBufferSeconds: .greatestFiniteMagnitude
    )
  }
}
