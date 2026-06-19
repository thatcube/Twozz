import SwiftUI

/// A read-only chat panel that auto-scrolls to the newest message.
/// Designed as a translucent overlay on top of the video player.
struct ChatView: View {
    let channel: String
    let messages: [ChatMessage]
    var textSize: CGFloat = ChatAppearance.defaultTextSize
    var emoteSize: CGFloat = ChatAppearance.defaultEmoteSize
    var messageSpacing: CGFloat = ChatAppearance.defaultMessageSpacing
    var lineHeight: CGFloat = ChatAppearance.defaultLineHeight
    var animatedEmotes: Bool = true
    var fontDesign: Font.Design = ChatAppearance.defaultFontStyle.design
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
    /// Shared player focus, so the scroll view participates in the page's focus
    /// system (`.chatScroll`) instead of relying on tvOS's implicit overflow
    /// focus, which leaked focus into chat unpredictably.
    var focusBinding: FocusState<PlayerView.Focusable?>.Binding
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
        .background(useGlassBackground
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
            .focused(focusBinding, equals: .chatScroll)
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
            .overlay {
                if messages.isEmpty {
                    Text(isConnected ? "Waiting for messages…" : "Connecting to chat…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Shown while the list is focused and auto-scroll is paused, so the viewer
    /// knows new messages are still arriving below and how to get back to live.
    private var pausedPill: some View {
        Label("Paused · press Back to resume live", systemImage: "pause.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.65), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            animatedEmotes: animatedEmotes,
            fontDesign: fontDesign,
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

private extension String {
    /// A stable index in `0..<count` derived from the string's contents.
    func deterministicIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let sum = unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % count
    }
}
