import SwiftUI

/// A scroll instruction for the chat list. The nonce ensures repeated scrolls to
/// the same message still register as a change through `onChange`.
struct ChatScrollTarget: Equatable {
  var id: ChatMessage.ID
  var anchor: UnitPoint
  var nonce: Int
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
  var isConnected: Bool = false
  var emoteURLs: [String: URL] = [:]
  var badgeURLs: [String: URL] = [:]
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
  /// A scroll instruction from the player (manual scroll mode). Changing its
  /// nonce scrolls the list to the given message; the player keeps focus on the
  /// composer because tvOS won't reliably keep focus on the chat ScrollView.
  var scrollTarget: ChatScrollTarget? = nil
  @Environment(\.themePalette) private var palette
  @State private var pendingScrollWork: DispatchWorkItem?

  /// Side layout is the only non-glass, non-overlay mode; it follows the
  /// app theme so light mode paints a light chat panel with dark text.
  private var isSideLayout: Bool {
    !useGlassBackground && !useLighterOverlayBackground
  }

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
        useGlassBackground
          ? AnyShapeStyle(Color.black.opacity(0.22))
          : (useLighterOverlayBackground
            ? AnyShapeStyle(Color(white: 0.13).opacity(0.90))
            : AnyShapeStyle(palette.chatSideSurface)))
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
        // Manual scroll: jump to the requested message with a short animation.
        guard let target else { return }
        pendingScrollWork?.cancel()
        withAnimation(.easeOut(duration: 0.14)) {
          proxy.scrollTo(target.id, anchor: target.anchor)
        }
      }
      .onChange(of: messages.count) {
        guard autoScroll else { return }
        guard let last = messages.last else { return }
        pendingScrollWork?.cancel()
        let work = DispatchWorkItem {
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
        pendingScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
      }
      .onChange(of: autoScroll) { _, isOn in
        // Resuming after a pause: snap back to the newest message.
        guard isOn, let last = messages.last else { return }
        pendingScrollWork?.cancel()
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

  /// Shown while the list is frozen — either the soft-pause read mode (with a
  /// countdown) or the full scrollable pause — so the viewer knows chat is held
  /// and how to get back to live.
  private var pausedPill: some View {
    HStack(spacing: 7) {
      Image(systemName: "pause.fill")
        .font(.caption2.weight(.bold))
      Text(pillText)
        .font(.caption.weight(.semibold))
        .contentTransition(.numericText())
    }
    .lineLimit(1)
    .fixedSize()
    .foregroundStyle(.white)
    .padding(.horizontal, 22)
    .padding(.vertical, 10)
    .modifier(PausedPillGlassStyle())
    .padding(.bottom, 12)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private var pillText: String {
    if let remaining = softPauseRemaining {
      return "Chat paused · \(remaining)s"
    }
    return "Paused · Scroll or press Back"
  }

  private func line(for message: ChatMessage) -> some View {
    return RichChatLineView(
      message: message,
      nameColor: color(for: message),
      globalEmoteURLs: emoteURLs,
      badgeURLs: badgeURLs,
      textSize: textSize,
      emoteSize: emoteSize,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      animatedEmotes: animatedEmotes,
      fontStyle: fontStyle,
      showBadges: showBadges,
      bodyColorOverride: isSideLayout ? palette.chatSidePrimaryText : nil
    )
  }

  /// Use the user's Twitch color, or a stable color derived from their name.
  private func color(for message: ChatMessage) -> Color {
    if let hex = message.colorHex, let c = Color(twitchHex: hex) {
      return c
    }
    return Self.fallbackPalette[message.username.deterministicIndex(Self.fallbackPalette.count)]
  }

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
}

extension String {
  /// A stable index in `0..<count` derived from the string's contents.
  fileprivate func deterministicIndex(_ count: Int) -> Int {
    guard count > 0 else { return 0 }
    let sum = unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return sum % count
  }
}

/// Liquid Glass surface for the paused/scroll indicator pill. Falls back to a
/// translucent material on tvOS versions before Liquid Glass is available.
private struct PausedPillGlassStyle: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content.glassEffect(.regular, in: Capsule())
    } else {
      content
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
  }
}
