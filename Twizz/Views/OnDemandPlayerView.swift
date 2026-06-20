import AVKit
import SwiftUI

/// A piece of on-demand content opened from the channel page.
enum OnDemandItem: Identifiable, Hashable {
  case clip(slug: String, title: String)
  case vod(id: String, title: String)

  var id: String {
    switch self {
    case .clip(let slug, _): return "clip:\(slug)"
    case .vod(let id, _): return "vod:\(id)"
    }
  }

  var title: String {
    switch self {
    case .clip(_, let title), .vod(_, let title): return title
    }
  }

  var kindNoun: String {
    switch self {
    case .clip: return "clip"
    case .vod: return "broadcast"
    }
  }

  /// The VOD id for broadcasts (used to fetch chat replay); nil for clips.
  var vodID: String? {
    if case .vod(let id, _) = self { return id }
    return nil
  }
}

/// Entry point for on-demand content opened from the channel page.
///
/// VODs reuse the full live `PlayerView` in VOD mode, so a recorded broadcast
/// gets the exact same chat, transport controls, layout modes, and chat settings
/// as the live channel — plus full-duration seek and a synchronized chat replay,
/// minus the ability to send messages. Clips are short and chat-less, so they get
/// a lightweight native player with Apple's standard transport UI.
struct OnDemandPlayerView: View {
  let item: OnDemandItem
  /// Login of the channel that owns this content, used to resolve the right
  /// emote/badge catalogs (and avatar) for VOD chat replay.
  var channelLogin: String? = nil

  /// VOD chat is read-only, so the player never needs real credentials; a local
  /// throwaway session satisfies `PlayerView`'s (sign-in / send) plumbing, which
  /// is gated off in VOD mode anyway.
  @State private var auth = TwitchAuthSession()

  var body: some View {
    switch item {
    case .vod(let id, let title):
      PlayerView(
        channel: channelLogin ?? "",
        auth: auth,
        vod: PlayerView.VODContext(id: id, title: title)
      )
    case .clip(let slug, let title):
      ClipPlayerView(slug: slug, title: title)
    }
  }
}

/// Minimal full-screen clip player: a native `AVPlayerViewController` (via
/// SwiftUI's `VideoPlayer`) gives scrub/seek/play-pause for free, which is all a
/// short clip needs.
private struct ClipPlayerView: View {
  let slug: String
  let title: String

  @Environment(\.dismiss) private var dismiss
  @State private var player = AVPlayer()
  @State private var phase: Phase = .loading
  @FocusState private var backFocused: Bool

  private enum Phase { case loading, playing, failed }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      switch phase {
      case .loading:
        StreamLoadingView(title: title)
      case .failed:
        VStack(spacing: 20) {
          Text("Couldn't play this clip right now.")
            .font(.title2)
          Button("Back") { dismiss() }
            .focused($backFocused)
        }
        .padding(40)
      case .playing:
        VideoPlayer(player: player)
          .ignoresSafeArea()
      }
    }
    .onExitCommand { dismiss() }
    .task(id: slug) { await start() }
    .onChange(of: phase) { _, newPhase in
      if newPhase == .failed { backFocused = true }
    }
    .onDisappear {
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  private func start() async {
    phase = .loading
    do {
      let url = try await PlaybackService.clipSourceURL(slug: slug)
      player.replaceCurrentItem(with: AVPlayerItem(url: url))
      player.play()
      phase = .playing
    } catch {
      phase = .failed
    }
  }
}
