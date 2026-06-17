import SwiftUI
import SDWebImageSwiftUI

struct RichChatLineView: View {
    let message: ChatMessage
    let nameColor: Color
    let globalEmoteURLs: [String: URL]
    let badgeURLs: [String: URL]
    var textSize: ChatTextSizeOption = .medium
    var lineHeight: ChatLineHeightOption = .normal
    /// Overrides the default white body color (used by the light side-chat).
    var bodyColorOverride: Color? = nil

    private enum Segment: Hashable {
        case text(String)
        case emote(name: String, url: URL)
    }

    private var bodyColor: Color {
        if message.isAction { return nameColor }
        return bodyColorOverride ?? .white
    }

    private var resolvedBadgeURLs: [URL] {
        message.badgeKeys.compactMap { badgeURLs[$0] }
    }

    private var messageScopedEmoteURLs: [String: URL] {
        message.twitchEmoteURLs.merging(message.youtubeEmoteURLs) { current, _ in current }
    }

    private var messageScopedEmoteKeysByLength: [String] {
        messageScopedEmoteURLs.keys.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }

    private var shouldShowSourceBadge: Bool {
        message.source == .youtube
    }

    private var sourceBadgeFill: Color {
        Color(twitchHex: "#FF0000") ?? .red
    }

    private var sourceBadgeWidth: CGFloat {
        badgeSize * 1.42
    }

    private var sourceBadgeCornerRadius: CGFloat {
        badgeSize * 0.28
    }

    private var sourceBadgePlayIconSize: CGFloat {
        badgeSize * 0.44
    }

    private var nameFontSize: CGFloat {
        switch textSize {
        case .small: return 22
        case .medium: return 26
        case .large: return 28
        }
    }

    private var bodyFontSize: CGFloat {
        switch textSize {
        case .small: return 22
        case .medium: return 26
        case .large: return 28
        }
    }

    private var badgeSize: CGFloat {
        switch textSize {
        case .small: return 18
        case .medium: return 22
        case .large: return 24
        }
    }

    private var rowSpacing: CGFloat {
        switch lineHeight {
        case .tight: return -1
        case .normal: return 2
        case .relaxed: return 6
        }
    }

    private var emoteHeight: CGFloat {
        switch textSize {
        case .small: return 28
        case .medium: return 34
        case .large: return 36
        }
    }

    var body: some View {
        ChatFlowLayout(itemSpacing: 0, rowSpacing: rowSpacing) {
            if shouldShowSourceBadge {
                sourceBadgeView
                    .padding(.top, 4)
                    .padding(.trailing, 4)
            }

            ForEach(Array(resolvedBadgeURLs.enumerated()), id: \.offset) { _, badgeURL in
                badgeView(url: badgeURL)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
            }

            Text(message.isAction ? "\(message.username) " : "\(message.username): ")
                .font(.system(size: nameFontSize, weight: .bold))
                .foregroundStyle(nameColor)

            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceBadgeView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: sourceBadgeCornerRadius, style: .continuous)
                .fill(sourceBadgeFill)

            Image(systemName: "play.fill")
                .font(.system(size: sourceBadgePlayIconSize, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 0.8)
        }
        .frame(width: sourceBadgeWidth, height: badgeSize)
        .accessibilityHidden(true)
    }

    private func badgeView(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: badgeSize, height: badgeSize)
            case .empty:
                Color.clear.frame(width: badgeSize, height: badgeSize)
            case .failure:
                Color.clear.frame(width: badgeSize, height: badgeSize)
            @unknown default:
                Color.clear.frame(width: badgeSize, height: badgeSize)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .font(.system(size: bodyFontSize))
                .foregroundStyle(bodyColor)
        case .emote(let name, let url):
            EmoteView(name: name, url: url, fallbackColor: bodyColor, fallbackFontSize: bodyFontSize, emoteHeight: emoteHeight)
        }
    }

    private var segments: [Segment] {
        // Keep ':' out of punctuation so tokens like :eyes: or :_raeKEK:
        // survive tokenization and can match YouTube emote shortcuts.
        let punctuation = CharacterSet(charactersIn: "()[]{}<>.,!?;\"'`")
        let words = message.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [Segment] = []

        for idx in words.indices {
            let token = words[idx]
            if token.isEmpty {
                if idx < words.count - 1 {
                    output.append(.text(" "))
                }
                continue
            }

            let leading = token.prefix { char in
                String(char).rangeOfCharacter(from: punctuation) != nil
            }
            let trailing = token.reversed().prefix { char in
                String(char).rangeOfCharacter(from: punctuation) != nil
            }

            let coreStart = token.index(token.startIndex, offsetBy: leading.count)
            let coreEnd = token.index(token.endIndex, offsetBy: -trailing.count)
            let core = coreStart <= coreEnd ? String(token[coreStart..<coreEnd]) : token

            if !leading.isEmpty {
                output.append(.text(String(leading)))
            }

            if let inlineSegments = inlineMessageScopedEmoteSegments(for: core) {
                output.append(contentsOf: inlineSegments)
            } else if let url = messageScopedEmoteURLs[core] ?? globalEmoteURLs[core] {
                output.append(.emote(name: core, url: url))
            } else {
                output.append(.text(core))
            }

            if !trailing.isEmpty {
                output.append(.text(String(trailing.reversed())))
            }

            if idx < words.count - 1 {
                output.append(.text(" "))
            }
        }

        return output
    }

    private func inlineMessageScopedEmoteSegments(for token: String) -> [Segment]? {
        guard !token.isEmpty else { return nil }
        guard !messageScopedEmoteKeysByLength.isEmpty else { return nil }

        var out: [Segment] = []
        var textBuffer = ""
        var index = token.startIndex
        var matchedAny = false

        while index < token.endIndex {
            var matchedKey: String?
            var matchedURL: URL?

            for key in messageScopedEmoteKeysByLength {
                guard token[index...].hasPrefix(key) else { continue }
                guard let url = messageScopedEmoteURLs[key] else { continue }
                matchedKey = key
                matchedURL = url
                break
            }

            if let matchedKey, let matchedURL {
                matchedAny = true
                if !textBuffer.isEmpty {
                    out.append(.text(textBuffer))
                    textBuffer = ""
                }
                out.append(.emote(name: matchedKey, url: matchedURL))
                index = token.index(index, offsetBy: matchedKey.count)
            } else {
                textBuffer.append(token[index])
                token.formIndex(after: &index)
            }
        }

        if !textBuffer.isEmpty {
            out.append(.text(textBuffer))
        }

        return matchedAny ? out : nil
    }
}

private struct EmoteView: View {
    let name: String
    let url: URL
    let fallbackColor: Color
    let fallbackFontSize: CGFloat
    let emoteHeight: CGFloat

    @State private var loadFailed = false

    var body: some View {
        Group {
            if loadFailed {
                Text(name)
                    .font(.system(size: fallbackFontSize))
                    .foregroundStyle(fallbackColor)
            } else {
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
            }
        }
    }
}

struct ChatFlowLayout: Layout {
    var itemSpacing: CGFloat = 0
    var rowSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

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

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )

            rowHeight = max(rowHeight, size.height)
            x += size.width + itemSpacing
        }
    }
}
