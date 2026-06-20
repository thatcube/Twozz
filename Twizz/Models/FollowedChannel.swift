import Foundation

/// A channel shown in the Home -> Following carousel.
struct FollowedChannel: Identifiable, Hashable {
    let id: String
    let login: String
    let displayName: String
    let title: String
    let gameName: String
    let viewerCount: Int?
    let thumbnailURL: URL?
    let profileImageURL: URL?
    let isLive: Bool
    let isMature: Bool

    /// The same streamer's live YouTube presence, when they're a dual-platform
    /// streamer who is currently also live on YouTube. `nil` means "no known
    /// YouTube live presence" — the card then renders Twitch-only as before.
    /// Populated after the Twitch fetch by `FollowedChannelsService`'s YouTube
    /// enrichment; deliberately outside the memberwise `init` so every existing
    /// call site keeps compiling unchanged.
    var youtube: YouTubePresence? = nil

    init(
        id: String,
        login: String,
        displayName: String,
        title: String,
        gameName: String,
        viewerCount: Int?,
        thumbnailURL: URL?,
        profileImageURL: URL?,
        isLive: Bool,
        isMature: Bool = false
    ) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.title = title
        self.gameName = gameName
        self.viewerCount = viewerCount
        self.thumbnailURL = thumbnailURL
        self.profileImageURL = profileImageURL
        self.isLive = isLive
        self.isMature = isMature
    }
}
