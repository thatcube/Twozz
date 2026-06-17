import Foundation

/// A lightweight, `Codable` snapshot of the channels Twizz wants to surface in
/// the tvOS Top Shelf. The main app writes this into the shared App Group
/// container; the Top Shelf extension (a separate process) reads it back.
///
/// Keeping this intentionally small and dependency-free means it can be
/// compiled into both the app and the extension without dragging the rest of
/// the app's networking/UI stack into the extension's tight memory budget.
struct TopShelfSnapshot: Codable, Equatable {
    /// When the snapshot was produced. Used purely for debugging/freshness.
    var generatedAt: Date

    /// Ordered list of carousels to render in the Top Shelf.
    var sections: [Section]

    struct Section: Codable, Equatable, Identifiable {
        /// Stable identifier for the section (e.g. "following", "trending").
        var id: String
        /// User-facing carousel title (e.g. "Following · Live now").
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Equatable, Identifiable {
        /// Stable identifier — Twitch user/stream id (falls back to login).
        var id: String
        /// Twitch login used to launch playback via deep link.
        var login: String
        var displayName: String
        var title: String
        var gameName: String
        var thumbnailURL: URL?
        var viewerCount: Int?
    }

    init(generatedAt: Date = Date(), sections: [Section]) {
        self.generatedAt = generatedAt
        self.sections = sections
    }
}
