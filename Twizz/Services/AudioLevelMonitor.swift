import AVFoundation
import MediaToolbox
import OSLog
import QuartzCore

/// Thread-safe scratchpad the realtime audio-tap thread writes into and the main
/// thread reads from. The tap callback runs on a high-priority media thread, so
/// it can never touch `@Observable` state directly — it just stashes the latest
/// RMS here behind a lock.
private final class AudioLevelBox: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: State())

  private struct State {
    var rms: Double = 0
    var sampleCount: UInt64 = 0
  }

  /// Most recent RMS amplitude (roughly 0...1) seen by the tap.
  var rms: Double { lock.withLock { $0.rms } }

  /// Monotonic counter so the monitor can tell whether new audio actually
  /// arrived since it last looked (i.e. the tap is genuinely firing).
  var sampleCount: UInt64 { lock.withLock { $0.sampleCount } }

  func record(rms value: Double) {
    lock.withLock {
      $0.rms = value
      $0.sampleCount &+= 1
    }
  }
}

/// Drives the audio-only visualizer with a smoothed `level` in `0...1`.
///
/// Two sources feed `level`:
///  1. **Best-effort real audio** — an `MTAudioProcessingTap` mixed onto the
///     player item's audio track. On live HLS the asset usually exposes no audio
///     `AVAssetTrack`, so the tap can't be installed and never fires; we detect
///     that and fall back automatically.
///  2. **Ambient synthesis** — an organic, always-running waveform so the orb
///     still breathes convincingly when real levels aren't available.
///
/// The view reads `level`; it doesn't care which source produced it.
@MainActor
@Observable
final class AudioLevelMonitor {
  /// Smoothed amplitude the visualizer renders, `0...1`.
  private(set) var level: Double = 0

  /// True once the audio tap has delivered real samples. Drives the (subtle)
  /// difference between "reacting to audio" and "ambient idle" motion, and lets
  /// the UI/logs report which path is live.
  private(set) var isReceivingRealAudio = false

  private let log = Logger(subsystem: "com.thatcube.Twizz", category: "AudioLevelMonitor")

  private let levelBox = AudioLevelBox()
  private weak var boundItem: AVPlayerItem?
  private var tap: MTAudioProcessingTap?

  private var ticker: Timer?
  private var startTime = CACurrentMediaTime()
  private var lastSampleCount: UInt64 = 0
  private var lastRealAudioAt: CFTimeInterval = 0
  private var trackLoadTask: Task<Void, Never>?

  // Smoothing coefficients: fast attack so peaks pop, slower decay so the orb
  // eases back down instead of snapping.
  private let attack = 0.45
  private let decay = 0.12
  // If the tap stops delivering samples for this long, drop back to ambient.
  private let realAudioTimeout: CFTimeInterval = 0.6
  private let tickInterval: TimeInterval = 1.0 / 60.0

  // MARK: - Lifecycle

  func start() {
    startTime = CACurrentMediaTime()
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  func stop() {
    ticker?.invalidate()
    ticker = nil
  }

  /// Points the monitor at a player item and tries to install the real-audio
  /// tap on its audio track. Safe to call repeatedly; re-binding the same item
  /// is a no-op.
  func bind(to item: AVPlayerItem?) {
    guard boundItem !== item else { return }
    teardownTap()
    boundItem = item
    isReceivingRealAudio = false
    lastSampleCount = levelBox.sampleCount

    guard let item else { return }
    installTap(on: item)
  }

  func unbind() {
    teardownTap()
    boundItem = nil
    isReceivingRealAudio = false
  }

  // MARK: - Per-frame update

  private func tick() {
    let now = CACurrentMediaTime()

    // Did the tap deliver anything since last frame?
    let count = levelBox.sampleCount
    if count != lastSampleCount {
      lastSampleCount = count
      lastRealAudioAt = now
    }
    let tapAlive = (now - lastRealAudioAt) < realAudioTimeout && lastRealAudioAt > 0
    if tapAlive != isReceivingRealAudio {
      isReceivingRealAudio = tapAlive
    }

    let target: Double = tapAlive ? shapedRealLevel() : ambientLevel(at: now - startTime)
    let coeff = target > level ? attack : decay
    level += (target - level) * coeff
    level = min(max(level, 0), 1)
  }

  /// Maps raw RMS into a livelier display range. RMS for typical program audio
  /// sits low, so we lift and gently compress it.
  private func shapedRealLevel() -> Double {
    let rms = levelBox.rms
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
    // Keep it in a gentle band so the orb breathes rather than thrashes.
    return 0.18 + blended * 0.5
  }

  // MARK: - Audio tap

  private func installTap(on item: AVPlayerItem) {
    let box = levelBox
    trackLoadTask?.cancel()
    trackLoadTask = Task { [weak self] in
      let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      guard let track = tracks?.first else {
        // Expected on live HLS: no exposed audio track to mix a tap onto.
        self.log.info("No audio asset track available; using ambient visualizer.")
        return
      }
      guard self.boundItem === item else { return }
      self.attachTap(to: item, track: track, box: box)
    }
  }

  private func attachTap(to item: AVPlayerItem, track: AVAssetTrack, box: AudioLevelBox) {
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque()),
      init: tapInit,
      finalize: tapFinalize,
      prepare: nil,
      unprepare: nil,
      process: tapProcess
    )

    var tapOut: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault,
      &callbacks,
      kMTAudioProcessingTapCreationFlag_PostEffects,
      &tapOut
    )
    guard status == noErr, let createdTap = tapOut else {
      // Creation failed — release the box we retained for the (absent) tap.
      Unmanaged<AudioLevelBox>.fromOpaque(
        UnsafeRawPointer(callbacks.clientInfo!)
      ).release()
      log.error("MTAudioProcessingTapCreate failed (\(status)); using ambient visualizer.")
      return
    }

    let params = AVMutableAudioMixInputParameters(track: track)
    params.audioTapProcessor = createdTap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [params]
    item.audioMix = mix
    tap = createdTap
    log.info("Installed audio processing tap for real-time levels.")
  }

  private func teardownTap() {
    trackLoadTask?.cancel()
    trackLoadTask = nil
    boundItem?.audioMix = nil
    tap = nil
  }
}

// MARK: - C tap callbacks (run on the realtime audio thread)

private func tapInit(
  tap: MTAudioProcessingTap,
  clientInfo: UnsafeMutableRawPointer?,
  tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
  // Hand the retained box reference through to the storage slot.
  tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
  let storage = MTAudioProcessingTapGetStorage(tap)
  Unmanaged<AudioLevelBox>.fromOpaque(storage).release()
}

private func tapProcess(
  tap: MTAudioProcessingTap,
  numberFrames: CMItemCount,
  flags: MTAudioProcessingTapFlags,
  bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
  numberFramesOut: UnsafeMutablePointer<CMItemCount>,
  flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
  let status = MTAudioProcessingTapGetSourceAudio(
    tap,
    numberFrames,
    bufferListInOut,
    flagsOut,
    nil,
    numberFramesOut
  )
  guard status == noErr else { return }

  let storage = MTAudioProcessingTapGetStorage(tap)
  let box = Unmanaged<AudioLevelBox>.fromOpaque(storage).takeUnretainedValue()

  var sumSquares: Double = 0
  var sampleTotal = 0

  let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
  for buffer in bufferList {
    guard let data = buffer.mData else { continue }
    let channels = max(Int(buffer.mNumberChannels), 1)
    let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    guard floatCount > 0 else { continue }
    let samples = data.bindMemory(to: Float.self, capacity: floatCount)
    var i = 0
    while i < floatCount {
      let v = Double(samples[i])
      sumSquares += v * v
      i += channels  // sample one channel; good enough for an amplitude meter
    }
    sampleTotal += floatCount / channels
  }

  guard sampleTotal > 0 else { return }
  let rms = (sumSquares / Double(sampleTotal)).squareRoot()
  box.record(rms: rms)
}
