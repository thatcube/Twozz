import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

extension PlayerView {
  /// True while playing a recorded broadcast rather than a live stream — either a
  /// VOD session opened from the channel page (`vod`) or an active Stream Rewind
  /// hand-off into the live broadcast's in-progress VOD (`liveVODHandoff`).
  var isVOD: Bool { activeVOD != nil }

  /// The VOD currently being played, whichever source it came from. `nil` while
  /// playing live.
  var activeVOD: VODContext? {
    if let vod { return vod }
    if let handoff = liveVODHandoff, handoff.isActive {
      return VODContext(id: handoff.broadcast.id, title: handoff.title)
    }
    return nil
  }

  /// True when this player was launched on a live channel (as opposed to a
  /// recorded-broadcast session from the channel page). Only live sessions can
  /// hand off to — and return from — the in-progress broadcast VOD.
  var isLiveSession: Bool { vod == nil }

  /// VODs always expose the transport bar (seek is essential); live exposes it
  /// only when the user has Stream Rewind enabled.
  var rewindAvailable: Bool { isVOD || streamRewindEnabled }

  /// The focus target that "holds" chat while the viewer scrolls it. Live keeps
  /// focus on the composer (tvOS can't reliably focus a ScrollView); VODs have no
  /// composer, so a dedicated invisible scroller target stands in.
  var chatFocusAnchor: Focusable { isVOD ? .chatScroller : .chatInput }

  /// Where focus lands when the viewer leaves an active chat scroll via Back:
  /// the live composer (so they can immediately type) or, on a VOD (no
  /// composer), the collapse-chat button. Never `.chatScroller`, which would
  /// immediately re-pause the replay.
  var chatScrollExitFocus: Focusable { isVOD ? .chatToggle : .chatInput }

  /// The seek bar is reachable ONLY by an explicit up-press from a control-row
  /// button (`requestSeekBarFocus`, which sets `seekBarRequested`). It is
  /// focusable only while it actually holds focus or has just been requested,
  /// which means it never sits in the focus engine as a silent neighbour above
  /// the control row — so a horizontal swipe that carries a little upward drift
  /// can't fling focus onto it, and from rest/chat it isn't a magnet either.
  var scrubberFocusable: Bool {
    focus == .rewindScrubber || seekBarRequested
  }

  /// Control-row buttons in left-to-right visual order. Drives the row-membership
  /// check below.
  var controlOrder: [Focusable] { [.streamInfo, .quality, .chatSettingsButton, .chatToggle] }

  func isControlRowButton(_ f: Focusable?) -> Bool {
    guard let f else { return false }
    return controlOrder.contains(f)
  }

  /// Whether `button` is dropped from the focus engine right now. All four control
  /// buttons are natively focusable together so tvOS's focus engine moves focus
  /// between them instantly and reliably on every press (no programmatic stepping,
  /// no throttle, no dropped or delayed moves). They are removed *only* while chat
  /// is being scrolled, when focus is trapped on the composer. The row is wrapped
  /// in a `.focusSection()` so a swipe can roam the buttons but can't escape to the
  /// chat pane; the seek bar and composer keep their own gates. Expressed as
  /// "removed" so we apply `.focusable(false)` (never `.focusable(true)`, which
  /// hijacks a Button's Select press on tvOS).
  func controlButtonRemoved(_ button: Focusable) -> Bool {
    isChatScrolling
  }

  /// Whether the chat composer (and its send button) should be dropped from the
  /// focus engine. Besides the rewind-bar case, we remove it whenever focus sits
  /// on a control button UNLESS we've just armed a deliberate hop into it
  /// (`chatInputArmed`). Because the other control buttons are pulled out of the
  /// engine during a swipe, the composer would otherwise be the nearest focusable
  /// view to the right of the row, so a swipe would fling onto it (or sail past
  /// the collapse button into chat). Keeping it out until an armed, throttled hop
  /// makes collapse→chat as deliberate as every other step.
  func chatInputFocusBlocked() -> Bool {
    if focus == .rewindScrubber { return true }
    if isControlRowButton(focus) { return !chatInputArmed }
    return false
  }

  /// Jump focus straight to `button`. Used for reveals and deliberate cross-section
  /// jumps (e.g. dropping from the seek bar).
  func activateControl(_ button: Focusable) {
    focus = button
  }

  /// The deliberate hop from the collapse button into the chat input. The composer
  /// is otherwise kept out of the focus engine while focus sits on a control button
  /// (see `chatInputFocusBlocked`), so a swipe roaming the control row can't sail
  /// into chat; only this explicit right-press arms it and moves focus there.
  func stepToChatInput(from source: Focusable) {
    guard showChat else { return }
    chatInputArmed = true
    focus = chatFocusAnchor
  }

  /// Handle an up-press from a control button: reveal the seek bar. Setting
  /// `seekBarRequested` makes the bar focusable for this assignment (it's
  /// otherwise kept out of the engine so it can't be a vertical magnet).
  func requestSeekBarFocus() {
    guard rewindAvailable else { return }
    seekBarRequested = true
    focus = .rewindScrubber
  }

  /// Spoken value for the rewind/seek bar's `accessibilityValue`: VODs read
  /// "elapsed of total", live reads "Live" at the edge or "N behind live".
  var rewindAccessibilityValue: String {
    func spoken(_ seconds: Double) -> String {
      let total = max(0, Int(seconds.rounded()))
      let m = total / 60
      let s = total % 60
      if m > 0 { return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")" }
      return "\(s) second\(s == 1 ? "" : "s")"
    }
    if rewindReadout.isVOD {
      return "\(spoken(rewindReadout.elapsedSeconds)) of \(spoken(rewindReadout.totalSeconds))"
    }
    if rewindReadout.isAtLiveEdge { return "Live" }
    return "\(spoken(rewindReadout.behindLiveSeconds)) behind live"
  }

  /// Selectable VOD playback rates, cycled by the speed control.
  var vodSpeedOptions: [Float] { [0.5, 1.0, 1.25, 1.5, 2.0] }

  /// Compact label for the current VOD rate, e.g. "1×", "1.5×", "0.5×".
  var vodSpeedLabel: String { String(format: "%g×", Double(vodPlaybackRate)) }
}
