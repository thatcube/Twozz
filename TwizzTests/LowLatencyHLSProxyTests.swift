import XCTest

@testable import Twizz

final class LowLatencyHLSProxyTests: XCTestCase {
  private func makeProxy() -> LowLatencyHLSProxy {
    LowLatencyHLSProxy(headers: [:])
  }

  private let source = URL(string: "https://video.example/chunked.m3u8")!

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

    XCTAssertTrue(out.contains("twizz-ll://video.example/chunked.m3u8"))
    XCTAssertTrue(out.contains("URI=\"twizz-ll://video.example/audio.m3u8\""))
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

  /// Exactly two consecutive media-sequence stalls (the strongest, ad-safe
  /// signal) must trip the predictor on their own at the third refresh — the
  /// `stalledRefreshPoints = 2.0` weighting means 2 × 2.0 = 4.0 clears the 3.0
  /// threshold, beating the reactive stall/jump watchdog. The score reaching ≥3.5
  /// proves the 2.0 weight is applied (the old 1.5 weight would total only 3.0).
  func testTwoConsecutiveStallsTripPredictively() {
    let proxy = makeProxy()
    let frozen = instabilityPlaylist(
      mediaSequence: 100,
      segments: [
        (name: "seg100", duration: 2, discontinuity: false),
        (name: "seg101", duration: 2, discontinuity: false),
        (name: "seg102", duration: 2, discontinuity: false),
      ])
    // Refresh 1 establishes the baseline; refreshes 2 and 3 are the two stalls.
    feedRefreshes(proxy, Array(repeating: frozen, count: 3))

    let snap = proxy.instabilityDiagnostics
    XCTAssertTrue(snap.predictedUnstable, "two consecutive stalls should trip at the third refresh")
    XCTAssertGreaterThanOrEqual(
      snap.score, 3.5, "stall weight 2.0 should total 4.0 across two stalls, not 3.0")
    XCTAssertEqual(snap.detail, "media-seq stalled")
  }

  /// Wildly irregular `#EXTINF` durations (a struggling encoder) should trip the
  /// predictor even while the sequence keeps advancing.
  func testIrregularSegmentDurationsArePredictedUnstable() {
    let proxy = makeProxy()
    let playlists = (0..<5).map { i in
      instabilityPlaylist(
        mediaSequence: 100 + i,
        segments: [
          (name: "a\(i)", duration: 0.4, discontinuity: false),
          (name: "b\(i)", duration: 3.6, discontinuity: false),
          (name: "c\(i)", duration: 2, discontinuity: false),
        ])
    }
    feedRefreshes(proxy, playlists)

    XCTAssertTrue(proxy.predictedUnstable, "off-cadence segment durations signal a struggling encoder")
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
}
