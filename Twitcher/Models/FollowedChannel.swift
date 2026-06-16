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
}
