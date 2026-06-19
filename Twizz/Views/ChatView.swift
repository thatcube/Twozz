import SwiftUI

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
  /// Total soft-pause duration in seconds, used to draw the countdown ring.
  var softPauseTotal: Int = 10
  /// A scroll instruction from the player (manual scroll mode). Changing its
  /// nonce scrolls the list to the given message; the player keeps focus on the
  /// composer because tvOS won't reliably keep focus on the chat ScrollView.
  var scrollTarget: ChatScrollTarget? = nil
  @Environment(\.themePalette) private var palette
  @State private var pendingScrollWork: DispatchWorkItem?
  /// Drives the swipe-up hint chevron: it fades + drifts up once, slightly after
  /// the pill animates in. Reset to false on disappear so it replays on reopen.
  @State private var hintShown = false

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
        // Manual scroll: jump to the requested message. Discrete swipes animate
        // for a snappy feel; continuous gesture scrolling sends un-animated
        // targets so the stream of updates reads as a smooth drag.
        guard let target else { return }
        pendingScrollWork?.cancel()
        if target.animated {
          withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            proxy.scrollTo(target.id, anchor: target.anchor)
          }
        } else {
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
          .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
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
      // Dark content to read against the white-tinted "focused" glass, mirroring
      // the chat composer field when it is the focused element.
      .foregroundStyle(.black.opacity(0.8))
      // Tuck the countdown ring into the capsule's left cap so its gap from the
      // left edge matches its (small) gap from the top/bottom.
      .padding(.leading, softPauseRemaining != nil ? 5 : 22)
      .padding(.trailing, 22)
      .padding(.vertical, 10)
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

/// Liquid Glass surface for the paused/scroll indicator pill. These pills are
/// shown only while the viewer is actively holding chat (reading or scrolling),
/// so they *are* the focused element — render them with the same white-tinted,
/// lifted glass the chat composer uses when focused so they read as interactive.
/// Falls back to a solid white capsule on tvOS versions before Liquid Glass.
private struct PausedPillGlassStyle: ViewModifier {
  private var shape: Capsule { Capsule(style: .continuous) }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
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
