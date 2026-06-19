import SwiftUI

// Sleep timer: selectable durations (and sleep-at-stream-end), the countdown
// loop, the "still watching?" prompt, and the dimmed sleeping overlay.
extension PlayerView {
  /// One selectable sleep-timer duration. `seconds == nil && !isEndOfStream` is
  /// the "Off" row; `isEndOfStream` sleeps when the channel goes offline.
  struct SleepTimerOption: Hashable {
    let label: String
    let seconds: Int?
    let isEndOfStream: Bool
  }

  static let sleepTimerOptions: [SleepTimerOption] = [
    .init(label: "Off", seconds: nil, isEndOfStream: false),
    .init(label: "15 minutes", seconds: 15 * 60, isEndOfStream: false),
    .init(label: "30 minutes", seconds: 30 * 60, isEndOfStream: false),
    .init(label: "1 hour", seconds: 60 * 60, isEndOfStream: false),
    .init(label: "1.5 hours", seconds: 90 * 60, isEndOfStream: false),
    .init(label: "End of stream", seconds: nil, isEndOfStream: true),
  ]

  var sleepTimerOptionLabels: [String] {
    Self.sleepTimerOptions.map(\.label)
  }

  var sleepTimerIsArmed: Bool {
    sleepDeadline != nil || sleepUntilStreamEnds
  }

  /// Applies a sleep-timer choice from the menu.
  func selectSleepTimer(at index: Int) {
    guard Self.sleepTimerOptions.indices.contains(index) else { return }
    let option = Self.sleepTimerOptions[index]
    sleepTimerTask?.cancel()
    sleepTimerTask = nil
    withAnimation { showStillWatching = false }
    sleepSelectionIndex = index

    if option.isEndOfStream {
      sleepUntilStreamEnds = true
      sleepDeadline = nil
      sleepRemainingSeconds = nil
      return
    }

    guard let seconds = option.seconds else {
      disarmSleepTimer()
      return
    }

    sleepUntilStreamEnds = false
    sleepDeadline = Date().addingTimeInterval(Double(seconds))
    sleepRemainingSeconds = seconds
    startSleepCountdown()
  }

  func disarmSleepTimer() {
    sleepTimerTask?.cancel()
    sleepTimerTask = nil
    sleepDeadline = nil
    sleepUntilStreamEnds = false
    sleepRemainingSeconds = nil
    sleepSelectionIndex = 0
    withAnimation { showStillWatching = false }
  }

  func startSleepCountdown() {
    sleepTimerTask?.cancel()
    sleepTimerTask = Task {
      while !Task.isCancelled {
        await MainActor.run { tickSleepTimer() }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func tickSleepTimer() {
    guard let deadline = sleepDeadline else { return }
    let remaining = Int(deadline.timeIntervalSinceNow.rounded())
    if remaining <= 0 {
      enterSleepState()
      return
    }
    sleepRemainingSeconds = remaining
    if remaining <= 30, !showStillWatching {
      withAnimation { showStillWatching = true }
    }
  }

  /// "Still watching?" → keep playing and cancel the pending sleep.
  func keepWatching() {
    disarmSleepTimer()
    focus = showControls ? .quality : .video
  }

  /// Timer fired: stop playback (and the monitors that would otherwise try to
  /// "recover" the deliberate pause), show the dim sleeping overlay, and release
  /// the idle timer so tvOS can actually put the device to sleep.
  func enterSleepState() {
    sleepTimerTask?.cancel()
    sleepTimerTask = nil
    sleepDeadline = nil
    sleepUntilStreamEnds = false
    sleepRemainingSeconds = nil
    sleepSelectionIndex = 0
    showStillWatching = false
    // Tear down the watchdog/latency loops first so neither one sees the pause
    // as a stall and resumes playback behind the overlay.
    stopPlaybackWatchdog()
    stopLatencyMonitor()
    didRequestPlayback = false
    player.pause()
    setIdleTimer(disabled: false)
    withAnimation { isSleeping = true }
    focus = .sleepResume
  }

  func wakeFromSleep() {
    guard isSleeping else { return }
    withAnimation { isSleeping = false }
    // Resume keeping the screen awake now that the viewer is back.
    setIdleTimer(disabled: true)
    focus = showControls ? .quality : .video
    // After a timed pause the live edge has moved on (often a couple of minutes)
    // and the cached playlist may be stale, so resuming in place leaves us stuck
    // far "behind live" or stalled. Reload from scratch to snap back to the live
    // edge and guarantee playback actually restarts.
    Task { await load(maxAttempts: 2, reason: "wake from sleep", resetMetadata: false) }
  }

  /// Dim full-screen "Sleeping" scene shown after a sleep timer fires. Pressing
  /// any select/tap resumes playback. Deliberately night-friendly: a dark,
  /// warm-red starry sky that stays easy on the eyes in a dark room and ignores
  /// the app's light/dark setting.
  var sleepingOverlay: some View {
    SleepingScreen()
      .contentShape(Rectangle())
      .focusable()
      .focused($focus, equals: .sleepResume)
      .onTapGesture { wakeFromSleep() }
      .zIndex(50)
  }

  /// "Still watching?" heads-up shown ~30s before a timed sleep, with a
  /// focusable button to stay awake. Mirrors the outgoing-raid banner.
  func stillWatchingBanner() -> some View {
    VStack {
      Spacer()
      HStack(spacing: 20) {
        Image(systemName: "moon.zzz.fill")
          .font(.system(size: 30))
          .foregroundStyle(.white)
        VStack(alignment: .leading, spacing: 4) {
          Text("Still watching?")
            .font(.headline).bold()
            .foregroundStyle(.white)
          Text("Pausing in \(sleepRemainingSeconds ?? 0)s to let your Apple TV sleep")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
        }
        Button("Keep watching") {
          keepWatching()
        }
        .focused($focus, equals: .sleepKeepWatching)
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 20)
      .background(Color(red: 0.13, green: 0.16, blue: 0.40).opacity(0.95), in: Capsule())
      .padding(.bottom, 60)
    }
    .ignoresSafeArea()
  }
}
