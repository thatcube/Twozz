import Foundation
import QuartzCore

/// Drives the audio-only visualizer with a smoothed `level` in `0...1`.
///
/// Real reactivity comes from `AudioOnlyLevelDecoder`, which decodes the
/// stream's audio-only segments off to the side and feeds us an RMS loudness
/// contour (live HLS can't be metered in-place via an audio tap). Those values
/// are played out at their native cadence. Whenever real audio isn't flowing —
/// before the first segment decodes, or if the stream's container can't be
/// decoded in isolation — an organic ambient waveform keeps the orb alive.
///
/// The view just reads `level`; it doesn't care which source produced it.
@MainActor
@Observable
final class AudioLevelMonitor {
  /// Smoothed amplitude the visualizer renders, `0...1`.
  private(set) var level: Double = 0

  /// True while the decoder is actively feeding real loudness values.
  private(set) var isReceivingRealAudio = false

  private var decoder: AudioOnlyLevelDecoder?
  private var ticker: Timer?
  private var startTime = CACurrentMediaTime()

  // Real-level playout queue: raw RMS values awaiting their turn on screen.
  private var realQueue: [Double] = []
  private var queueInterval: Double = 0.05
  private var nextPopAt: CFTimeInterval = 0
  private var lastRealAt: CFTimeInterval = 0
  private var currentRealTarget: Double = 0

  // Fast attack so transients pop; slower decay so the orb eases back down.
  private let attack = 0.5
  private let decay = 0.14
  private let realAudioTimeout: CFTimeInterval = 1.0
  private let tickInterval: TimeInterval = 1.0 / 60.0
  // Cap the backlog (~12s) so we never drift far behind the live edge.
  private let maxQueued = 240

  // MARK: - Lifecycle

  /// Starts the visualizer clock and, when an audio-only playlist URL is
  /// available, the background decoder that produces real loudness values.
  func start(audioPlaylistURL: URL?, headers: [String: String]) {
    startTime = CACurrentMediaTime()
    startTicker()

    guard let url = audioPlaylistURL else { return }
    stopDecoder()
    let decoder = AudioOnlyLevelDecoder(playlistURL: url, headers: headers, monitor: self)
    self.decoder = decoder
    Task { await decoder.start() }
  }

  func stop() {
    ticker?.invalidate()
    ticker = nil
    stopDecoder()
    realQueue.removeAll()
    nextPopAt = 0
    lastRealAt = 0
    isReceivingRealAudio = false
  }

  private func stopDecoder() {
    if let decoder {
      Task { await decoder.stop() }
    }
    decoder = nil
  }

  /// Called by the decoder (hopping to the main actor) with a freshly decoded
  /// loudness contour for one segment of audio.
  func enqueueRealLevels(_ contour: [Double], interval: Double) {
    guard !contour.isEmpty else { return }
    let wasIdle = (CACurrentMediaTime() - lastRealAt) > realAudioTimeout
    queueInterval = min(max(interval, 0.02), 0.12)
    realQueue.append(contentsOf: contour)
    if realQueue.count > maxQueued {
      realQueue.removeFirst(realQueue.count - maxQueued)
    }
    // After a gap, restart playout from now instead of bursting to catch up.
    if wasIdle { nextPopAt = CACurrentMediaTime() }
  }

  // MARK: - Per-frame update

  private func startTicker() {
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func tick() {
    let now = CACurrentMediaTime()

    // Advance the real-level queue at its native cadence.
    if !realQueue.isEmpty, now >= nextPopAt {
      currentRealTarget = shaped(realQueue.removeFirst())
      nextPopAt = now + queueInterval
      lastRealAt = now
    }

    let hasReal = lastRealAt > 0 && (now - lastRealAt) < realAudioTimeout
    if hasReal != isReceivingRealAudio {
      isReceivingRealAudio = hasReal
    }

    let target = hasReal ? currentRealTarget : ambientLevel(at: now - startTime)
    let coeff = target > level ? attack : decay
    level += (target - level) * coeff
    level = min(max(level, 0), 1)
  }

  /// Maps raw RMS into a livelier display range. RMS for typical program audio
  /// sits low, so we lift and gently compress it.
  private func shaped(_ rms: Double) -> Double {
    let boosted = pow(min(rms * 3.2, 1), 0.7)
    return min(max(boosted, 0), 1)
  }

  /// Organic idle motion: a few incommensurate sines summed so it never reads as
  /// a single repeating pulse, biased toward a calm mid-level.
  private func ambientLevel(at t: Double) -> Double {
    let slow = sin(t * 0.90) * 0.5 + 0.5
    let mid = sin(t * 1.70 + 1.1) * 0.5 + 0.5
    let fast = sin(t * 3.10 + 0.4) * 0.5 + 0.5
    let flutter = sin(t * 5.30 + 2.0) * 0.5 + 0.5
    let blended = slow * 0.5 + mid * 0.28 + fast * 0.15 + flutter * 0.07
    return 0.18 + blended * 0.5
  }
}
