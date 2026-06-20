import SwiftUI
import UIKit

// Chat scrolling, paging, and trackpad/hold scroll loops for the chat pane.
extension PlayerView {
  func toggleChatVisibility() {
    showChat.toggle()
    if showChat {
      chatReplayStartMessageID = chat.messages.suffix(chatReplayMessageCount).first?.id
    } else {
      chatReplayStartMessageID = nil
      showChatSettings = false
      cancelSoftPause()
      chatFrozenMessages = nil
    }
  }

  /// Up press while chat is open. First press soft-pauses (read mode with a
  /// countdown). A press while paused promotes to scroll mode and steps up;
  /// press-and-hold repeats. A trackpad swipe scrolls continuously via the
  /// gesture loop, which suppresses these discrete events while it's driving.
  func handleChatUpPress() {
    if isChatScrolling {
      // A swipe also emits these discrete move events; ignore them while the
      // gesture loop is actively scrolling so a swipe doesn't double-step. A
      // press (no recent gesture motion) still steps, and press-and-hold repeats.
      if trackpad.hasController, Date().timeIntervalSince(lastGestureScrollAt) < 0.12 {
        return
      }
      // The hold watcher already drove this; swallow the move event the click
      // emits on release so a hold doesn't tack on an extra step.
      if trackpad.hasController, Date().timeIntervalSince(lastHoldRepeatAt) < 0.3 {
        return
      }
      stepChatScroll(up: true)
    } else if chatSoftPauseRemaining != nil {
      beginChatScrolling()
      stepChatScroll(up: true)
    } else {
      // Ignore an up-swipe that arrives right as focus lands on the composer —
      // that's a diagonal move off the chat-toggle button, not a deliberate
      // pause.
      guard Date().timeIntervalSince(chatInputFocusedAt) > 0.3 else { return }
      startSoftPause()
    }
  }

  /// Down press while chat is open. While actively scrolling, a down press walks
  /// the view *toward newer messages* one step at a time (mirroring how up steps
  /// toward older ones); reaching the live bottom resumes the feed and exits. A
  /// plain soft pause has nothing newer to reveal, so down there just rejoins the
  /// live feed. A continuous down *swipe* scrolls via the gesture loop, which
  /// likewise rejoins live as it nears the bottom.
  func handleChatDownPress() {
    if isChatScrolling {
      if trackpad.hasController, Date().timeIntervalSince(lastGestureScrollAt) < 0.12 {
        return
      }
      if trackpad.hasController, Date().timeIntervalSince(lastHoldRepeatAt) < 0.3 {
        return
      }
      stepChatScroll(up: false)
    } else if chatSoftPauseRemaining != nil {
      resumeChatLive()
    }
  }

  /// Freeze chat for `softPauseSeconds`, counting down then auto-resuming.
  /// Focus is left untouched — this is a lightweight "let me read" pause.
  func startSoftPause() {
    freezeChatSnapshot()
    softPauseTask?.cancel()
    chatSoftPauseRemaining = softPauseSeconds
    softPauseTask = Task {
      var remaining = softPauseSeconds
      while remaining > 0 {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        remaining -= 1
        await MainActor.run {
          chatSoftPauseRemaining = remaining > 0 ? remaining : nil
        }
      }
    }
  }

  /// Capture the live chat list so the reader's view stays put while a busy
  /// channel keeps appending (and trimming) messages underneath. No-op if a
  /// snapshot is already held (a soft pause promoted into a scroll keeps it).
  func freezeChatSnapshot() {
    guard chatFrozenMessages == nil else { return }
    chatFrozenMessages = liveVisibleChatMessages
  }

  func cancelSoftPause() {
    softPauseTask?.cancel()
    softPauseTask = nil
    chatSoftPauseRemaining = nil
  }

  /// Promote a soft pause into manual scroll mode, anchored at the newest message.
  func beginChatScrolling() {
    guard !isChatScrolling else { return }
    freezeChatSnapshot()
    cancelSoftPause()
    isChatScrolling = true
    let msgs = visibleChatMessages
    chatScrollAnchorID = msgs.last?.id
    trackpadScrollIndex = Double(max(0, msgs.count - 1))
    lastSentScrollIndex = msgs.count - 1
    scheduleHide()
    startTrackpadScrollLoop()
    startChatHoldWatcher()
  }

  /// Drive swipe-to-scroll from the Siri Remote trackpad. Runs at ~60 Hz while
  /// scrolling and moves the chat by the finger's *per-frame travel*, so the
  /// chat follows a swipe and a resting/pressing finger (no travel) is left
  /// completely alone — that way it never fights the discrete press handler.
  func startTrackpadScrollLoop() {
    guard trackpad.hasController, trackpadScrollTask == nil else { return }
    trackpadScrollTask = Task { @MainActor in
      var primed = false
      var lastY = 0.0
      // Coasting speed in index-units per frame, carried after the finger lifts.
      var velocity = 0.0
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(16))
        if Task.isCancelled { break }
        guard isChatScrolling else { break }

        let x = Double(trackpad.horizontalValue)
        let y = Double(trackpad.verticalValue)
        let touching =
          abs(x) > chatScrollTouchEpsilon || abs(y) > chatScrollTouchEpsilon

        if !touching {
          // Finger lifted: coast with the velocity built up during the swipe so
          // the chat eases to a stop (momentum) instead of halting dead.
          primed = false
          if abs(velocity) > chatScrollMomentumMin {
            if !applyScrollDelta(velocity) { break }
            velocity *= chatScrollFriction
          } else {
            velocity = 0
          }
          continue
        }
        // A fresh touch (including a press's finger-down) cancels any coast so it
        // doesn't fight the press/step handler, then re-baselines travel.
        if !primed {
          primed = true
          lastY = y
          velocity = 0
          continue
        }
        let dy = y - lastY
        lastY = y
        // A resting or pressing finger (dy ~ 0) is left alone; bleed off any
        // leftover velocity so pausing mid-swipe doesn't later coast.
        guard abs(dy) > chatScrollMoveEpsilon else {
          velocity *= chatScrollFriction
          continue
        }
        lastGestureScrollAt = Date()
        // Up travel (y increases) scrolls toward older messages (lower index).
        let delta = -dy * chatScrollSwipeSensitivity
        // Smooth into the velocity estimate so the handoff to momentum is stable.
        velocity = velocity * 0.35 + delta * 0.65
        if !applyScrollDelta(delta) { break }
      }
      trackpadScrollTask = nil
    }
  }

  /// Move the scroll position by `delta` messages (fractional). Returns false if
  /// the move reached the live bottom and resumed the feed, signalling the loop
  /// to stop.
  @discardableResult
  func applyScrollDelta(_ delta: Double) -> Bool {
    let msgs = visibleChatMessages
    guard !msgs.isEmpty else { return false }
    let lastIndex = Double(msgs.count - 1)
    let idx = trackpadScrollIndex + delta
    // Treat "almost at the live bottom" as the bottom so a quick down-swipe that
    // coasts to a stop a fraction of a message short still rejoins the live feed
    // instead of stranding the chat frozen just above it.
    if idx >= lastIndex - 0.5 {
      resumeChatLive()
      return false
    }
    let clamped = max(0, idx)
    trackpadScrollIndex = clamped
    let target = Int(clamped.rounded())
    guard target != lastSentScrollIndex else { return true }
    lastSentScrollIndex = target
    chatScrollAnchorID = msgs[target].id
    sendChatScroll(to: msgs[target].id, animated: false)
    return true
  }

  /// Continuously auto-scroll while the touch surface is physically *held*
  /// clicked. tvOS gives no press-down/key-repeat event for a directional click
  /// here — only a single move on release — and the live finger position is
  /// unreliable once clicked, so we key off the reliable click button plus the
  /// direction latched at click-down. Scrolls via the same continuous index model
  /// as a swipe (un-animated, accelerating) so a hold feels fluid, not steppy.
  func startChatHoldWatcher() {
    guard trackpad.hasController, chatHoldTask == nil else { return }
    chatHoldTask = Task { @MainActor in
      var pressStart: Date?
      var active = false
      var velocity = 0.0
      // Direction resolved for the current hold. Sticks for the whole hold so the
      // flickery live position can't flip it mid-scroll.
      var heldDir = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(16))
        if Task.isCancelled { break }
        guard isChatScrolling else { break }

        guard trackpad.clickPressed else {
          pressStart = nil
          active = false
          velocity = 0
          heldDir = 0
          continue
        }

        let now = Date()
        if pressStart == nil {
          pressStart = now
          active = false
          velocity = 0
          heldDir = 0
        }
        // Resolve a direction for this hold. Prefer the click-down latch, but if
        // it missed (click registered a frame before the finger position updated)
        // recover from the live dpad/y signal and then stick with it.
        if heldDir == 0 {
          if trackpad.clickLatchedDirection != 0 {
            heldDir = trackpad.clickLatchedDirection
          } else if trackpad.dpadUpPressed || Double(trackpad.verticalValue) > 0.12 {
            heldDir = 1
          } else if trackpad.dpadDownPressed || Double(trackpad.verticalValue) < -0.12 {
            heldDir = -1
          }
        }
        guard heldDir != 0 else { continue }

        // Let an active swipe own the scroll; pause the hold without resetting.
        if Date().timeIntervalSince(lastGestureScrollAt) < 0.12 { continue }
        if !active {
          guard now.timeIntervalSince(pressStart!) >= chatHoldInitialDelay else {
            continue
          }
          active = true
          velocity = chatHoldStartVelocity
        }
        // Up (dir +1) scrolls toward older messages, i.e. a negative index delta.
        let delta = heldDir > 0 ? -velocity : velocity
        lastHoldRepeatAt = now
        if !applyScrollDelta(delta) { break }  // reached the live bottom
        velocity = min(chatHoldMaxVelocity, velocity * chatHoldVelocityAccel)
      }
      chatHoldTask = nil
    }
  }

  func stopChatHold() {
    chatHoldTask?.cancel()
    chatHoldTask = nil
  }

  func stopTrackpadScrollLoop() {
    trackpadScrollTask?.cancel()
    trackpadScrollTask = nil
    stopChatHold()
    lastSentScrollIndex = -1
  }

  /// Advance the scroll anchor by `chatScrollStep` messages and tell ChatView to
  /// scroll there. Scrolling past the newest message resumes the live feed.
  func stepChatScroll(up: Bool) {
    let msgs = visibleChatMessages
    guard !msgs.isEmpty else { return }
    let lastIndex = msgs.count - 1
    let currentIndex: Int = {
      if let id = chatScrollAnchorID, let i = msgs.firstIndex(where: { $0.id == id }) {
        return i
      }
      return lastIndex
    }()

    if up {
      let target = max(0, currentIndex - chatScrollStep)
      // Already at the top — don't re-send the same target (wasted scroll work).
      guard target != currentIndex else { return }
      chatScrollAnchorID = msgs[target].id
      trackpadScrollIndex = Double(target)
      lastSentScrollIndex = target
      sendChatScroll(to: msgs[target].id)
    } else {
      let target = currentIndex + chatScrollStep
      if target >= lastIndex {
        resumeChatLive()
      } else {
        chatScrollAnchorID = msgs[target].id
        trackpadScrollIndex = Double(target)
        lastSentScrollIndex = target
        sendChatScroll(to: msgs[target].id)
      }
    }
    scheduleHide()
  }

  func sendChatScroll(to id: ChatMessage.ID, animated: Bool = true) {
    chatScrollNonce += 1
    // Anchor the target at the bottom of the viewport. A `.top` anchor clamps
    // hard near the live bottom (where every scroll starts), so the first swipes
    // barely move; `.bottom` reveals a full step of older messages immediately.
    chatScrollTarget = ChatScrollTarget(
      id: id, anchor: .bottom, nonce: chatScrollNonce, animated: animated)
  }

  /// Leave any frozen state and let chat snap back to the live, newest message.
  func resumeChatLive() {
    cancelSoftPause()
    isChatScrolling = false
    chatScrollAnchorID = nil
    chatFrozenMessages = nil
    stopTrackpadScrollLoop()
    scheduleHide()
  }
}
