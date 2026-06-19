import Foundation

/// One render-ready token of a chat line, precomputed at ingest so the chat
/// view body doesn't re-tokenize text on every scroll/layout pass.
///
/// Deliberately SwiftUI-free so it can live on the `ChatMessage` model: a
/// cheer's color travels as a `#RRGGBB` hex string that the view resolves to a
/// `Color` at render time.
enum ChatLineSegment: Hashable {
    case text(String)
    case emote(name: String, url: URL)
    case cheer(amount: Int, url: URL, colorHex: String)
}

/// Pure tokenizer that turns a chat message's text + emote/cheermote catalogs
/// into render-ready `ChatLineSegment`s.
///
/// Lives outside the view layer so ingest (`ChatService`) can precompute the
/// segments once when a message arrives — and again only when a catalog loads —
/// instead of the chat view re-tokenizing every line on each scroll tick.
enum ChatLineTokenizer {
    static func segments(
        text: String,
        twitchEmoteURLs: [String: URL],
        youtubeEmoteURLs: [String: URL],
        globalEmoteURLs: [String: URL],
        cheermotes: [Cheermote],
        shouldRenderCheers: Bool
    ) -> [ChatLineSegment] {
        let scopedEmoteURLs = twitchEmoteURLs.merging(youtubeEmoteURLs) { current, _ in current }
        let scopedKeysByLength = scopedEmoteURLs.keys.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }

        // Keep ':' out of punctuation so tokens like :eyes: or :_raeKEK:
        // survive tokenization and can match YouTube emote shortcuts.
        let punctuation = CharacterSet(charactersIn: "()[]{}<>.,!?;\"'`")
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [ChatLineSegment] = []

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

            if shouldRenderCheers, let cheer = cheerSegment(for: core, cheermotes: cheermotes) {
                output.append(cheer)
            } else if let inline = inlineScopedEmoteSegments(for: core, scopedEmoteURLs: scopedEmoteURLs, scopedKeysByLength: scopedKeysByLength) {
                output.append(contentsOf: inline)
            } else if let url = scopedEmoteURLs[core] ?? globalEmoteURLs[core] {
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

    /// Match a `<prefix><amount>` cheermote token (e.g. `exemCheer100`) against
    /// the catalog. The longest matching prefix wins (so `pokiCheer` beats a
    /// hypothetical `Cheer`), and the tier is chosen by the cheered amount.
    private static func cheerSegment(for token: String, cheermotes: [Cheermote]) -> ChatLineSegment? {
        guard !token.isEmpty else { return nil }
        let lower = token.lowercased()

        var best: (cheer: Cheermote, amount: Int)?
        for cheer in cheermotes {
            let prefix = cheer.prefixLower
            guard !prefix.isEmpty, lower.hasPrefix(prefix) else { continue }
            let digits = lower.dropFirst(prefix.count)
            guard !digits.isEmpty, let amount = Int(digits) else { continue }
            if best == nil || prefix.count > best!.cheer.prefixLower.count {
                best = (cheer, amount)
            }
        }

        guard let match = best, let tier = match.cheer.tier(forBits: match.amount) else { return nil }
        return .cheer(amount: match.amount, url: tier.imageURL, colorHex: tier.colorHex)
    }

    private static func inlineScopedEmoteSegments(
        for token: String,
        scopedEmoteURLs: [String: URL],
        scopedKeysByLength: [String]
    ) -> [ChatLineSegment]? {
        guard !token.isEmpty else { return nil }
        guard !scopedKeysByLength.isEmpty else { return nil }

        var out: [ChatLineSegment] = []
        var textBuffer = ""
        var index = token.startIndex
        var matchedAny = false

        while index < token.endIndex {
            var matchedKey: String?
            var matchedURL: URL?

            for key in scopedKeysByLength {
                guard token[index...].hasPrefix(key) else { continue }
                guard let url = scopedEmoteURLs[key] else { continue }
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
