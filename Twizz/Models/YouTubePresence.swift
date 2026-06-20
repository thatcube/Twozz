import Foundation

/// A streamer's *live* presence on YouTube, attached to a `FollowedChannel` so a
/// single Twitch-followed streamer card can show both platforms at once (Twitch
/// logo + viewers and YouTube logo + viewers) without a duplicate card.
///
/// Sourced entirely from a public, parameter-free snapshot the app downloads
/// (`YouTubeLiveSnapshotService`) — never from a per-user YouTube API call — so
/// it scales to any number of users and keeps the "Data Not Collected" posture.
struct YouTubePresence: Hashable {
  /// The streamer's YouTube channel ID (e.g. `UCxxxxxxxx`). Case-sensitive.
  let channelID: String
  let isLive: Bool
  /// Concurrent viewers on the YouTube live broadcast, when known.
  let viewerCount: Int?
  /// The currently-live video ID, used to open YouTube playback.
  let videoID: String?
  let title: String?
}
