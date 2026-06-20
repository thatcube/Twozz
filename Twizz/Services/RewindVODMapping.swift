import Foundation

/// Pure timeline math for the Stream Rewind ⇄ in-progress VOD hand-off, factored
/// out of `PlayerView` so it can be unit-tested without a player.
///
/// The live and VOD timelines share one anchor: **wall-clock time**. The live
/// playlist carries `#EXT-X-PROGRAM-DATE-TIME`, so any live player-timeline
/// position maps to a wall-clock instant; the VOD's timeline zero is the
/// broadcast's start. Mapping between the two is therefore just wall-clock
/// arithmetic.
enum RewindVODMapping {
  /// Wall-clock instant for an arbitrary player-timeline position, given the
  /// item's PROGRAM-DATE-TIME anchor (`anchorDate` at `anchorTime`).
  static func wallClock(playerTime: Double, anchorTime: Double, anchorDate: Date) -> Date {
    anchorDate.addingTimeInterval(playerTime - anchorTime)
  }

  /// Offset into the VOD (seconds from the recording's start) for a live rewind
  /// position's wall clock. Clamped at zero — you can't be before the broadcast
  /// began.
  static func vodOffset(forWallClock wallClock: Date, broadcastStart: Date) -> Double {
    max(0, wallClock.timeIntervalSince(broadcastStart))
  }

  /// Wall-clock instant for a VOD offset — the inverse of `vodOffset`, used when
  /// handing back from the VOD to the live DVR window.
  static func wallClock(forVODOffset offset: Double, broadcastStart: Date) -> Date {
    broadcastStart.addingTimeInterval(max(0, offset))
  }
}
