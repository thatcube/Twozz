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
  var showPlatformBadges: Bool = ChatAppearance.defaultShowPlatformBadges
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
  @Environment(\.themePalette) var palette
  @Environment(\.glassDisabled) var glassDisabled
  /// Drives the swipe-up hint chevron: it fades + drifts up once, slightly after
  /// the pill animates in. Reset to false on disappear so it replays on reopen.
  @State var hintShown = false

  /// Side layout is the only non-glass, non-overlay mode; it follows the
  /// app theme so light mode paints a light chat panel with dark text.
  var isSideLayout: Bool {
    !useGlassBackground && !useLighterOverlayBackground
  }

  /// The nominal surface colored chat text is drawn on, used to keep name colors
  /// and accents at a readable contrast. Overlay/glass modes sit on the dark,
  /// translucent player; only the light-theme side panel is a light surface.
  var chatSurfaceColor: Color {
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

  var isLightChatSurface: Bool {
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

  struct LightSurfaceSignature: Equatable {
    let palette: ThemePalette
    let glassDisabled: Bool
    let isSideLayout: Bool
    let useLighterOverlayBackground: Bool
  }

  static var lightSurfaceMemo: (signature: LightSurfaceSignature, value: Bool)?

  private var messageSpacingValue: CGFloat {
    messageSpacing
  }

  var horizontalPadding: CGFloat {
    ChatAppearance.horizontalPadding(forTextSize: textSize)
  }

  var verticalPadding: CGFloat {
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
      // Pin the list to the bottom natively. Unlike a manual `scrollTo(lastID,
      // anchor: .bottom)` — which must sum the heights of every row above the
      // target, including off-screen lazy rows whose heights are only *estimated*
      // (and fluctuate as the capped buffer trims the front and appends the back),
      // causing the list to overshoot upward then snap back down — this keeps the
      // bottom *content edge* glued to the viewport as content grows. It's a
      // relative pin with no per-item offset math, so live chat stays steady with
      // no upward re-adjustment, and it also absorbs a row growing taller when its
      // emotes finish loading.
      .defaultScrollAnchor(.bottom)
      .onChange(of: scrollTarget) { _, target in
        // Manual scroll: jump to the requested message. Discrete swipes animate
        // for a snappy feel; continuous gesture scrolling sends un-animated
        // targets so the stream of updates reads as a smooth drag.
        guard let target else { return }
        if target.animated {
          withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            proxy.scrollTo(target.id, anchor: target.anchor)
          }
        } else {
          proxy.scrollTo(target.id, anchor: target.anchor)
        }
      }
      .onChange(of: autoScroll) { _, isOn in
        // Resuming after a pause: snap back to the newest message. (Live pinning
        // is handled natively by `defaultScrollAnchor(.bottom)`; this is just the
        // one-shot animated catch-up when the reader rejoins the feed.)
        guard isOn, let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
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
}
