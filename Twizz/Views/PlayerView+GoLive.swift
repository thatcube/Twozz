import SwiftUI

// "Just went live" toast shown over the player when a followed channel starts
// broadcasting. Mirrors the raid-banner pattern, but anchored top-trailing and
// interactive: the focusable "Watch" button switches the player to the new
// channel before the toast auto-dismisses.
extension PlayerView {
  @ViewBuilder
  func goLiveToast(_ watcher: GoLiveWatcher, event: GoLiveEvent) -> some View {
    VStack {
      HStack {
        Spacer()
        GoLiveToastView(
          event: event,
          onWatch: { watchGoLive(watcher) }
        )
      }
      Spacer()
    }
    .padding(.top, 60)
    .padding(.trailing, 60)
    .ignoresSafeArea()
  }

  /// Dismiss the toast and switch the player to the channel that just went live.
  /// Reuses the raid follow path — a full teardown + reload of playback, chat,
  /// and EventSub for the new channel.
  func watchGoLive(_ watcher: GoLiveWatcher) {
    guard let login = watcher.watch() else { return }
    guard login.caseInsensitiveCompare(activeChannel) != .orderedSame else { return }
    followRaid(login)
  }
}
