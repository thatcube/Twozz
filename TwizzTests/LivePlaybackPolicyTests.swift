import XCTest

@testable import Twizz

final class LivePlaybackPolicyTests: XCTestCase {
  func testDefaultProfileIsLowerLatency() {
    XCTAssertEqual(LivePlaybackProfile.default, .lowerLatency)
  }

  func testProfileRawValuesAreStable() {
    // Persisted via @AppStorage — changing these would silently reset users.
    XCTAssertEqual(LivePlaybackProfile.lowerLatency.rawValue, "lowerLatency")
    XCTAssertEqual(LivePlaybackProfile.higherQuality.rawValue, "higherQuality")
  }

  func testPickerLabels() {
    XCTAssertEqual(LivePlaybackProfile.lowerLatency.pickerLabel, "Auto · Low Latency")
    XCTAssertEqual(LivePlaybackProfile.higherQuality.pickerLabel, "Auto · High Quality")
  }

  func testLowerLatencyPolicyIsShallowAndCatchesUp() {
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 3)
    XCTAssertTrue(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.catchUpThresholdSeconds, 2)
    XCTAssertEqual(policy.maxCatchUpRate, 1.12, accuracy: 0.0001)
    XCTAssertGreaterThan(policy.catchUpRampPerSecond, 0)
  }

  func testLowerLatencyEnablesAntiStallSlowdown() {
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertEqual(policy.minPlaybackRate, 0.90, accuracy: 0.0001)
    XCTAssertEqual(policy.slowdownBufferFloorSeconds, 1.5)
    XCTAssertEqual(policy.catchUpHealthyBufferSeconds, 2.0)
  }

  func testLowerLatencyCatchUpTargetIsTighterThanSeekLanding() {
    // Catch-up must chase tighter than the live-edge seek landing point,
    // otherwise we always start inside the target and the rate never engages.
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertLessThan(policy.catchUpThresholdSeconds, 3.5)
  }

  func testLowerLatencyCatchUpHealthyBufferClearsSlowdownFloor() {
    // The two rate arms need a dead-band between them so they don't flap.
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertGreaterThan(policy.catchUpHealthyBufferSeconds, policy.slowdownBufferFloorSeconds)
  }

  func testHigherQualityDisablesRateGames() {
    let policy = LivePlaybackPolicy.live(profile: .higherQuality, isPinned: false)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    // minPlaybackRate of 1.0 disables the anti-stall slow-down arm.
    XCTAssertEqual(policy.minPlaybackRate, 1.0, accuracy: 0.0001)
    XCTAssertEqual(policy.maxCatchUpRate, 1.0, accuracy: 0.0001)
  }

  func testPinnedRenditionDisablesRateGames() {
    for profile in LivePlaybackProfile.allCases {
      let policy = LivePlaybackPolicy.live(profile: profile, isPinned: true)
      XCTAssertEqual(policy.minPlaybackRate, 1.0, accuracy: 0.0001)
      XCTAssertEqual(policy.maxCatchUpRate, 1.0, accuracy: 0.0001)
    }
  }

  func testHigherQualityPolicyIsDeepAndDoesNotCatchUp() {
    let policy = LivePlaybackPolicy.live(profile: .higherQuality, isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 8)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.maxCatchUpRate, 1.0, accuracy: 0.0001)
  }

  func testPinnedRenditionIgnoresProfileAndNeverCatchesUp() {
    for profile in LivePlaybackProfile.allCases {
      let policy = LivePlaybackPolicy.live(profile: profile, isPinned: true)
      XCTAssertEqual(policy.preferredForwardBufferDuration, 8)
      XCTAssertFalse(policy.enablesGentleCatchUp)
      XCTAssertEqual(policy.catchUpThresholdSeconds, .greatestFiniteMagnitude)
    }
  }

  func testStabilityFallbackIsDeepBufferedAndDoesNotChaseEdge() {
    let policy = LivePlaybackPolicy.stabilityFallback
    // Deep buffer to absorb an erratic source.
    XCTAssertGreaterThanOrEqual(policy.preferredForwardBufferDuration, 12)
    // Never chase the live edge — that's what caused the stall/rewind loop.
    XCTAssertFalse(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.maxCatchUpRate, 1.0, accuracy: 0.0001)
    XCTAssertEqual(policy.catchUpThresholdSeconds, .greatestFiniteMagnitude)
  }

  func testStabilityFallbackKeepsAntiStallSlowdown() {
    let policy = LivePlaybackPolicy.stabilityFallback
    // The anti-stall slow-down stays as the last line of defence.
    XCTAssertEqual(policy.minPlaybackRate, 0.90, accuracy: 0.0001)
    XCTAssertGreaterThan(policy.slowdownBufferFloorSeconds, 0)
  }

  func testStabilityFallbackBuffersDeeperThanNormalProfiles() {
    let stability = LivePlaybackPolicy.stabilityFallback
    let lowLatency = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    let highQuality = LivePlaybackPolicy.live(profile: .higherQuality, isPinned: false)
    XCTAssertGreaterThan(stability.preferredForwardBufferDuration, lowLatency.preferredForwardBufferDuration)
    XCTAssertGreaterThan(stability.preferredForwardBufferDuration, highQuality.preferredForwardBufferDuration)
  }
}
