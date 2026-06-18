import AVFoundation
import Foundation
import OSLog

/// Produces a real loudness contour for the audio-only visualizer by decoding
/// the stream ourselves.
///
/// AVPlayer + live HLS does not expose decompressed PCM to an
/// `MTAudioProcessingTap`, so we can't meter the playing item directly. Instead
/// we poll the audio-only media playlist, download the freshest **self-contained
/// MPEG-TS segment**, and run an `AVAssetReader` over that *local* file (which is
/// allowed) to compute a short RMS contour. Those samples are handed to
/// `AudioLevelMonitor`, which plays them out so the orb pulses with the audio.
///
/// Best effort by design: if a stream uses a container we can't decode in
/// isolation (e.g. fMP4 media segments that need a separate init segment), the
/// reader yields nothing and the monitor stays on its ambient animation.
actor AudioOnlyLevelDecoder {
  private let playlistURL: URL
  private let headers: [String: String]
  private weak var monitor: AudioLevelMonitor?
  private let log = Logger(subsystem: "com.thatcube.Twizz", category: "AudioOnlyLevelDecoder")

  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  private var loop: Task<Void, Never>?
  private var processedSegments: Set<String> = []

  /// Target metering resolution: one RMS value per this many seconds of audio.
  private let windowSeconds: Double = 0.05
  private let fallbackSegmentDuration: Double = 2.0

  init(playlistURL: URL, headers: [String: String], monitor: AudioLevelMonitor) {
    self.playlistURL = playlistURL
    self.headers = headers
    self.monitor = monitor
  }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      await self?.run()
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  // MARK: - Polling loop

  private func run() async {
    while !Task.isCancelled {
      let pace: Double
      do {
        pace = try await tick()
      } catch {
        pace = fallbackSegmentDuration
      }
      // Pace roughly to one segment of audio so we track the live edge without
      // racing ahead of what AVPlayer is actually playing.
      try? await Task.sleep(for: .seconds(min(max(pace, 0.5), 4.0)))
    }
  }

  /// Fetches the playlist, decodes the newest unseen segment, and returns how
  /// long (seconds) to wait before the next poll.
  private func tick() async throws -> Double {
    let playlist = try await fetchText(playlistURL)
    let segments = parseSegments(playlist, relativeTo: playlistURL)
    guard let newest = segments.last else { return fallbackSegmentDuration }

    // Avoid unbounded growth of the seen-set while keeping recent identity.
    if processedSegments.count > 64 {
      processedSegments.removeAll(keepingCapacity: true)
    }

    guard !processedSegments.contains(newest.url.absoluteString) else {
      return newest.duration * 0.5
    }
    processedSegments.insert(newest.url.absoluteString)

    let data = try await fetchData(newest.url)
    let contour = try await decodeRMSContour(from: data, fallbackDuration: newest.duration)
    guard !contour.isEmpty else { return newest.duration }

    let interval = newest.duration / Double(contour.count)
    await monitor?.enqueueRealLevels(contour, interval: interval)
    return newest.duration
  }

  // MARK: - Networking

  private func fetchText(_ url: URL) async throws -> String {
    let data = try await fetchData(url)
    return String(decoding: data, as: UTF8.self)
  }

  private func fetchData(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, _) = try await session.data(for: request)
    return data
  }

  // MARK: - Playlist parsing

  private struct Segment {
    let url: URL
    let duration: Double
  }

  private func parseSegments(_ text: String, relativeTo base: URL) -> [Segment] {
    var segments: [Segment] = []
    var pendingDuration = fallbackSegmentDuration
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#EXTINF:") {
        let value = line.dropFirst("#EXTINF:".count)
        let number = value.prefix { $0.isNumber || $0 == "." }
        pendingDuration = Double(number) ?? fallbackSegmentDuration
      } else if !line.isEmpty, !line.hasPrefix("#") {
        let url = URL(string: line, relativeTo: base)?.absoluteURL
        if let url {
          segments.append(Segment(url: url, duration: pendingDuration))
        }
        pendingDuration = fallbackSegmentDuration
      }
    }
    return segments
  }

  // MARK: - Decoding

  /// Decodes a single self-contained media segment into an RMS loudness contour.
  private func decodeRMSContour(from data: Data, fallbackDuration: Double) async throws -> [Double] {
    let ext = Self.containerExtension(for: data)
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("twizz-audio-\(UUID().uuidString).\(ext)")
    try data.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let asset = AVURLAsset(url: tempURL)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      log.info("Segment exposed no audio track; staying on ambient visualizer.")
      return []
    }

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    var mono: [Float] = []
    mono.reserveCapacity(96_000)
    var sampleRate: Double = 48_000

    while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
      if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
      {
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        appendSamples(from: sampleBuffer, channels: channels, into: &mono)
      }
      CMSampleBufferInvalidate(sampleBuffer)
    }

    guard reader.status != .failed, !mono.isEmpty else { return [] }

    let duration = Double(mono.count) / sampleRate
    let effectiveDuration = duration > 0 ? duration : fallbackDuration
    let windowCount = max(1, Int((effectiveDuration / windowSeconds).rounded()))
    return Self.rmsContour(from: mono, windowCount: windowCount)
  }

  private func appendSamples(
    from sampleBuffer: CMSampleBuffer, channels: Int, into mono: inout [Float]
  ) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    )
    guard status == kCMBlockBufferNoErr, let dataPointer else { return }

    let floatCount = totalLength / MemoryLayout<Float>.size
    guard floatCount > 0 else { return }
    dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
      var i = 0
      while i < floatCount {
        if channels == 1 {
          mono.append(floats[i])
          i += 1
        } else {
          var sum: Float = 0
          var c = 0
          while c < channels, i + c < floatCount {
            sum += floats[i + c]
            c += 1
          }
          mono.append(sum / Float(channels))
          i += channels
        }
      }
    }
  }

  private static func rmsContour(from samples: [Float], windowCount: Int) -> [Double] {
    guard windowCount > 0, !samples.isEmpty else { return [] }
    let windowSize = max(1, samples.count / windowCount)
    var contour: [Double] = []
    contour.reserveCapacity(windowCount)
    var index = 0
    while index < samples.count {
      let end = min(index + windowSize, samples.count)
      var sumSquares: Double = 0
      var n = 0
      var j = index
      while j < end {
        let v = Double(samples[j])
        sumSquares += v * v
        n += 1
        j += 1
      }
      if n > 0 {
        contour.append((sumSquares / Double(n)).squareRoot())
      }
      index = end
    }
    return contour
  }

  /// Sniffs the container so the temp file gets an extension AVURLAsset trusts.
  private static func containerExtension(for data: Data) -> String {
    // MPEG-TS packets start with the 0x47 sync byte at 188-byte intervals.
    if data.first == 0x47 { return "ts" }
    // fMP4 / ISO-BMFF: 'ftyp' or 'styp' box type at bytes 4...8.
    if data.count >= 8 {
      let boxType = data.subdata(in: 4..<8)
      if boxType == Data("ftyp".utf8) || boxType == Data("styp".utf8) || boxType == Data("moof".utf8) {
        return "mp4"
      }
    }
    return "ts"
  }
}
