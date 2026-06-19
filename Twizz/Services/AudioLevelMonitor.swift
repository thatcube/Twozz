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

  /// Diagnostics: how many segments have been decoded into real levels, and how
  /// many real samples are queued for playout. Surfaced by a temporary on-screen
  /// readout while we tune reactivity.
  private(set) var decodedSegmentCount = 0
  var pendingRealSamples: Int { realQueue.count }
  /// Signed gap (ms) between the player's position and the loudness sample we're
  /// showing — near zero means well aligned. Temporary diagnostic.
  private(set) var syncLagMs: Int = 0

  // Internal mechanism state is deliberately excluded from observation: only the
  // view-facing diagnostics above (`level`, `isReceivingRealAudio`,
  // `decodedSegmentCount`, `syncLagMs`) should drive SwiftUI invalidation. In
  // particular `realQueue` mutates ~60Hz; observing it would invalidate the
  // visualizer's host view every tick on top of its own `TimelineView` redraw.
  @ObservationIgnored private var decoder: AudioOnlyLevelDecoder?
  @ObservationIgnored private var ticker: Timer?
  @ObservationIgnored private var startTime = CACurrentMediaTime()

  /// Returns the wall-clock date the player is *currently* playing, derived from
  /// the stream's `EXT-X-PROGRAM-DATE-TIME`. Lets us show the loudness for the
  /// audio actually leaving the speakers instead of the live edge we decoded.
  @ObservationIgnored private var playerClock: (() -> Date?)?

  // One decoded loudness sample, optionally stamped with the media wall-clock
  // time it represents so we can line it up with playback.
  private struct RealSample {
    let date: Date?
    let level: Double
  }
  @ObservationIgnored private var realQueue: [RealSample] = []
  @ObservationIgnored private var realSamplesAreDated = false
  @ObservationIgnored private var queueInterval: Double = 0.05
  @ObservationIgnored private var nextPopAt: CFTimeInterval = 0
  @ObservationIgnored private var lastRealAt: CFTimeInterval = 0
  @ObservationIgnored private var currentRealTarget: Double = 0

  // Fast attack so transients pop; slower decay so the orb eases back down.
  private let attack = 0.6
  private let decay = 0.2
  private let realAudioTimeout: CFTimeInterval = 1.0
  private let tickInterval: TimeInterval = 1.0 / 60.0
  // How far the head may trail the player before we consider the data stale.
  private let syncTolerance: TimeInterval = 1.5
  // Cap the backlog (~30s of dated history) so it can't grow without bound.
  private let maxQueued = 600

  // MARK: - Lifecycle

  /// Starts the visualizer clock and, when an audio-only playlist URL is
  /// available, the background decoder that produces real loudness values.
  /// `currentDate` reports the player's current media time so playout can be
  /// aligned to what's actually being heard.
  func start(
    audioPlaylistURL: URL?,
    headers: [String: String],
    currentDate: (() -> Date?)? = nil
  ) {
    startTime = CACurrentMediaTime()
    playerClock = currentDate
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
    playerClock = nil
    realQueue.removeAll()
    realSamplesAreDated = false
    nextPopAt = 0
    lastRealAt = 0
    decodedSegmentCount = 0
    syncLagMs = 0
    isReceivingRealAudio = false
  }

  private func stopDecoder() {
    if let decoder {
      Task { await decoder.stop() }
    }
    decoder = nil
  }

  /// Called by the decoder (hopping to the main actor) with a freshly decoded
  /// loudness contour for one segment of audio. `startDate` is the media
  /// wall-clock time of the segment's first sample, when the playlist provides
  /// it, so we can align playout to the player.
  func enqueueRealLevels(_ contour: [Double], interval: Double, startDate: Date?) {
    guard !contour.isEmpty else { return }
    decodedSegmentCount += 1
    let wasIdle = (CACurrentMediaTime() - lastRealAt) > realAudioTimeout
    queueInterval = min(max(interval, 0.02), 0.12)

    if let startDate {
      realSamplesAreDated = true
      for (i, level) in contour.enumerated() {
        realQueue.append(RealSample(date: startDate.addingTimeInterval(Double(i) * interval), level: level))
      }
    } else {
      realSamplesAreDated = false
      for level in contour {
        realQueue.append(RealSample(date: nil, level: level))
      }
    }

    if realQueue.count > maxQueued {
      realQueue.removeFirst(realQueue.count - maxQueued)
    }
    // After a gap in undated mode, restart playout from now instead of bursting.
    if wasIdle, !realSamplesAreDated { nextPopAt = CACurrentMediaTime() }
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

    if realSamplesAreDated, let playerDate = playerClock?() {
      advanceDatedQueue(to: playerDate, now: now)
    } else if !realQueue.isEmpty, now >= nextPopAt {
      // Undated fallback: play out at the segment's native cadence.
      currentRealTarget = shaped(realQueue.removeFirst().level)
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

  /// Picks the loudness sample matching the player's current media time, so the
  /// orb pulses with the audio actually being heard rather than the live edge.
  private func advanceDatedQueue(to playerDate: Date, now: CFTimeInterval) {
    // Drop samples the player has already passed, keeping the most recent one at
    // or before the current playback position at the head.
    while realQueue.count > 1, let next = realQueue[1].date, next <= playerDate {
      realQueue.removeFirst()
    }
    guard let head = realQueue.first, let headDate = head.date else { return }
    // Only treat as real audio when the head actually lines up with playback;
    // if we've run dry the head falls far behind and we ease back to ambient.
    let lag = playerDate.timeIntervalSince(headDate)
    syncLagMs = Int((lag * 1000).rounded())
    if lag >= -syncTolerance, lag < syncTolerance {
      currentRealTarget = shaped(head.level)
      lastRealAt = now
    }
  }

  /// Maps raw RMS into a livelier display range. RMS for typical program audio
  /// sits low, so we drop a small noise floor, then lift and expand what's left
  /// so quiet passages dip toward the baseline and peaks push the orb hard.
  private func shaped(_ rms: Double) -> Double {
    let floored = max(0, rms - 0.015)
    let boosted = pow(min(floored * 4.5, 1), 0.6)
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
