import XCTest

@testable import Twozz

final class LowLatencyHLSProxyTests: XCTestCase {
  private func makeProxy() -> LowLatencyHLSProxy {
    LowLatencyHLSProxy(headers: [:])
  }

  private let source = URL(string: "https://video.example/chunked.m3u8")!

  func testTelemetryCancellationIsCountedExactlyOnce() {
    let proxy = makeProxy()
    let cancelled = proxy.beginTelemetryRequest(host: "video.example", uptime: 0)
    let active = proxy.beginTelemetryRequest(host: "video.example", uptime: 1)
    XCTAssertTrue(proxy.finishTelemetryRequest(cancelled, cancelled: true, uptime: 2))
    XCTAssertFalse(proxy.finishTelemetryRequest(cancelled, errorCode: -999, uptime: 3))
    XCTAssertEqual(proxy.telemetrySnapshot.activeRequestCount, 1)
    XCTAssertEqual(proxy.telemetrySnapshot.cancelledRequestCount, 1)
    XCTAssertEqual(proxy.telemetrySnapshot.failedRequestCount, 0)
    proxy.finishTelemetryRequest(active, status: 200, responseBytes: 1_024, uptime: 4)
    XCTAssertEqual(proxy.telemetrySnapshot.activeRequestCount, 0)
    XCTAssertEqual(proxy.telemetrySnapshot.lastRequestDurationMilliseconds, 3_000)
  }

  func testTelemetryResetRejectsStaleCallbacksAndKeepsFailureEvidence() {
    let proxy = makeProxy()
    let stale = proxy.beginTelemetryRequest(host: "old.example", uptime: 0)
    proxy.resetTelemetry()
    let failed = proxy.beginTelemetryRequest(host: "new.example", uptime: 1)
    XCTAssertFalse(proxy.finishTelemetryRequest(stale, status: 500, uptime: 2))
    proxy.finishTelemetryRequest(failed, status: 503, uptime: 3)
    let succeeded = proxy.beginTelemetryRequest(host: "new.example", uptime: 4)
    proxy.finishTelemetryRequest(succeeded, status: 200, uptime: 5)
    let snapshot = proxy.telemetrySnapshot
    XCTAssertEqual(snapshot.requestCount, 2)
    XCTAssertEqual(snapshot.failedRequestCount, 1)
    XCTAssertEqual(snapshot.lastStatusCode, 200)
    XCTAssertEqual(snapshot.lastFailureStatusCode, 503)
    XCTAssertEqual(snapshot.lastFailureUptime, 3)
    XCTAssertEqual(snapshot.activeRequestCount, 0)
  }

  func testPlaylistTelemetryCountsPromotionAndClearsRetention() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(mediaSequence: 100, segments: [("a", 2), ("b", 2)], prefetch: ["c"])
    _ = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: true)
    XCTAssertEqual(proxy.telemetrySnapshot.lastPromotedPrefetchCount, 1)
    XCTAssertEqual(proxy.telemetrySnapshot.retainedSeconds, 4)
    _ = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: false, retainHistory: false)
    XCTAssertEqual(proxy.telemetrySnapshot.lastPromotedPrefetchCount, 0)
    XCTAssertEqual(proxy.telemetrySnapshot.retainedSeconds, 0)
    XCTAssertEqual(proxy.telemetrySnapshot.retainedSegmentCount, 0)
    XCTAssertEqual(proxy.telemetrySnapshot.mediaPlaylistRefreshes, 2)
  }

  /// A minimal Twitch-style live media playlist with two real segments and one
  /// prefetch tag. `durations` sets each real segment's `#EXTINF`.
  private func mediaPlaylist(
    mediaSequence: Int,
    segments: [(name: String, duration: Double)],
    prefetch: [String]
  ) -> String {
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:2",
      "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
    ]
    for seg in segments {
      lines.append("#EXTINF:\(String(format: "%.3f", seg.duration)),")
      lines.append("https://video.example/\(seg.name).ts")
    }
    for url in prefetch {
      lines.append("#EXT-X-TWITCH-PREFETCH:https://video.example/\(url).ts")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Prefetch promotion

  func testPromotesPrefetchIntoRealSegment() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("seg100", 2), ("seg101", 2)],
      prefetch: ["seg102"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)

    XCTAssertFalse(out.contains("#EXT-X-TWITCH-PREFETCH"), "prefetch tag should be rewritten")
    XCTAssertTrue(out.contains("https://video.example/seg102.ts"), "prefetch URL should be promoted")
    XCTAssertTrue(out.contains("https://video.example/seg100.ts"))
  }

  func testPrefetchOmittedWhenPromotionDisabled() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("seg100", 2), ("seg101", 2)],
      prefetch: ["seg102"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: false, retainHistory: false)

    XCTAssertFalse(out.contains("seg102.ts"), "prefetch should not appear when promotion is off")
    XCTAssertTrue(out.contains("seg101.ts"), "real segments still pass through")
  }

  /// Twitch prefetch tags carry no duration, so the proxy synthesizes one from
  /// the AVERAGE of the real segments (Streamlink's heuristic) — not the last one.
  func testPromotedPrefetchUsesAverageSegmentDuration() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("a", 2), ("b", 4)],
      prefetch: ["c"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)

    // (2 + 4) / 2 == 3.000; the naive "last segment" heuristic would give 4.000.
    XCTAssertTrue(
      out.contains("#EXTINF:3.000,\nhttps://video.example/c.ts"),
      "expected averaged 3.000s prefetch duration, got:\n\(out)")
  }

  // MARK: - DVR (Stream Rewind) retention

  func testRetentionGrowsThenSlidesWindow() {
    let proxy = makeProxy()
    let window: Double = 5  // seconds; each segment is 2s

    // First refresh: two 2s segments (4s total) fit under the 5s window.
    _ = proxy.rewriteMediaPlaylistForTesting(
      mediaPlaylist(mediaSequence: 100, segments: [("seg100", 2), ("seg101", 2)], prefetch: []),
      sourceURL: source, promotePrefetch: false, retainHistory: true, windowSeconds: window)

    // Second refresh advances by one segment; total would be 6s, so the oldest
    // (seg100) is evicted and the media sequence advances with it.
    let out = proxy.rewriteMediaPlaylistForTesting(
      mediaPlaylist(mediaSequence: 101, segments: [("seg101", 2), ("seg102", 2)], prefetch: []),
      sourceURL: source, promotePrefetch: false, retainHistory: true, windowSeconds: window)

    XCTAssertFalse(out.contains("seg100.ts"), "oldest segment should be evicted past the window")
    XCTAssertTrue(out.contains("seg101.ts"))
    XCTAssertTrue(out.contains("seg102.ts"))
    XCTAssertTrue(out.contains("#EXT-X-MEDIA-SEQUENCE:101"), "media sequence should advance:\n\(out)")
  }

  // MARK: - Master playlist rewriting

  func testMasterRewriteReroutesVariantAndMediaURIsOntoCustomScheme() {
    let proxy = makeProxy()
    let master = [
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",URI=\"https://video.example/audio.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080",
      "https://video.example/chunked.m3u8",
    ].joined(separator: "\n")

    let out = proxy.rewriteMasterPlaylistForTesting(master)

    XCTAssertTrue(out.contains("twozz-ll://video.example/chunked.m3u8"))
    XCTAssertTrue(out.contains("URI=\"twozz-ll://video.example/audio.m3u8\""))
    XCTAssertFalse(out.contains("https://video.example/chunked.m3u8"))
  }

  // MARK: - Predictive instability

  /// Builds a media playlist with explicit per-segment durations and an optional
  /// per-segment discontinuity flag, plus an explicit discontinuity-sequence — the
  /// inputs the predictive scorer reads.
  private func instabilityPlaylist(
    mediaSequence: Int,
    targetDuration: Int = 2,
    discontinuitySequence: Int = 0,
    segments: [(name: String, duration: Double, discontinuity: Bool)]
  ) -> String {
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:\(targetDuration)",
      "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
      "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)",
    ]
    for seg in segments {
      if seg.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
      lines.append("#EXTINF:\(String(format: "%.3f", seg.duration)),")
      lines.append("https://video.example/\(seg.name).ts")
    }
    return lines.joined(separator: "\n")
  }

  /// Feeds a sequence of refreshes through the proxy and returns the final verdict.
  private func feedRefreshes(_ proxy: LowLatencyHLSProxy, _ playlists: [String]) {
    for playlist in playlists {
      _ = proxy.rewriteMediaPlaylistForTesting(
        playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)
    }
  }

  /// A flawless stream — segments exactly at target, sequence advancing every
  /// refresh, no discontinuities — must never be predicted unstable.
  func testCleanStreamIsNotPredictedUnstable() {
    let proxy = makeProxy()
    let playlists = (0..<12).map { i in
      instabilityPlaylist(
        mediaSequence: 100 + i,
        segments: [
          (name: "seg\(100 + i)", duration: 2, discontinuity: false),
          (name: "seg\(101 + i)", duration: 2, discontinuity: false),
          (name: "seg\(102 + i)", duration: 2, discontinuity: false),
        ])
    }
    feedRefreshes(proxy, playlists)

    XCTAssertFalse(proxy.predictedUnstable, "a clean stream must keep full low latency")
    XCTAssertEqual(proxy.instabilityDiagnostics.score, 0, accuracy: 0.0001)
  }

  /// A stalled encoder — the media sequence (and segment list) never advances
  /// across refreshes — should trip the predictor.
  func testStalledMediaSequenceIsPredictedUnstable() {
    let proxy = makeProxy()
    // Identical playlist five times: the tail sequence never moves.
    let frozen = instabilityPlaylist(
      mediaSequence: 100,
      segments: [
        (name: "seg100", duration: 2, discontinuity: false),
        (name: "seg101", duration: 2, discontinuity: false),
        (name: "seg102", duration: 2, discontinuity: false),
      ])
    feedRefreshes(proxy, Array(repeating: frozen, count: 5))

    XCTAssertTrue(proxy.predictedUnstable, "a non-advancing media sequence signals a stalled encoder")
  }

  /// Irregular `#EXTINF` is non-discriminating — real known-good Twitch channels
  /// (e.g. a healthy Rocket League stream) read off-cadence on essentially every
  /// refresh — so even a long sustained run of off-cadence refreshes must NOT trip
  /// the predictor on its own. Its total contribution is capped at
  /// `irregularIsolatedScoreCap` (1.0), well below the 3.0 threshold; a genuine bad
  /// encoder is caught by the media-sequence-stall signal and the reactive watchdog.
  func testSustainedIrregularDoesNotSoloTrip() {
    let proxy = makeProxy()
    feedRefreshes(proxy, (0..<12).map(irregularRefresh))

    XCTAssertFalse(
      proxy.predictedUnstable,
      "irregular #EXTINF fires on good streams too and must never solo-trip the predictor")
    XCTAssertEqual(
      proxy.instabilityDiagnostics.score, LowLatencyHLSProxy.irregularIsolatedScoreCap,
      accuracy: 0.0001, "off-cadence contribution is capped at 1.0")
  }

  /// Helper: a refresh whose body segments are off-cadence (a struggling encoder),
  /// with an advancing media sequence so the *only* signal is irregular `#EXTINF`.
  private func irregularRefresh(_ i: Int) -> String {
    instabilityPlaylist(
      mediaSequence: 100 + i,
      segments: [
        (name: "a\(i)", duration: 0.4, discontinuity: false),
        (name: "b\(i)", duration: 3.6, discontinuity: false),
        (name: "c\(i)", duration: 2, discontinuity: false),
      ])
  }

  /// Helper: a clean, regular-cadence refresh with an advancing media sequence.
  private func cleanRefresh(_ i: Int) -> String {
    instabilityPlaylist(
      mediaSequence: 100 + i,
      segments: [
        (name: "x\(i)", duration: 2, discontinuity: false),
        (name: "y\(i)", duration: 2, discontinuity: false),
        (name: "z\(i)", duration: 2, discontinuity: false),
      ])
  }

  /// SUSTAINED irregular jitter must NOT solo-trip: with the escalation removed,
  /// off-cadence refreshes accumulate only up to the isolated cap (1.0). (Kept as a
  /// distinct case from the 12-refresh test above to guard the 3-consecutive shape
  /// that previously escalated to 5.0.)
  func testThreeConsecutiveIrregularStayCapped() {
    let proxy = makeProxy()
    feedRefreshes(proxy, (0..<3).map(irregularRefresh))

    let snap = proxy.instabilityDiagnostics
    XCTAssertFalse(snap.predictedUnstable, "consecutive off-cadence jitter must not trip on its own")
    XCTAssertEqual(
      snap.score, LowLatencyHLSProxy.irregularIsolatedScoreCap, accuracy: 0.0001,
      "irregular contribution is capped at 1.0, not escalated past 3.0")
  }

  /// An ad break splices in and out — an irregular refresh here and there with a
  /// clean run between — stays capped: the isolated-contribution bucket tops out at
  /// `irregularIsolatedScoreCap` (1.0), so *two* off-cadence boundary refreshes
  /// together still score only 1.0, nowhere near the 3.0 threshold.
  func testIsolatedIrregularSplicesStayCapped() {
    let proxy = makeProxy()
    // Two irregular refreshes separated by clean ones — splice-in, run, splice-out.
    let playlists = [
      cleanRefresh(0),
      irregularRefresh(1),
      cleanRefresh(2),
      irregularRefresh(3),
      cleanRefresh(4),
      cleanRefresh(5),
    ]
    feedRefreshes(proxy, playlists)

    let snap = proxy.instabilityDiagnostics
    XCTAssertFalse(
      snap.predictedUnstable,
      "isolated splice refreshes must not escalate the way sustained jitter does")
    XCTAssertEqual(
      snap.score, LowLatencyHLSProxy.irregularIsolatedScoreCap, accuracy: 0.0001,
      "two isolated irregular refreshes are capped at the isolated bucket (1.0), not 2.0 or 3.0")
  }

  /// The exact worst-case ad break: off-cadence segments AND a new discontinuity
  /// at *both* the splice-in and splice-out boundaries, separated by a clean ad
  /// run — the failure mode the isolated cap closes. Even with two disc + two
  /// irregular boundary refreshes, the irregular bucket caps at 1.0 and the
  /// discontinuity bucket caps at 1.5, so the total tops out at 2.5, safely below
  /// the 3.0 threshold. (Without the isolated cap this would reach ~3.5 and trip.)
  func testAdSpliceDiscAndIrregularStaysUnderThreshold() {
    let proxy = makeProxy()
    let spliceIn = instabilityPlaylist(
      mediaSequence: 101, discontinuitySequence: 0,
      segments: [
        (name: "ad-a", duration: 0.4, discontinuity: true),
        (name: "ad-b", duration: 3.6, discontinuity: false),
        (name: "ad-c", duration: 2, discontinuity: false),
      ])
    let spliceOut = instabilityPlaylist(
      mediaSequence: 105, discontinuitySequence: 1,
      segments: [
        (name: "ad-d", duration: 0.4, discontinuity: true),
        (name: "ad-e", duration: 3.6, discontinuity: false),
        (name: "ad-f", duration: 2, discontinuity: false),
      ])
    let playlists = [
      cleanRefresh(0),
      spliceIn,
      cleanRefresh(2),
      cleanRefresh(3),
      spliceOut,
      cleanRefresh(6),
      cleanRefresh(7),
    ]
    feedRefreshes(proxy, playlists)

    let snap = proxy.instabilityDiagnostics
    XCTAssertFalse(
      snap.predictedUnstable, "a two-boundary ad break must not trip the predictor")
    XCTAssertLessThan(snap.score, LowLatencyHLSProxy.predictedUnstableScoreThreshold)
    XCTAssertEqual(snap.score, 2.5, accuracy: 0.0001, "irregular cap 1.0 + disc cap 1.5 = 2.5")
  }

  /// Discontinuities alone — as a normal ad break produces — are capped below the
  /// trip threshold, so an otherwise-healthy stream is NOT predicted unstable.
  func testDiscontinuitiesAloneDoNotFalseTrip() {
    let proxy = makeProxy()
    // Every refresh introduces a fresh discontinuity, but durations stay regular
    // and the sequence keeps advancing — mimicking repeated ad markers.
    let playlists = (0..<12).map { i in
      instabilityPlaylist(
        mediaSequence: 100 + i,
        discontinuitySequence: i,
        segments: [
          (name: "seg\(100 + i)", duration: 2, discontinuity: false),
          (name: "seg\(101 + i)", duration: 2, discontinuity: false),
          (name: "seg\(102 + i)", duration: 2, discontinuity: true),
        ])
    }
    feedRefreshes(proxy, playlists)

    XCTAssertFalse(
      proxy.predictedUnstable,
      "discontinuities are capped so an ad break can't trip the predictor alone")
    XCTAssertLessThan(
      proxy.instabilityDiagnostics.score, LowLatencyHLSProxy.predictedUnstableScoreThreshold)
  }

  /// The verdict is per channel session — resetting clears a latched prediction.
  func testResetClearsPrediction() {
    let proxy = makeProxy()
    let frozen = instabilityPlaylist(
      mediaSequence: 100,
      segments: [
        (name: "seg100", duration: 2, discontinuity: false),
        (name: "seg101", duration: 2, discontinuity: false),
        (name: "seg102", duration: 2, discontinuity: false),
      ])
    feedRefreshes(proxy, Array(repeating: frozen, count: 5))
    XCTAssertTrue(proxy.predictedUnstable)

    proxy.resetInstabilityPrediction()
    // resetInstabilityPrediction dispatches onto the delegate queue; a subsequent
    // rewrite (also on that queue) is guaranteed to observe the cleared state.
    _ = proxy.rewriteMediaPlaylistForTesting(
      instabilityPlaylist(
        mediaSequence: 200,
        segments: [(name: "x", duration: 2, discontinuity: false)]),
      sourceURL: source, promotePrefetch: true, retainHistory: false)

    XCTAssertFalse(proxy.predictedUnstable, "reset must forget the prior channel session's verdict")
  }

  // MARK: - Output encoding (direct-Data writer) invariants

  /// The rewritten body must join lines with `"\n"` and carry no trailing
  /// newline — exactly matching the previous `joined(separator: "\n")`
  /// behaviour the direct-`Data` writer replaced.
  func testRewrittenBodyHasNoTrailingNewline() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("seg100", 2), ("seg101", 2)],
      prefetch: ["seg102"])
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)

    XCTAssertFalse(out.hasSuffix("\n"), "no trailing newline should be introduced")
    XCTAssertFalse(out.contains("\n\n"), "lines should be single-`\\n`-separated")
  }

  /// A passthrough rewrite (no promotion, no retention, no prefetch) must
  /// reproduce the source bytes exactly — including CRLF line endings, which
  /// the parser splits on `"\n"` (leaving `\r` attached) and the writer rejoins
  /// with `"\n"`. This guards the direct-`Data` writer against mangling `\r\n`.
  func testCRLFPassthroughIsByteExact() {
    let proxy = makeProxy()
    let lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:2",
      "#EXT-X-MEDIA-SEQUENCE:100",
      "#EXTINF:2.000,",
      "https://video.example/seg100.ts",
      "#EXTINF:2.000,",
      "https://video.example/seg101.ts",
    ]
    let crlf = lines.joined(separator: "\r\n")  // no trailing newline
    let out = proxy.rewriteMediaPlaylistForTesting(
      crlf, sourceURL: source, promotePrefetch: false, retainHistory: false)

    XCTAssertEqual(out, crlf, "CRLF passthrough must be byte-for-byte identical")
  }

  // MARK: - DVR growth safety net

  /// A degenerate stream whose segments all report zero duration would never
  /// trip the seconds-based window slide, so the retained history (and its
  /// `seenURLs` set) must instead be bounded by the hard segment-count cap.
  func testZeroDurationHistoryIsCappedBySegmentCount() {
    let proxy = makeProxy()
    let overflow = LowLatencyHLSProxy.maxRetainedSegments + 250
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:0",
      "#EXT-X-MEDIA-SEQUENCE:0",
    ]
    for i in 0..<overflow {
      lines.append("#EXTINF:0.000,")
      lines.append("https://video.example/seg\(i).ts")
    }
    _ = proxy.rewriteMediaPlaylistForTesting(
      lines.joined(separator: "\n"),
      sourceURL: source, promotePrefetch: false, retainHistory: true, windowSeconds: 1800)

    XCTAssertEqual(
      proxy.retainedSegmentCountForTesting(sourceURL: source),
      LowLatencyHLSProxy.maxRetainedSegments,
      "zero-duration history must be capped by the segment-count safety net")
  }
}