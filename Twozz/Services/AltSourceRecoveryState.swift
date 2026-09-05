import Foundation

/// One automatic fresh resolution per source selection, not per "playing" tick.
/// Clock progress is the recovery evidence; AVPlayer can remain ready after a
/// terminal media error.
struct AltSourceRecoveryState {
  let generation = UUID()
  private(set) var retryCount = 0
  private var terminalFailure = false
  private var lastClock: Double?
  private var lastProgressAt: TimeInterval?

  var canRetry: Bool { retryCount == 0 }

  static func retryDelay(sinceLastAttempt elapsed: TimeInterval) -> TimeInterval {
    max(0, 10 - elapsed)
  }

  mutating func beginItem() {
    terminalFailure = false
    lastClock = nil
    lastProgressAt = nil
  }

  mutating func noteTerminalFailure() {
    terminalFailure = true
  }

  mutating func beginRetry() -> Bool {
    guard canRetry else { return false }
    retryCount += 1
    return true
  }

  mutating func needsRecovery(clock: Double, shouldPlay: Bool, now: TimeInterval) -> Bool {
    guard shouldPlay else {
      lastClock = nil
      lastProgressAt = nil
      return false
    }
    if terminalFailure { return true }
    if lastProgressAt == nil { lastProgressAt = now }
    if clock.isFinite, lastClock == nil || abs(clock - (lastClock ?? clock)) > 0.05 {
      lastClock = clock
      lastProgressAt = now
    }
    return now - (lastProgressAt ?? now) >= 20
  }
}
