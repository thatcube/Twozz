import SwiftUI

extension ChatView {
  @ViewBuilder
  func line(for message: ChatMessage) -> some View {
    let seed = message.id.hashValue
    let richLine = RichChatLineView(
      message: message,
      nameColor: color(for: message),
      globalEmoteURLs: emoteURLs,
      badgeURLs: badgeURLs,
      cheermotes: cheermotes,
      matchCheersWithoutBits: matchCheersWithoutBits,
      textSize: textSize,
      emoteSize: emoteSize,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      animatedEmotes: animatedEmotes,
      fontStyle: fontStyle,
      showBadges: showBadges,
      showPlatformBadges: showPlatformBadges,
      bodyColorOverride: isLightChatSurface ? palette.chatSidePrimaryText : nil
    )

    if let systemMessage = message.systemMessage {
      switch message.systemNoticeStyle {
      case .subscription:
        eventNoticeHighlight(
          systemMessage: systemMessage,
          accent: subscriptionAccent,
          readableAccent: readableSubscriptionAccent,
          showUserLine: !message.text.isEmpty,
          seed: seed,
          icon: {
            Icon(glyph: subscriptionGlyph(for: message.systemNoticeIcon), size: textSize * 0.9)
          },
          line: richLine
        )
      case .watchStreak:
        eventNoticeHighlight(
          systemMessage: systemMessage,
          accent: watchStreakAccent,
          readableAccent: readableWatchStreakAccent,
          showUserLine: !message.text.isEmpty,
          seed: seed,
          icon: {
            Icon(glyph: .flame, size: textSize * 0.9)
          },
          line: richLine
        )
      }
    } else if message.isFirstMessage {
      firstMessageHighlight(around: richLine, seed: seed)
    } else if shouldHighlight(message) {
      mentionHighlight(around: richLine, seed: seed)
    } else {
      richLine
    }
  }

  /// Maps a notice's icon kind to the vendored Tabler glyph: Prime → crown,
  /// gift subs → gift, ordinary paid subs → star. (Watch streaks have their own
  /// case and use the flame glyph directly.)
  private func subscriptionGlyph(for icon: SystemNoticeIcon) -> Glyph {
    switch icon {
    case .prime: return .crownFilled
    case .gift: return .giftFilled
    case .watchStreak: return .flame
    case .sub: return .starFilled
    }
  }

  // MARK: - Mention highlight

  /// Discord-style gold/amber accent for lines that mention the viewer — the
  /// universal "you were mentioned" color, kept distinct from the purple
  /// subscription/first-message and orange watch-streak treatments.
  private var mentionAccent: Color {
    Color(twitchHex: "#FAA61A") ?? .orange
  }

  /// Whether `message` should get the mention highlight: it names the signed-in
  /// user (word-boundary match on login or display name, covering bare mentions
  /// and Twitch replies, which prefix `@you`), it's a threaded reply to the
  /// viewer, or it contains one of the user's highlight keywords.
  private func shouldHighlight(_ message: ChatMessage) -> Bool {
    guard highlightEnabled else { return false }

    // Mention detection lowercases the message text and runs word-boundary scans
    // per name/keyword. That's cheap once, but the line closure re-evaluates as
    // rows scroll in and out, so memoize the result by message id plus a signature
    // of the highlight inputs (viewer identity + keywords). When the signature
    // changes, new keys are used and stale entries fall out via LRU eviction.
    let key = HighlightCacheKey(id: message.id, configSignature: Self.highlightConfigSignature(self))
    if let cached = Self.highlightCache[key] { return cached }

    let result = Self.computeShouldHighlight(message, viewerLogin: viewerLogin, viewerDisplayName: viewerDisplayName, keywords: highlightKeywords)

    Self.highlightCache[key] = result
    Self.highlightCacheOrder.append(key)
    if Self.highlightCacheOrder.count > Self.highlightCacheLimit {
      let overflow = Self.highlightCacheOrder.count - Self.highlightCacheLimit
      for evicted in Self.highlightCacheOrder.prefix(overflow) {
        Self.highlightCache.removeValue(forKey: evicted)
      }
      Self.highlightCacheOrder.removeFirst(overflow)
    }
    return result
  }

  private static func computeShouldHighlight(_ message: ChatMessage, viewerLogin: String?, viewerDisplayName: String?, keywords: [String]) -> Bool {
    if let login = message.replyParentLogin,
       let viewerLogin, !viewerLogin.isEmpty,
       login == viewerLogin.lowercased() {
      return true
    }

    let haystack = message.text.lowercased()

    for name in [viewerLogin, viewerDisplayName] {
      guard let name, !name.isEmpty else { continue }
      if containsWord(name.lowercased(), in: haystack) { return true }
    }

    for keyword in keywords where haystack.contains(keyword) {
      return true
    }

    return false
  }

  /// Stable signature of the inputs that change which lines highlight. Folded
  /// into the cache key so a viewer/keyword change invalidates memoized results.
  private static func highlightConfigSignature(_ view: ChatView) -> Int {
    var hasher = Hasher()
    hasher.combine(view.viewerLogin)
    hasher.combine(view.viewerDisplayName)
    hasher.combine(view.highlightKeywords)
    return hasher.finalize()
  }

  private struct HighlightCacheKey: Hashable {
    let id: UUID
    let configSignature: Int
  }

  private static var highlightCache: [HighlightCacheKey: Bool] = [:]
  private static var highlightCacheOrder: [HighlightCacheKey] = []
  private static let highlightCacheLimit = 3000

  /// Case-insensitive whole-token match for a username so "sam" doesn't fire on
  /// "same". Both inputs are expected lowercased. A leading `@` (as in a mention
  /// or reply prefix) counts as a boundary.
  private static func containsWord(_ word: String, in text: String) -> Bool {
    guard !word.isEmpty else { return false }
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: word, range: searchRange) {
      let beforeOK: Bool = {
        guard found.lowerBound > text.startIndex else { return true }
        let prev = text[text.index(before: found.lowerBound)]
        return !(prev.isLetter || prev.isNumber || prev == "_")
      }()
      let afterOK: Bool = {
        guard found.upperBound < text.endIndex else { return true }
        let next = text[found.upperBound]
        return !(next.isLetter || next.isNumber || next == "_")
      }()
      if beforeOK && afterOK { return true }
      searchRange = found.upperBound..<text.endIndex
    }
    return false
  }

  /// Wraps an ordinary chat line in the gold mention treatment using the shared
  /// rounded highlight card.
  private func mentionHighlight<Content: View>(around line: Content, seed: Int) -> some View {
    highlightCard(accent: mentionAccent, seed: seed) { line }
  }

  // MARK: - Shared highlight card

  /// Corner radius for the rounded highlight card. tvOS leans on rounded cards,
  /// so a soft corner reads more native than a hard edge-to-edge band.
  private var highlightCornerRadius: CGFloat { 14 }

  /// Shared container for every highlighted line (mention, subscription,
  /// watch-streak, first message). Gives a rounded, gradient-tinted card with a
  /// rounded leading accent bar and a hairline accent stroke. The accent gradient
  /// alone carries the highlight in every mode (no material blur — it's an
  /// expensive per-row GPU cost on tvOS that's barely noticeable here). The card
  /// always fills the available width so it never stops short of the panel edge.
  @ViewBuilder
  private func highlightCard<Content: View>(
    accent: Color,
    seed: Int,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let barWidth: CGFloat = 4
    let corner = highlightCornerRadius
    // Keep the card a touch inside the list edge so it still reads as a rounded
    // card, while the remaining left margin (`margin`) is exactly enough to land
    // the message text back on the same keyline as the surrounding chat lines —
    // the accent bar floats in that margin, left of the text, like Twitch.
    let cardInset: CGFloat = 5
    let margin = max(barWidth + 8, horizontalPadding - cardInset)
    let glow = highlightGlow(seed: seed)
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

    content()
      .padding(.vertical, max(verticalPadding - 2, 3))
      .padding(.horizontal, margin)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Draw the whole highlight (tinted glow, accent bar, hairline border) as a
      // rounded *background* instead of clipping the card with `.clipShape`. The
      // message content is already inset from the corners by `margin`, so it never
      // reached the rounded edge — the old clip only ever masked empty background,
      // yet still forced an offscreen compositing pass on every highlighted row.
      // Those passes are what made scrolling back through a busy channel (lots of
      // sub / first-message cards) janky. Rounded shapes filled straight into the
      // background composite in place with no offscreen pass, for the same look.
      .background {
        ZStack(alignment: .leading) {
          // A soft radial glow whose origin + spread vary per message (seeded by
          // the line) so highlights don't all read as the same left-to-right ramp.
          // The center stays biased toward the leading edge, anchoring the glow to
          // the accent bar. EllipticalGradient costs about the same as a linear one
          // and uses relative radii, so it needs no GeometryReader. Filling the
          // rounded shape directly is what replaces the former clip.
          shape.fill(
            EllipticalGradient(
              colors: [
                accent.opacity(isSideLayout ? 0.18 : 0.26),
                accent.opacity(isSideLayout ? 0.03 : 0.05),
              ],
              center: glow.center,
              startRadiusFraction: 0,
              endRadiusFraction: glow.endRadiusFraction
            )
          )
          Capsule(style: .continuous)
            .fill(accent)
            // Fill the card height minus a fixed top/bottom inset so the bar
            // keeps a consistent margin from the card edges at any height (it no
            // longer shrinks proportionally on tall, multi-line messages).
            .frame(width: barWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 14)
            .padding(.leading, (margin - barWidth) / 2 + 1)
        }
        .overlay {
          shape.strokeBorder(accent.opacity(isSideLayout ? 0.22 : 0.32), lineWidth: 1)
        }
      }
      // Bleed back out so the text inside lands on the normal chat keyline while
      // the card keeps a small inset from the panel edge.
      .padding(.horizontal, -margin)
  }

  /// Stable per-line variation for the highlight glow, derived from the message's
  /// hash so each card differs but stays the same across re-renders. The center is
  /// kept near the leading edge (where the accent bar sits) with a varying vertical
  /// position and spread. Pure integer math — effectively free per line.
  private func highlightGlow(seed: Int) -> (center: UnitPoint, endRadiusFraction: CGFloat) {
    let r = UInt(bitPattern: seed)
    let cx = 0.02 + CGFloat(r % 26) / 100.0           // 0.02 ... 0.27 (hug the bar)
    let cy = 0.16 + CGFloat((r / 26) % 68) / 100.0     // 0.16 ... 0.83
    let endRadius = 0.85 + CGFloat((r / 7) % 50) / 100.0 // 0.85 ... 1.34
    return (UnitPoint(x: cx, y: cy), endRadius)
  }

  /// Small rounded "chip" used for highlight labels (e.g. FIRST MESSAGE) — a
  /// compact tinted capsule.
  private func highlightChip(
    _ text: String,
    accent: Color,
    readable: Color,
    fontSize: CGFloat,
    weight: Font.Weight = .heavy,
    tracking: CGFloat = 0.6
  ) -> some View {
    Text(text)
      .font(.system(size: fontSize, weight: weight))
      .tracking(tracking)
      .fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(readable)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(
        Capsule(style: .continuous).fill(accent.opacity(isSideLayout ? 0.18 : 0.26))
      )
  }

  // MARK: - Subscription highlight

  /// Twitch highlights subscription notices with its brand purple — the same
  /// accent used for the first-message treatment above and on Twitch itself.
  private var subscriptionAccent: Color {
    firstMessageAccent
  }

  /// The accent colors above are tuned for the dark overlay; on a light side
  /// panel they wash out, so run them through the same readable-contrast
  /// adjustment for any text drawn in them (the translucent tints/bars keep the
  /// raw accent so the strip still reads as Twitch purple).
  private var readableSubscriptionAccent: Color {
    subscriptionAccent.chatReadable(onSurface: chatSurfaceColor)
  }

  private var readableFirstMessageAccent: Color {
    firstMessageAccent.chatReadable(onSurface: chatSurfaceColor)
  }

  /// Warm "flame" accent for shared watch-streak milestones, distinguishing them
  /// from the purple subscription treatment while echoing Twitch's streak flame.
  private var watchStreakAccent: Color {
    Color(twitchHex: "#FF6905") ?? .orange
  }

  private var readableWatchStreakAccent: Color {
    watchStreakAccent.chatReadable(onSurface: chatSurfaceColor)
  }

  /// Wraps a highlighted USERNOTICE (subscription or watch-streak) in the shared
  /// rounded highlight card: a glyph in a filled accent circle, the ready-made
  /// `system-msg` text, and — when the viewer attached a comment — their normal
  /// chat line beneath it.
  private func eventNoticeHighlight<IconContent: View, Content: View>(
    systemMessage: String,
    accent: Color,
    readableAccent: Color,
    showUserLine: Bool,
    seed: Int,
    @ViewBuilder icon: () -> IconContent,
    line: Content
  ) -> some View {
    let badgeSize = max(20, textSize * 0.95)

    return highlightCard(accent: accent, seed: seed) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          icon()
            .foregroundStyle(.white)
            .frame(width: badgeSize, height: badgeSize)
            .background(Circle().fill(accent))
          Text(systemMessage)
            .font(fontStyle.font(size: textSize, weight: .semibold))
            .tracking(letterSpacing)
            .foregroundStyle(readableAccent)
            .fixedSize(horizontal: false, vertical: true)
        }

        if showUserLine {
          line
        }
      }
    }
  }

  // MARK: - First-message highlight

  /// Twitch-style accent purple used for the first-message treatment.
  private var firstMessageAccent: Color {
    Color(twitchHex: "#A970FF") ?? .purple
  }

  /// Wraps a chat line in the highlighted "first message" treatment: the shared
  /// rounded card with a small "FIRST MESSAGE" pill above the text — mirroring
  /// Twitch's affordance in a more tvOS-native form.
  private func firstMessageHighlight<Content: View>(around line: Content, seed: Int) -> some View {
    let labelSize = max(11, textSize * 0.44)

    return highlightCard(accent: firstMessageAccent, seed: seed) {
      VStack(alignment: .leading, spacing: 3) {
        highlightChip(
          "FIRST MESSAGE",
          accent: firstMessageAccent,
          readable: readableFirstMessageAccent,
          fontSize: labelSize
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        line
      }
    }
  }


  /// Use the user's Twitch color, or a stable color derived from their name.
  private func color(for message: ChatMessage) -> Color {
    let surfaceKey = isLightChatSurface ? "L" : "D"
    let key = (message.colorHex ?? "name:\(message.username)") + "|" + surfaceKey
    if let cached = Self.colorCache[key] {
      return cached
    }
    let base: Color
    if let hex = message.colorHex, let c = Color(twitchHex: hex) {
      base = c
    } else {
      base = Self.fallbackPalette[message.username.deterministicIndex(Self.fallbackPalette.count)]
    }
    // Nudge dim/low-contrast colors so names (and the /me bodies that reuse this
    // color) stay legible on whichever surface the chat is drawn on.
    let resolved = base.chatReadable(onSurface: chatSurfaceColor)
    Self.colorCache[key] = resolved
    Self.colorCacheOrder.append(key)
    if Self.colorCacheOrder.count > Self.colorCacheLimit {
      let overflow = Self.colorCacheOrder.count - Self.colorCacheLimit
      for evicted in Self.colorCacheOrder.prefix(overflow) {
        Self.colorCache.removeValue(forKey: evicted)
      }
      Self.colorCacheOrder.removeFirst(overflow)
    }
    return resolved
  }

  /// Resolved name colors keyed by the user's color hex (or username) plus the
  /// surface they're drawn on. Parsing the hex, building a Color, and running the
  /// readable-contrast adjustment on every line render is pure repeated work, so
  /// memoize it across the session. Bounded with an LRU eviction (matching the
  /// segment/highlight caches) so a long session on a busy channel with many
  /// distinct chatters can't grow this map without limit.
  private static var colorCache: [String: Color] = [:]
  private static var colorCacheOrder: [String] = []
  private static let colorCacheLimit = 3000

  /// Drops the process-global chat line caches (resolved name colors,
  /// mention-highlight results, and the light-surface memo). Called on channel
  /// change and on memory pressure (see `ChatService.clearLineCaches`).
  static func clearLineCaches() {
    colorCache.removeAll(keepingCapacity: false)
    colorCacheOrder.removeAll(keepingCapacity: false)
    highlightCache.removeAll(keepingCapacity: false)
    highlightCacheOrder.removeAll(keepingCapacity: false)
    lightSurfaceMemo = nil
  }

  /// Bright, readable defaults (Twitch-style) for users with no color set.
  private static let fallbackPalette: [Color] = [
    Color(twitchHex: "#FF4500")!, Color(twitchHex: "#1E90FF")!, Color(twitchHex: "#00C896")!,
    Color(twitchHex: "#FF69B4")!, Color(twitchHex: "#9ACD32")!, Color(twitchHex: "#FFB000")!,
    Color(twitchHex: "#00CED1")!, Color(twitchHex: "#FF7F50")!, Color(twitchHex: "#BA8AFF")!,
    Color(twitchHex: "#5CD65C")!,
  ]
}

extension String {
  /// A stable index in `0..<count` derived from the string's contents.
  fileprivate func deterministicIndex(_ count: Int) -> Int {
    guard count > 0 else { return 0 }
    let sum = unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return sum % count
  }
}
