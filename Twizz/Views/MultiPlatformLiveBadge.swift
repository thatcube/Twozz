import SwiftUI

/// The live indicator shown on a stream card. When the streamer is a
/// dual-platform streamer who is currently live on both Twitch and YouTube, it
/// shows one row per platform — a Twitch logo + viewers and a YouTube logo +
/// viewers — so a single card represents the streamer on both services instead
/// of two duplicate cards. Otherwise it falls back to the standard `LiveBadge`
/// so Twitch-only and offline cards look exactly as before.
///
/// Like `LiveBadge`, this is always laid over a guaranteed-dark surface (the
/// bottom video scrim), so white text is the correct, legible choice here; the
/// platform glyphs carry the brand tint. Liveness is never conveyed by color
/// alone — the card's `accessibilityLabel` already spells out the state, and
/// each row pairs a brand glyph with a textual viewer count.
struct MultiPlatformLiveBadge: View {
  let channel: FollowedChannel
  var prominent: Bool = false

  var body: some View {
    if let youtube = channel.youtube, youtube.isLive {
      VStack(alignment: .leading, spacing: prominent ? 8 : 6) {
        PlatformLiveRow(
          glyph: .brandTwitch,
          tint: SocialPlatform.twitch.tint,
          viewerCount: channel.viewerCount,
          prominent: prominent
        )
        PlatformLiveRow(
          glyph: .brandYoutube,
          tint: SocialPlatform.youtube.tint,
          viewerCount: youtube.viewerCount,
          prominent: prominent
        )
      }
    } else {
      LiveBadge(isLive: channel.isLive, viewerCount: channel.viewerCount, prominent: prominent)
    }
  }
}

/// One platform's live row: brand glyph in a legible chip + concurrent viewers.
private struct PlatformLiveRow: View {
  let glyph: Glyph
  let tint: Color
  let viewerCount: Int?
  var prominent: Bool

  private var glyphSize: CGFloat { prominent ? 22 : 18 }
  private var countFont: Font { prominent ? .subheadline.weight(.semibold) : .caption2.weight(.semibold) }

  var body: some View {
    HStack(spacing: 7) {
      Icon(glyph: glyph, size: glyphSize)
        .foregroundStyle(.white)
        .padding(5)
        .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      Text(Self.formatViewers(viewerCount))
        .font(countFont)
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }

  /// Compact viewer count: `1.2K`, `12.3K`, `1.4M`. Falls back to `LIVE` when the
  /// count is unknown so the row still reads as live.
  static func formatViewers(_ count: Int?) -> String {
    guard let count, count > 0 else { return "LIVE" }
    switch count {
    case 1_000_000...:
      return String(format: "%.1fM watching", Double(count) / 1_000_000)
    case 10_000...:
      return String(format: "%.0fK watching", Double(count) / 1_000)
    case 1_000...:
      return String(format: "%.1fK watching", Double(count) / 1_000)
    default:
      return "\(count) watching"
    }
  }
}

#if DEBUG
#Preview("Twitch + YouTube") {
  ZStack {
    Color.black
    MultiPlatformLiveBadge(
      channel: FollowedChannel(
        id: "1",
        login: "example",
        displayName: "Example",
        title: "Dual streaming",
        gameName: "Just Chatting",
        viewerCount: 24_300,
        thumbnailURL: nil,
        profileImageURL: nil,
        isLive: true
      ).withDebugYouTube(
        YouTubePresence(
          channelID: "UCxxxx", isLive: true, viewerCount: 8_577, videoID: "abc", title: "Live")
      ),
      prominent: true
    )
    .padding()
  }
}

extension FollowedChannel {
  fileprivate func withDebugYouTube(_ presence: YouTubePresence) -> FollowedChannel {
    var copy = self
    copy.youtube = presence
    return copy
  }
}
#endif
