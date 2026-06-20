import SwiftUI
import UIKit

/// A scroll instruction for the chat list. The nonce ensures repeated scrolls to
/// the same message still register as a change through `onChange`.
struct ChatScrollTarget: Equatable {
  var id: ChatMessage.ID
  var anchor: UnitPoint
  var nonce: Int
  /// Continuous gesture scrolling sends un-animated targets so the rapid 60 Hz
  /// updates read as a smooth drag rather than a stutter of spring animations.
  var animated: Bool = true
}

/// A read-only chat panel that auto-scrolls to the newest message.
/// Designed as a translucent overlay on top of the video player.
struct ChatView: View {
  let channel: String
  let messages: [ChatMessage]
  var textSize: CGFloat = ChatAppearance.defaultTextSize
  var emoteSize: CGFloat = ChatAppearance.defaultEmoteSize
  var messageSpacing: CGFloat = ChatAppearance.defaultMessageSpacing
  var lineHeight: CGFloat = ChatAppearance.defaultLineHeight
  var letterSpacing: CGFloat = ChatAppearance.defaultLetterSpacing
  var animatedEmotes: Bool = true
  var fontStyle: ChatFontStyle = ChatAppearance.defaultFontStyle
  var showBadges: Bool = ChatAppearance.defaultShowBadges
  /// Master on/off for mention highlighting.
  var highlightEnabled: Bool = true
  /// Signed-in user's Twitch login (lowercase) and display name, used to detect
  /// lines that mention the viewer. Both nil when signed out.
  var viewerLogin: String? = nil
  var viewerDisplayName: String? = nil
  /// Extra user-defined highlight keywords (already normalized/lowercased).
  var highlightKeywords: [String] = []
  var isConnected: Bool = false
  var emoteURLs: [String: URL] = [:]
  var badgeURLs: [String: URL] = [:]
  /// Channel + global cheermotes, used to render bits cheers (e.g. `Cheer100`).
  var cheermotes: [Cheermote] = []
  /// When true, cheermote tokens are matched without an accompanying bits count
  /// (VOD replay, where comments carry no `bits` tag). Live chat leaves this
  /// false so only real cheers (with bits) render as cheermotes.
  var matchCheersWithoutBits: Bool = false
  /// When true, the message list draws a light scrim instead of a solid
  /// background so an underlying Liquid Glass panel can show through.
  var useGlassBackground: Bool = false
  /// When true, use a lighter non-glass background for overlay mode.
  var useLighterOverlayBackground: Bool = false
  /// When false, the list stops pinning to the newest message so the viewer can
  /// scroll back through history without the view yanking to the bottom.
  var autoScroll: Bool = true
  /// When non-nil, chat is in the lightweight "soft pause" read mode and this is
  /// the seconds remaining before it auto-resumes. Drives the countdown pill.
  var softPauseRemaining: Int? = nil
  /// Total soft-pause duration in seconds, used to draw the countdown ring.
  var softPauseTotal: Int = 10
  /// A scroll instruction from the player (manual scroll mode). Changing its
  /// nonce scrolls the list to the given message; the player keeps focus on the
  /// composer because tvOS won't reliably keep focus on the chat ScrollView.
  var scrollTarget: ChatScrollTarget? = nil
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @State private var pendingScrollWork: DispatchWorkItem?
  /// Newest message id, tracked separately so the throttled auto-scroll always
  /// targets the true latest message even if more arrived during its window.
  @State private var latestMessageID: UUID?
  /// Drives the swipe-up hint chevron: it fades + drifts up once, slightly after
  /// the pill animates in. Reset to false on disappear so it replays on reopen.
  @State private var hintShown = false

  /// Side layout is the only non-glass, non-overlay mode; it follows the
  /// app theme so light mode paints a light chat panel with dark text.
  private var isSideLayout: Bool {
    !useGlassBackground && !useLighterOverlayBackground
  }

  /// The nominal surface colored chat text is drawn on, used to keep name colors
  /// and accents at a readable contrast. Overlay/glass modes sit on the dark,
  /// translucent player; only the light-theme side panel is a light surface.
  private var chatSurfaceColor: Color {
    if isSideLayout { return palette.chatSideSurface }
    // Reduce-transparency / disable-glass: the pane paints an opaque, theme-aware
    // chrome surface (light in Light theme), so resolve text contrast against it.
    if glassDisabled { return palette.chromeOpaqueSurface }
    // Light theme: the translucent overlay/glass chat now sits on light chrome
    // (the player tree renders in the light color scheme), so resolve text and
    // accent contrast against a light surface instead of the dark video.
    if palette.isLight { return Color(white: 0.97) }
    if useLighterOverlayBackground { return Color(white: 0.13) }
    return Color(white: 0.12)
  }

  private var isLightChatSurface: Bool {
    // Bridging to UIColor and reading its luminance isn't free, and this is hit
    // multiple times per chat line (name color + body color override). The result
    // only depends on the surface inputs, not the message, so memoize it in a
    // single-entry cache keyed by those inputs — N bridges per render collapse to
    // one when the signature is unchanged.
    let signature = LightSurfaceSignature(
      palette: palette,
      glassDisabled: glassDisabled,
      isSideLayout: isSideLayout,
      useLighterOverlayBackground: useLighterOverlayBackground
    )
    if let memo = Self.lightSurfaceMemo, memo.signature == signature {
      return memo.value
    }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(chatSurfaceColor).getWhite(&white, alpha: &alpha)
    let value = white > 0.5
    Self.lightSurfaceMemo = (signature, value)
    return value
  }

  private struct LightSurfaceSignature: Equatable {
    let palette: ThemePalette
    let glassDisabled: Bool
    let isSideLayout: Bool
    let useLighterOverlayBackground: Bool
  }

  private static var lightSurfaceMemo: (signature: LightSurfaceSignature, value: Bool)?

  private var messageSpacingValue: CGFloat {
    messageSpacing
  }

  private var horizontalPadding: CGFloat {
    ChatAppearance.horizontalPadding(forTextSize: textSize)
  }

  private var verticalPadding: CGFloat {
    ChatAppearance.verticalPadding(forMessageSpacing: messageSpacing)
  }

  var body: some View {
    messageList
      .background(
        isSideLayout
          ? AnyShapeStyle(palette.chatSideSurface)
          : (useGlassBackground
            ? (glassDisabled
              ? AnyShapeStyle(Color.clear)
              : AnyShapeStyle(palette.chromeGlassTint(0.22)))
            : (useLighterOverlayBackground
              ? (glassDisabled
                ? AnyShapeStyle(palette.chromeOpaqueSurface)
                : AnyShapeStyle(palette.isLight ? Color(white: 0.97).opacity(0.92) : Color(white: 0.13).opacity(0.90)))
              : AnyShapeStyle(palette.chatSideSurface))))
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: messageSpacingValue) {
          ForEach(messages) { message in
            line(for: message)
              .id(message.id)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
      }
      .scrollIndicators(.hidden)
      .onChange(of: scrollTarget) { _, target in
        // Manual scroll: jump to the requested message. Discrete swipes animate
        // for a snappy feel; continuous gesture scrolling sends un-animated
        // targets so the stream of updates reads as a smooth drag.
        guard let target else { return }
        pendingScrollWork?.cancel()
        pendingScrollWork = nil
        if target.animated {
          withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            proxy.scrollTo(target.id, anchor: target.anchor)
          }
        } else {
          proxy.scrollTo(target.id, anchor: target.anchor)
        }
      }
      .onChange(of: messages.last?.id) {
        // Keyed off the newest message id rather than `messages.count`: the chat
        // buffer is capped (see ChatService.maxBufferedMessages), so on a busy
        // channel each new message trims one off the front and the count stays
        // pinned at the cap forever. A count-based trigger would stop firing and
        // auto-scroll would silently freeze; the last id changes on every message.
        guard autoScroll, let last = messages.last else { return }
        // Keep the target current (cheap) so a burst still lands on the newest
        // message, but only run one *un-animated* scroll per ~100ms. Animating a
        // scrollTo on every incoming message forces a continuous stream of layout
        // passes — the dominant chat cost on fast/raided channels. Un-animated
        // anchoring just keeps the list pinned to the bottom, which is smoother.
        latestMessageID = last.id
        guard pendingScrollWork == nil else { return }
        let work = DispatchWorkItem {
          pendingScrollWork = nil
          guard autoScroll, let id = latestMessageID else { return }
          proxy.scrollTo(id, anchor: .bottom)
        }
        pendingScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
      }
      .onChange(of: autoScroll) { _, isOn in
        // Cancel any throttled auto-scroll the moment the user pauses/scrolls.
        // The work item scheduled in the `messages.last?.id` handler captures a
        // *stale* `autoScroll` (SwiftUI views are value types), so its own guard
        // can't see the live paused state — without this cancel, a message that
        // landed in the ~100ms before the user grabbed the list would still yank
        // it to the bottom and fight the scroll.
        pendingScrollWork?.cancel()
        pendingScrollWork = nil
        // Resuming after a pause: snap back to the newest message.
        guard isOn, let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
      .onDisappear {
        pendingScrollWork?.cancel()
        pendingScrollWork = nil
      }
      .overlay(alignment: .bottom) {
        if !autoScroll {
          pausedPill
        }
      }
      .animation(.easeInOut(duration: 0.2), value: autoScroll)
      .animation(.easeInOut(duration: 0.2), value: softPauseRemaining)
      .overlay {
        if messages.isEmpty {
          Text(isConnected ? "Waiting for messages…" : "Connecting to chat…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Shown while the list is frozen. In the soft-pause "read" mode it shows the
  /// "Chat paused" countdown with a wide, bouncing up-chevron hint (the native
  /// "swipe/press up" affordance) floating just above it; once you actually
  /// scroll it collapses to a minimal "Scrolling" tag.
  private var pausedPill: some View {
    VStack(spacing: 6) {
      // Wide, shallow chevron — the conventional "swipe up to go up" hint, like
      // an iOS sheet grabber — floating bare above the pill. Only on the
      // read-pause state, where an up press is the next action. It fades in and
      // performs a single subtle upward drift a beat *after* the pill arrives,
      // and is reset on disappear so it replays on every reopen.
      if softPauseRemaining != nil {
        Image(systemName: "chevron.compact.up")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .opacity(hintShown ? 1 : 0)
          .blur(radius: hintShown ? 0 : 6)
          .offset(y: hintShown ? -3 : 7)
          .onAppear {
            hintShown = false
            withAnimation(.easeOut(duration: 0.7).delay(0.35)) { hintShown = true }
          }
          .onDisappear { hintShown = false }
      }

      HStack(spacing: 8) {
        if let remaining = softPauseRemaining {
          // Twitch-style countdown: a large ring on the left that depletes each
          // second with the number animating inside it. Fixed width, so the pill
          // never resizes as the count ticks down.
          countdownRing(remaining: remaining)
          Text("Chat paused")
            .font(.caption.weight(.semibold))
        } else {
          Image(systemName: "arrow.up.and.down")
            .font(.caption.weight(.bold))
          Text("Scrolling")
            .font(.caption.weight(.semibold))
        }
      }
      .lineLimit(1)
      .fixedSize()
      // Floor both states to the ring's layout height so the "Scrolling" pill is
      // exactly as tall as the "Chat paused" one.
      .frame(minHeight: 28)
      // Dark content to read against the white-tinted "focused" glass, mirroring
      // the chat composer field when it is the focused element.
      .foregroundStyle(.black.opacity(0.8))
      // Tuck the countdown ring into the capsule's left cap so its gap from the
      // left edge matches its (small) gap from the top/bottom.
      .padding(.leading, softPauseRemaining != nil ? 9 : 26)
      .padding(.trailing, 26)
      .padding(.vertical, 14)
      .modifier(PausedPillGlassStyle())
    }
    .padding(.bottom, 12)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  /// A small depleting countdown ring with the remaining seconds animating in
  /// its center. The ring shrinks one step per second (linear over the 1s tick)
  /// and the number uses a numeric content transition. Fixed size so it never
  /// changes the pill's width.
  private func countdownRing(remaining: Int) -> some View {
    let progress = softPauseTotal > 0
      ? max(0, min(1, Double(remaining) / Double(softPauseTotal)))
      : 0
    return ZStack {
      Circle()
        .stroke(.black.opacity(0.16), lineWidth: 4)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(.black.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 1), value: remaining)
      Text("\(remaining)")
        .font(.system(size: 20, weight: .bold))
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .frame(width: 40, height: 40)
    // Let the ring read larger than the label without making the pill taller:
    // the extra height overlaps the pill's own vertical padding instead of
    // pushing the capsule open.
    .padding(.vertical, -8)
  }

  @ViewBuilder
  private func line(for message: ChatMessage) -> some View {
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

    content()
      .padding(.vertical, max(verticalPadding - 2, 3))
      .padding(.horizontal, margin)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        ZStack(alignment: .leading) {
          // A soft radial glow whose origin + spread vary per message (seeded by
          // the line) so highlights don't all read as the same left-to-right ramp.
          // The center stays biased toward the leading edge, anchoring the glow to
          // the accent bar. EllipticalGradient costs about the same as a linear one
          // and uses relative radii, so it needs no GeometryReader.
          EllipticalGradient(
            colors: [
              accent.opacity(isSideLayout ? 0.24 : 0.34),
              accent.opacity(isSideLayout ? 0.04 : 0.07),
            ],
            center: glow.center,
            startRadiusFraction: 0,
            endRadiusFraction: glow.endRadiusFraction
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
      }
      .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .strokeBorder(accent.opacity(isSideLayout ? 0.22 : 0.32), lineWidth: 1)
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
    return resolved
  }

  /// Resolved name colors keyed by the user's color hex (or username) plus the
  /// surface they're drawn on. Parsing the hex, building a Color, and running the
  /// readable-contrast adjustment on every line render is pure repeated work, so
  /// memoize it across the session.
  private static var colorCache: [String: Color] = [:]

  /// Bright, readable defaults (Twitch-style) for users with no color set.
  private static let fallbackPalette: [Color] = [
    Color(twitchHex: "#FF4500")!, Color(twitchHex: "#1E90FF")!, Color(twitchHex: "#00C896")!,
    Color(twitchHex: "#FF69B4")!, Color(twitchHex: "#9ACD32")!, Color(twitchHex: "#FFB000")!,
    Color(twitchHex: "#00CED1")!, Color(twitchHex: "#FF7F50")!, Color(twitchHex: "#BA8AFF")!,
    Color(twitchHex: "#5CD65C")!,
  ]
}

extension Color {
  /// Initialize from a `#RRGGBB` (or `RRGGBB`) hex string.
  init?(twitchHex hex: String) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    self.init(
      .sRGB,
      red: Double((v >> 16) & 0xFF) / 255,
      green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255
    )
  }

  private static func chatLinearize(_ c: CGFloat) -> CGFloat {
    c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  private static func chatRelativeLuminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    0.2126 * chatLinearize(r) + 0.7152 * chatLinearize(g) + 0.0722 * chatLinearize(b)
  }

  private static func chatContrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    let hi = max(a, b)
    let lo = min(a, b)
    return (hi + 0.05) / (lo + 0.05)
  }

  /// Twitch-style "readable colors": nudges this color's lightness until it meets
  /// at least `minRatio` WCAG contrast against `surface` — lightening toward white
  /// on dark surfaces, darkening toward black on light ones — so colored names,
  /// `/me` bodies and special-message accents stay legible whichever chat surface
  /// they're drawn on. Hue is broadly preserved and colors that already pass the
  /// ratio are returned unchanged. `minRatio` defaults to 3.0 (WCAG AA for the
  /// large, bold text used in chat) to keep colors as vivid as Twitch's.
  func chatReadable(onSurface surface: Color, minRatio: CGFloat = 3.0) -> Color {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
    guard UIColor(surface).getRed(&sr, green: &sg, blue: &sb, alpha: &sa) else { return self }

    let surfaceLum = Color.chatRelativeLuminance(sr, sg, sb)
    if Color.chatContrastRatio(Color.chatRelativeLuminance(r, g, b), surfaceLum) >= minRatio {
      return self
    }

    // Blend toward white on a dark surface, toward black on a light one.
    let target: CGFloat = surfaceLum < 0.5 ? 1 : 0
    var best = (r: r, g: g, b: b)
    var step: CGFloat = 0
    while step < 1 {
      step += 0.04
      let nr = r + (target - r) * step
      let ng = g + (target - g) * step
      let nb = b + (target - b) * step
      best = (nr, ng, nb)
      if Color.chatContrastRatio(Color.chatRelativeLuminance(nr, ng, nb), surfaceLum) >= minRatio {
        break
      }
    }
    return Color(.sRGB, red: Double(best.r), green: Double(best.g), blue: Double(best.b), opacity: Double(a))
  }
}

extension String {
  /// A stable index in `0..<count` derived from the string's contents.
  fileprivate func deterministicIndex(_ count: Int) -> Int {
    guard count > 0 else { return 0 }
    let sum = unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return sum % count
  }
}

/// Liquid Glass surface for the paused/scroll indicator pill. These pills are
/// shown only while the viewer is actively holding chat (reading or scrolling),
/// so they *are* the focused element — render them with the same white-tinted,
/// lifted glass the chat composer uses when focused so they read as interactive.
/// Falls back to a solid white capsule on tvOS versions before Liquid Glass.
private struct PausedPillGlassStyle: ViewModifier {
  @Environment(\.glassDisabled) private var glassDisabled
  private var shape: Capsule { Capsule(style: .continuous) }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(.white, in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    } else if #available(tvOS 26.0, *) {
      content
        .glassEffect(.regular.tint(.white), in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    } else {
      content
        .background(.white, in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
  }
}
