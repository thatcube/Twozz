import SwiftUI
import SDWebImageSwiftUI

struct RichChatLineView: View {
    let message: ChatMessage
    let nameColor: Color
    let globalEmoteURLs: [String: URL]
    let badgeURLs: [String: URL]
    /// Channel + global cheermotes for rendering bits cheers (e.g. `Cheer100`).
    var cheermotes: [Cheermote] = []
    /// When true, cheermote tokens render even without a bits count on the
    /// message (VOD replay). Live chat gates on `message.bits` instead.
    var matchCheersWithoutBits: Bool = false
    /// Body/name font point size.
    var textSize: CGFloat = ChatAppearance.defaultTextSize
    /// Emote glyph height (already resolved: Auto callers pass the derived value).
    var emoteSize: CGFloat = ChatAppearance.defaultEmoteSize
    /// Extra spacing applied within a wrapped message line.
    var lineHeight: CGFloat = ChatAppearance.defaultLineHeight
    /// Extra tracking (spacing between characters) applied to all chat text.
    var letterSpacing: CGFloat = ChatAppearance.defaultLetterSpacing
    /// When false, emotes render as a static first frame instead of animating.
    var animatedEmotes: Bool = true
    /// Typeface applied to all chat text.
    var fontStyle: ChatFontStyle = ChatAppearance.defaultFontStyle
    /// When false, per-user chat badges (mod/sub/etc.) are hidden.
    var showBadges: Bool = ChatAppearance.defaultShowBadges
    /// When false, the platform-source badge (YouTube/Kick) is hidden.
    var showPlatformBadges: Bool = ChatAppearance.defaultShowPlatformBadges
    /// Overrides the default white body color (used by the light side-chat).
    var bodyColorOverride: Color? = nil

    /// VoiceOver state. The combined spoken label is only built when VoiceOver is
    /// actually running — otherwise computing it (segment walk + string split/join)
    /// on every line during scroll is pure wasted work.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Whether this message should have its tokens scanned for cheermotes.
    private var shouldRenderCheers: Bool {
        guard !cheermotes.isEmpty else { return false }
        return message.bits > 0 || matchCheersWithoutBits
    }

    private var bodyColor: Color {
        // Twitch tints the whole /me line in the sender's color. That color is
        // already contrast-adjusted for the chat surface upstream (ChatView), so
        // reusing it keeps the action styling while staying legible.
        if message.isAction { return nameColor }
        return bodyColorOverride ?? .white
    }

    private var resolvedBadgeURLs: [URL] {
        message.badgeKeys.compactMap { badgeURLs[$0] }
    }

    private var shouldShowSourceBadge: Bool {
        guard showPlatformBadges else { return false }
        return message.source == .youtube || message.source == .kick
    }

    private var sourceBadgeFill: Color {
        switch message.source {
        case .kick:
            // Kick brand green.
            return Color(twitchHex: "#53FC18") ?? .green
        default:
            return Color(twitchHex: "#FF0000") ?? .red
        }
    }

    private var sourceBadgeWidth: CGFloat {
        // Kick's mark is a square logo tile; YouTube's play badge is wider.
        message.source == .kick ? badgeSize : badgeSize * 1.42
    }

    private var sourceBadgeCornerRadius: CGFloat {
        badgeSize * 0.28
    }

    private var sourceBadgePlayIconSize: CGFloat {
        badgeSize * 0.44
    }

    private var nameFontSize: CGFloat {
        textSize
    }

    private var bodyFontSize: CGFloat {
        textSize
    }

    private var badgeSize: CGFloat {
        ChatAppearance.badgeSize(forTextSize: textSize)
    }

    private var rowSpacing: CGFloat {
        lineHeight
    }

    private var emoteHeight: CGFloat {
        emoteSize
    }

    var body: some View {
        ChatFlowLayout(itemSpacing: 0, rowSpacing: rowSpacing) {
            if shouldShowSourceBadge {
                sourceBadgeView
                    .padding(.trailing, 4)
            }

            if showBadges {
                ForEach(Array(resolvedBadgeURLs.enumerated()), id: \.offset) { _, badgeURL in
                    badgeView(url: badgeURL)
                        .padding(.trailing, 4)
                }
            }

            Text(message.isAction ? "\(message.username) " : "\(message.username): ")
                .font(fontStyle.font(size: nameFontSize, weight: .bold))
                .tracking(letterSpacing)
                .foregroundStyle(nameColor)

            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Collapse the whole line into one VoiceOver element so the couch
        // experience reads "author, message" as a single utterance instead of
        // stepping through every badge/emote image node (which otherwise speak
        // raw emote URLs or surface empty, unlabeled image elements).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverEnabled ? accessibilityLabel : "")
    }

    /// Combined spoken label for the line: badges, the author name, then the
    /// message body with emotes announced by name and cheers as a bits count.
    private var accessibilityLabel: String {
        var parts: [String] = []

        if showBadges {
            parts.append(contentsOf: message.badgeKeys.compactMap(Self.badgeAccessibilityName))
        }
        if shouldShowSourceBadge {
            parts.append(message.source == .kick ? "Kick" : "YouTube")
        }

        if !message.username.isEmpty {
            parts.append(message.isAction ? "\(message.username) (action)" : message.username)
        }

        let body = spokenBody
        if !body.isEmpty {
            parts.append(body)
        }

        return parts.joined(separator: ", ")
    }

    /// Flatten the rendered segments into speakable text: text verbatim, emotes
    /// as their name, and cheers as "<amount> bits". Collapses the whitespace
    /// that segmentation introduces so VoiceOver doesn't pause oddly.
    private var spokenBody: String {
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text
            case .emote(let name, _):
                result += " \(name) "
            case .cheer(let amount, _, _):
                result += " \(amount) bits "
            }
        }
        return result
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Map a Twitch badge key (`category/version`) to a human-readable label,
    /// e.g. `moderator/1` -> "Moderator badge". Falls back to a title-cased
    /// category for badges without a hand-tuned name.
    private static func badgeAccessibilityName(_ key: String) -> String? {
        let category = key.split(separator: "/").first.map(String.init) ?? key
        guard !category.isEmpty else { return nil }

        let friendly: String
        switch category.lowercased() {
        case "broadcaster": friendly = "Broadcaster"
        case "moderator": friendly = "Moderator"
        case "subscriber": friendly = "Subscriber"
        case "founder": friendly = "Founder"
        case "vip": friendly = "VIP"
        case "turbo": friendly = "Turbo"
        case "premium": friendly = "Prime"
        case "staff": friendly = "Staff"
        case "admin": friendly = "Admin"
        case "global_mod": friendly = "Global moderator"
        case "partner": friendly = "Verified"
        case "bits": friendly = "Bits"
        case "bits-leader": friendly = "Bits leader"
        case "sub-gifter", "sub-gift-leader": friendly = "Gift sub"
        case "artist-badge": friendly = "Artist"
        default:
            friendly = category
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
        return "\(friendly) badge"
    }

    private var sourceBadgeIconColor: Color {
        // Kick's brand mark is black-on-green; YouTube's is white-on-red.
        message.source == .kick ? .black : .white
    }

    private var sourceBadgeView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: sourceBadgeCornerRadius, style: .continuous)
                .fill(sourceBadgeFill)

            sourceBadgeSymbol
        }
        .frame(width: sourceBadgeWidth, height: badgeSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sourceBadgeSymbol: some View {
        switch message.source {
        case .kick:
            // Kick's logo is a bold black "K" on its green tile; mirror that here
            // rather than reusing the generic play glyph.
            Text("K")
                .font(.system(size: badgeSize * 0.7, weight: .black, design: .rounded))
                .foregroundStyle(sourceBadgeIconColor)
                .minimumScaleFactor(0.5)
        default:
            Icon(glyph: .playerPlayFilled, size: sourceBadgePlayIconSize)
                .foregroundStyle(sourceBadgeIconColor)
                .offset(x: 0.8)
        }
    }

    private func badgeView(url: URL) -> some View {
        // WebImage (SDWebImage) keeps a decoded in-memory cache, so a badge that
        // repeats across nearly every chat line isn't re-fetched and re-decoded
        // each time a line scrolls into view the way SwiftUI's AsyncImage would.
        WebImage(url: url) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Color.clear
        }
        .frame(width: badgeSize, height: badgeSize)
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatLineSegment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .font(fontStyle.font(size: bodyFontSize))
                .tracking(letterSpacing)
                .foregroundStyle(bodyColor)
        case .emote(let name, let url):
            EmoteView(name: name, url: url, fallbackColor: bodyColor, fallbackFontSize: bodyFontSize, emoteHeight: emoteHeight, animated: animatedEmotes)
        case .cheer(let amount, let url, let colorHex):
            let color = Color(twitchHex: colorHex) ?? .gray
            HStack(spacing: 1) {
                EmoteView(name: "", url: url, fallbackColor: color, fallbackFontSize: bodyFontSize, emoteHeight: emoteHeight, animated: animatedEmotes)
                Text("\(amount)")
                    .font(fontStyle.font(size: bodyFontSize, weight: .bold))
                    .tracking(letterSpacing)
                    .foregroundStyle(color)
            }
        }
    }

    private var segments: [ChatLineSegment] {
        // Prefer the segments precomputed at ingest (ChatService) so scrolling
        // never re-tokenizes a line. The fallback path covers producers that
        // don't precompute (e.g. VOD chat replay) and any message seen before
        // its catalog-driven recompute lands: tokenize once and cache by message
        // id (+ catalog counts so newly-loaded globals/cheers still resolve).
        // body runs on the main thread, so the static store needs no locking.
        if let precomputed = message.segments {
            return precomputed
        }
        let key = SegmentCacheKey(id: message.id, globalEmoteCount: globalEmoteURLs.count, cheermoteCount: shouldRenderCheers ? cheermotes.count : 0)
        if let cached = Self.segmentCache[key] {
            return cached
        }
        let computed = ChatLineTokenizer.segments(
            text: message.text,
            twitchEmoteURLs: message.twitchEmoteURLs,
            youtubeEmoteURLs: message.youtubeEmoteURLs,
            kickEmoteURLs: message.kickEmoteURLs,
            globalEmoteURLs: globalEmoteURLs,
            cheermotes: cheermotes,
            shouldRenderCheers: shouldRenderCheers
        )
        Self.segmentCache[key] = computed
        Self.segmentCacheOrder.append(key)
        if Self.segmentCacheOrder.count > Self.segmentCacheLimit {
            let overflow = Self.segmentCacheOrder.count - Self.segmentCacheLimit
            for evicted in Self.segmentCacheOrder.prefix(overflow) {
                Self.segmentCache.removeValue(forKey: evicted)
            }
            Self.segmentCacheOrder.removeFirst(overflow)
        }
        return computed
    }

    private struct SegmentCacheKey: Hashable {
        let id: UUID
        let globalEmoteCount: Int
        let cheermoteCount: Int
    }

    private static var segmentCache: [SegmentCacheKey: [ChatLineSegment]] = [:]
    private static var segmentCacheOrder: [SegmentCacheKey] = []
    private static let segmentCacheLimit = 3000
}

private struct EmoteView: View {
    let name: String
    let url: URL
    let fallbackColor: Color
    let fallbackFontSize: CGFloat
    let emoteHeight: CGFloat
    /// When false, render the emote's first frame statically (no animation).
    var animated: Bool = true

    @State private var loadFailed = false

    var body: some View {
        Group {
            if loadFailed {
                Text(name)
                    .font(.system(size: fallbackFontSize))
                    .foregroundStyle(fallbackColor)
            } else if animated {
                AnimatedImage(url: url)
                    .onFailure { _ in
                        // Defer the state mutation: SDWebImage fires this callback
                        // synchronously while cancelling in-flight loads during view
                        // teardown. Writing @State inline re-enters SwiftUI's storage
                        // mid-update and trips a Swift exclusivity conflict (SIGABRT).
                        DispatchQueue.main.async {
                            loadFailed = true
                        }
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: emoteHeight)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                // Static path: WebImage's `isAnimating` defaults to `true`, so we
                // must explicitly pin it off to hold the first frame. Animated
                // WebP/GIF emotes then stay still while keeping the same layout
                // footprint.
                WebImage(url: url, isAnimating: .constant(false)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.clear
                }
                .onFailure { _ in
                    DispatchQueue.main.async {
                        loadFailed = true
                    }
                }
                .frame(height: emoteHeight)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct ChatFlowLayout: Layout {
    var itemSpacing: CGFloat = 0
    var rowSpacing: CGFloat = 0

    // Measuring every subview is the per-line layout cost. SwiftUI runs
    // sizeThatFits then placeSubviews in the same pass, so measure once in
    // sizeThatFits, stash the sizes in the cache, and reuse them when placing
    // instead of re-measuring every subview a second time. placeSubviews
    // re-measures only if the cache is missing/stale (e.g. an emote finished
    // loading and changed its intrinsic size), which keeps wrapping correct.
    func makeCache(subviews: Subviews) -> [CGSize] { [] }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache = sizes
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for size in sizes {
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            rowHeight = max(rowHeight, size.height)
            x += size.width + itemSpacing
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        // Group subviews into rows first so each row's height is known before we
        // place its items. Items are then centered on the row's vertical midline
        // instead of pinned to the top — keeping emotes, badges and the YouTube
        // glyph aligned with the text even when a typeface (e.g. OpenDyslexic) or
        // a very large size gives the text line box extra height below the glyphs.
        let sizes = cache.count == subviews.count ? cache : subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[(subview: LayoutSubview, size: CGSize)]] = []
        var currentRow: [(subview: LayoutSubview, size: CGSize)] = []
        var x: CGFloat = 0

        for index in subviews.indices {
            let subview = subviews[index]
            let size = sizes[index]

            if x > 0 && x + size.width > bounds.width {
                rows.append(currentRow)
                currentRow = []
                x = 0
            }

            currentRow.append((subview, size))
            x += size.width + itemSpacing
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            var rowX = bounds.minX

            for item in row {
                let yOffset = (rowHeight - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: rowX, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                rowX += item.size.width + itemSpacing
            }

            y += rowHeight + rowSpacing
        }
    }
}
