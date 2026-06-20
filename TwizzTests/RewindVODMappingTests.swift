import XCTest

@testable import Twizz

final class RewindVODMappingTests: XCTestCase {
  private let broadcastStart = Date(timeIntervalSince1970: 1_000_000)

  func testWallClockFromPlayerTimeUsesAnchorOffset() {
    let anchorDate = Date(timeIntervalSince1970: 2_000_000)
    let anchorTime = 600.0  // player is 600s into its timeline at anchorDate

    // 60s earlier on the timeline → 60s earlier in wall clock.
    let earlier = RewindVODMapping.wallClock(
      playerTime: 540, anchorTime: anchorTime, anchorDate: anchorDate)
    XCTAssertEqual(earlier.timeIntervalSince1970, 2_000_000 - 60, accuracy: 0.001)

    // 30s later on the timeline → 30s later in wall clock.
    let later = RewindVODMapping.wallClock(
      playerTime: 630, anchorTime: anchorTime, anchorDate: anchorDate)
    XCTAssertEqual(later.timeIntervalSince1970, 2_000_000 + 30, accuracy: 0.001)
  }

  func testVODOffsetIsSecondsSinceBroadcastStart() {
    let wallClock = broadcastStart.addingTimeInterval(1234)
    XCTAssertEqual(
      RewindVODMapping.vodOffset(forWallClock: wallClock, broadcastStart: broadcastStart),
      1234, accuracy: 0.001)
  }

  func testVODOffsetClampsBeforeBroadcastStart() {
    let wallClock = broadcastStart.addingTimeInterval(-50)
    XCTAssertEqual(
      RewindVODMapping.vodOffset(forWallClock: wallClock, broadcastStart: broadcastStart),
      0, accuracy: 0.001)
  }

  func testWallClockForVODOffsetIsInverseOfVODOffset() {
    let original = broadcastStart.addingTimeInterval(987)
    let offset = RewindVODMapping.vodOffset(
      forWallClock: original, broadcastStart: broadcastStart)
    let roundTripped = RewindVODMapping.wallClock(
      forVODOffset: offset, broadcastStart: broadcastStart)
    XCTAssertEqual(
      roundTripped.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
  }

  func testWallClockForVODOffsetClampsNegativeOffset() {
    let result = RewindVODMapping.wallClock(forVODOffset: -10, broadcastStart: broadcastStart)
    XCTAssertEqual(
      result.timeIntervalSince1970, broadcastStart.timeIntervalSince1970, accuracy: 0.001)
  }

  /// End-to-end: a live rewind position maps to a VOD offset and back to the same
  /// wall clock, so the hand-off lands on the same content moment in both
  /// directions.
  func testLiveToVODToLiveRoundTrip() {
    let anchorDate = broadcastStart.addingTimeInterval(3600)  // 1h into the broadcast
    let anchorTime = 3600.0
    let rewoundPlayerTime = 3000.0  // rewound 10 min from the anchor

    let liveWallClock = RewindVODMapping.wallClock(
      playerTime: rewoundPlayerTime, anchorTime: anchorTime, anchorDate: anchorDate)
    let offset = RewindVODMapping.vodOffset(
      forWallClock: liveWallClock, broadcastStart: broadcastStart)
    XCTAssertEqual(offset, 3000, accuracy: 0.001)

    let backToLive = RewindVODMapping.wallClock(
      forVODOffset: offset, broadcastStart: broadcastStart)
    XCTAssertEqual(
      backToLive.timeIntervalSince1970, liveWallClock.timeIntervalSince1970, accuracy: 0.001)
  }
}
