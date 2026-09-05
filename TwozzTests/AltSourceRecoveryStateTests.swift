import XCTest

@testable import Twozz

final class AltSourceRecoveryStateTests: XCTestCase {
  func testTerminalFailureDoesNotDependOnItemStatusOrClock() {
    var state = AltSourceRecoveryState()
    state.noteTerminalFailure()
    XCTAssertTrue(state.needsRecovery(clock: 123, shouldPlay: true, now: 1))
  }

  func testRetryBudgetDoesNotResetWhenPlaybackBrieflyResumes() {
    var state = AltSourceRecoveryState()
    XCTAssertTrue(state.beginRetry())
    state.beginItem()
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 1))
    XCTAssertFalse(state.needsRecovery(clock: 2, shouldPlay: true, now: 2))
    state.noteTerminalFailure()
    XCTAssertTrue(state.needsRecovery(clock: 2, shouldPlay: true, now: 3))
    XCTAssertFalse(state.canRetry)
    XCTAssertFalse(state.beginRetry())
    XCTAssertEqual(state.retryCount, 1)
  }

  func testNewSelectionInvalidatesOldWorkAndResetsBudget() {
    var state = AltSourceRecoveryState()
    let oldGeneration = state.generation
    XCTAssertTrue(state.beginRetry())
    state = AltSourceRecoveryState()
    XCTAssertNotEqual(oldGeneration, state.generation)
    XCTAssertTrue(state.canRetry)
  }

  func testBriefBufferingDoesNotTriggerRecovery() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 0))
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 19))
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 20))
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 39))
    XCTAssertTrue(state.needsRecovery(clock: 1, shouldPlay: true, now: 40))
  }

  func testPauseScrubAndBackgroundTimeDoNotCountAsStalls() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 0))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: false, now: 100))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 200))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 219))
    XCTAssertTrue(state.needsRecovery(clock: 5, shouldPlay: true, now: 220))
  }

  func testTerminalErrorWhilePausedIsRememberedUntilResume() {
    var state = AltSourceRecoveryState()
    state.noteTerminalFailure()
    XCTAssertFalse(state.needsRecovery(clock: 10, shouldPlay: false, now: 10))
    XCTAssertTrue(state.needsRecovery(clock: 10, shouldPlay: true, now: 30))
    state.beginItem()
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 31))
  }

  func testUnknownClockStillHasABoundedStartupDeadline() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: .nan, shouldPlay: true, now: 0))
    XCTAssertTrue(state.needsRecovery(clock: .nan, shouldPlay: true, now: 20))
  }

  func testFreshResolveRespectsCooldown() {
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 0), 10)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 3), 7)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 10), 0)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 100), 0)
  }
}
