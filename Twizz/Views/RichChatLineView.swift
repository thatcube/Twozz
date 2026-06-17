import SwiftUI
import SDWebImageSwiftUI

struct RichChatLineView: View {
    let message: ChatMessage
    let nameColor: Color
    let globalEmoteURLs: [String: URL]
    let badgeURLs: [String: URL]
    var textSize: ChatTextSizeOption = .medium
    var lineHeight: ChatLineHeightOption = .normal

    private enum Segment: Hashable {
        case text(String)
        case emote(name: String, url: URL)
    }

    private var bodyColor: Color {
        message.isAction ? nameColor : .white
    }

    private var resolvedBadgeURLs: [URL] {
        message.badgeKeys.compactMap { badgeURLs[$0] }
    }

    private var shouldShowSourceBadge: Bool {
        message.source == .youtube
    }

    private var sourceBadgeTitle: String {
        "YT"
    }

    private var sourceBadgeFill: Color {
        Color(twitchHex: "#FF0000") ?? .red
    }

    private var sourceBadgeTextColor: Color {
        .white
    }

    private var sourceBadgeFontSize: CGFloat {
        switch textSize {
        case .small: return 13
        case .medium: return 15
        case .large: return 16
        }
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
        case .tight: return 1
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
                Text(sourceBadgeTitle)
                    .font(.system(size: sourceBadgeFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(sourceBadgeTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(sourceBadgeFill, in: Capsule())
                    .padding(.trailing, 6)
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
        let punctuation = CharacterSet(charactersIn: "()[]{}<>.,!?;:\"'`")
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

            if let url = message.twitchEmoteURLs[core] ?? message.youtubeEmoteURLs[core] ?? globalEmoteURLs[core] {
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
                        loadFailed = true
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
