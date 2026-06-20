import SwiftUI

/// How the caption slab is drawn behind the text. User-selectable in caption
/// settings; `blur` falls back to `dim` automatically when Reduce Transparency
/// (`glassDisabled`) is on.
enum CaptionBackgroundStyle: String, CaseIterable, Identifiable {
    case blur
    case dim
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: return "Blur"
        case .dim: return "Dim"
        case .none: return "None"
        }
    }

    static func from(_ raw: String) -> CaptionBackgroundStyle {
        CaptionBackgroundStyle(rawValue: raw) ?? .blur
    }
}

/// Caption text color, user-selectable in caption settings. A small preset
/// palette (rather than a free RGB picker) keeps selection fast on the Siri
/// Remote and every choice legible over video. Stored as a raw string in
/// `@AppStorage` because SwiftUI `Color` isn't directly persistable — same
/// pattern as `CaptionBackgroundStyle`.
enum CaptionTextColor: String, CaseIterable, Identifiable {
    case white
    case gray
    case yellow
    case amber
    case mint
    case cyan
    case lavender
    case rose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .gray: return "Gray"
        case .yellow: return "Yellow"
        case .amber: return "Amber"
        case .mint: return "Mint"
        case .cyan: return "Cyan"
        case .lavender: return "Lavender"
        case .rose: return "Rose"
        }
    }

    /// The drawn color. Curated for legibility over video and for looking good:
    /// readability research favors white and yellow, so those anchor the set; the
    /// rest are high-luminance, low-saturation tints (not the harsh system
    /// primaries) that stay readable on bright frames. Pure red/blue/green are
    /// deliberately omitted — they're low-luminance and worst for color-vision
    /// deficiency. `gray` is a softened white, gentler on OLED panels where pure
    /// white can feel harsh. No black: it disappears on dark video.
    var color: Color {
        switch self {
        case .white: return .white
        case .gray: return Color(white: 0.74)
        case .yellow: return Color(red: 1.0, green: 0.87, blue: 0.40)
        case .amber: return Color(red: 1.0, green: 0.74, blue: 0.45)
        case .mint: return Color(red: 0.55, green: 0.93, blue: 0.70)
        case .cyan: return Color(red: 0.50, green: 0.85, blue: 1.0)
        case .lavender: return Color(red: 0.78, green: 0.72, blue: 1.0)
        case .rose: return Color(red: 1.0, green: 0.67, blue: 0.80)
        }
    }

    static func from(_ raw: String) -> CaptionTextColor {
        CaptionTextColor(rawValue: raw) ?? .white
    }
}

/// Bridges the (tvOS 26-gated) `LiveCaptionEngine` to SwiftUI, and owns the
/// rolling caption text shown by `CaptionOverlayView`.
///
/// The class itself is **not** availability-gated so `PlayerView` can hold it as
/// plain `@State` on any OS; the gated engine is stored as `Any?` and only ever
/// touched inside `if #available(tvOS 26.0, *)` blocks. On older OSes the
/// controller is inert and `isSupported` is false, so the toggle is hidden.
@MainActor
@Observable
final class CaptionController {
    /// Settled caption lines (most recent last). Capped to a short rolling window.
    private(set) var finalizedLines: [String] = []
    /// The in-progress line still being refined by the recognizer.
    private(set) var volatileLine: String = ""
    /// True once the engine is running for the current stream.
    private(set) var isActive = false

    /// Whether the engine could not start (e.g. no on-device model for the
    /// locale). Surfaced so the UI can explain rather than silently show nothing.
    private(set) var failed = false

    /// The single rolling caption to display: the most recent settled phrase
    /// continued by the phrase currently forming. One evolving line rather than a
    /// growing stack, so it reads like live broadcast captions.
    var displayText: String {
        [finalizedLines.last, volatileLine.isEmpty ? nil : volatileLine]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var engine: Any?
    private var startTask: Task<Void, Never>?
    /// Samples the player playhead on the main actor and forwards it into the
    /// (Sendable-safe) engine. The clock closure captures `AVPlayer`, which isn't
    /// Sendable, so it must only ever be called here on the MainActor.
    private var playerClock: (() -> Date?)?
    private var playheadTimer: Timer?
    /// User timing fine-tune (seconds), forwarded into the engine each tick.
    private var timingOffset: TimeInterval = 0
    /// Clears stale captions when the speaker goes quiet, so the last phrase
    /// doesn't linger on screen indefinitely.
    private var idleTimer: Timer?
    private let idleTimeout: TimeInterval = 4.0
    /// Identity of the currently-running configuration, so repeated `sync` calls
    /// with unchanged inputs don't tear down and restart the engine.
    private var activeKey: String?

    private let maxLines = 1

    /// Whether on-device caption generation is even possible on this OS. Hardware
    /// capability (model availability) is confirmed asynchronously once started.
    static var isSupported: Bool {
        if #available(tvOS 26.0, *) { return true }
        return false
    }

    /// Reconcile the engine with the desired state. Safe to call frequently
    /// (e.g. from several `.onChange` hooks) — it no-ops when nothing changed.
    func sync(
        enabled: Bool,
        playlistURL: URL?,
        headers: [String: String],
        isLive: Bool,
        isReady: Bool,
        timingOffset: TimeInterval = 0,
        playerClock: (() -> Date?)? = nil
    ) {
        let shouldRun = enabled && isLive && isReady && playlistURL != nil && Self.isSupported
        let key = shouldRun ? playlistURL?.absoluteString : nil
        // Keep the latest clock even when the config key is unchanged, so the
        // playhead sampler always reads the current player.
        self.playerClock = shouldRun ? playerClock : nil
        // Likewise keep the latest timing fine-tune live without a restart.
        self.timingOffset = timingOffset
        if key == activeKey { return }
        activeKey = key

        stopEngine()

        guard shouldRun, let url = playlistURL else {
            clearText()
            return
        }

        guard #available(tvOS 26.0, *) else { return }

        failed = false
        let engine = LiveCaptionEngine(
            playlistURL: url,
            headers: headers
        ) { [weak self] line in
            Task { @MainActor in self?.apply(line) }
        }
        self.engine = engine
        isActive = true
        startPlayheadTimer()
        startTask = Task { [weak self] in
            do {
                try await engine.start()
            } catch {
                await MainActor.run {
                    self?.failed = true
                    self?.isActive = false
                }
            }
        }
    }

    /// Fully stop captioning and clear any displayed text (channel exit/teardown).
    func stop() {
        activeKey = nil
        playerClock = nil
        stopEngine()
        clearText()
    }

    private func stopEngine() {
        startTask?.cancel()
        startTask = nil
        playheadTimer?.invalidate()
        playheadTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        isActive = false
        if #available(tvOS 26.0, *), let engine = engine as? LiveCaptionEngine {
            Task { await engine.stop() }
        }
        engine = nil
    }

    /// Samples the player playhead ~4x/sec on the main actor and pushes the plain
    /// `Date` into the engine, which uses it to release buffered audio in step
    /// with playback (so captions don't run ahead of the visible frame).
    private func startPlayheadTimer() {
        playheadTimer?.invalidate()
        guard #available(tvOS 26.0, *), let engine = engine as? LiveCaptionEngine else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let date = self?.playerClock?()
                let offset = self?.timingOffset ?? 0
                Task {
                    await engine.setTimingOffset(offset)
                    await engine.setPlayhead(date)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func apply(_ line: CaptionLine) {
        if line.isVolatile {
            volatileLine = line.text
        } else {
            finalizedLines.append(line.text)
            if finalizedLines.count > maxLines {
                finalizedLines.removeFirst(finalizedLines.count - maxLines)
            }
            volatileLine = ""
        }
        scheduleIdleClear()
    }

    /// Restart the idle countdown on every recognized update; if no new caption
    /// arrives within `idleTimeout`, fade the lingering text away.
    private func scheduleIdleClear() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearDisplayed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Clear only the on-screen caption text (keeps the engine running).
    private func clearDisplayed() {
        finalizedLines.removeAll()
        volatileLine = ""
    }

    private func clearText() {
        idleTimer?.invalidate()
        idleTimer = nil
        finalizedLines.removeAll()
        volatileLine = ""
        failed = false
    }
}

/// Rolling on-video caption overlay. Native styling: system fonts on a legible
/// slab, honoring Reduce Transparency (`glassDisabled`) and Reduce Motion. The
/// user controls (in caption settings) drive text size, vertical position, the
/// background style, and an optional outline for legibility over bright video.
struct CaptionOverlayView: View {
    let controller: CaptionController
    /// True while the player's bottom control bar is on screen, so the overlay
    /// lifts above it (and the interactive-moment dock) at the lowest positions.
    let controlsVisible: Bool
    /// Multiplier on the base caption font size (user "Text Size" control).
    var fontScale: Double = 1.0
    /// 0 = bottom of the safe area, 1 = top; negatives push below the edge into
    /// overscan (user "Position" control).
    var verticalPosition: Double = 0.0
    /// Slab background treatment (user "Background" control).
    var backgroundStyle: CaptionBackgroundStyle = .blur
    /// Draw a dark outline around the glyphs for legibility (user toggle).
    var outline: Bool = false
    /// Caption text color (user "Color" control).
    var textColor: Color = .white
    /// Caption text opacity 0…1 (user "Opacity" control).
    var textOpacity: Double = 1.0

    @Environment(\.glassDisabled) private var glassDisabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String { controller.displayText }

    /// Base point size (tvOS, ~title2) before the user scale is applied.
    private let baseFontSize: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            if !text.isEmpty {
                captionSlab
                    .frame(maxWidth: 1200)
                    .position(
                        x: geo.size.width / 2,
                        y: captionCenterY(in: geo.size.height)
                    )
                    .transition(appearTransition)
            }
        }
        // Animate only the overlay appearing/disappearing (empty ↔ non-empty);
        // text swaps while it's on screen stay instant for readability.
        .animation(.easeOut(duration: 0.22), value: text.isEmpty)
        .allowsHitTesting(false)
    }

    /// Captions ease up from the bottom with a soft blur as they appear (and
    /// reverse on disappear). Reduce Motion drops the slide/blur for a plain fade.
    private var appearTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .bottom)).combined(with: .captionBlur)
    }

    private var captionSlab: some View {
        Text(text)
            .font(.system(size: baseFontSize * fontScale, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(textColor.opacity(textOpacity))
            .lineLimit(1)
            // Single, fixed-height line that always shows the most recent words
            // (older ones scroll off the front) — avoids the jank of the slab
            // growing to two lines and snapping back to one.
            .truncationMode(.head)
            .captionOutline(outline)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(captionBackground)
            .accessibilityLabel("Live captions")
            .accessibilityValue(text)
    }

    /// Map the position control to a vertical center. `0` hugs the bottom
    /// title-safe edge; `1` sits near the top. **Negative** values continue past
    /// the bottom anchor into overscan (deliberately allowed so captions can be
    /// pushed lower than the safe edge), using a compact pixel step so the small
    /// overscan band isn't blown past in a single notch. When the control bar is
    /// visible the caption is clamped up so it never hides behind the controls /
    /// interactive-moment dock.
    private func captionCenterY(in height: CGFloat) -> CGFloat {
        let bottomInset: CGFloat = 56
        let topMargin: CGFloat = 80
        let low = height - bottomInset
        let high = topMargin
        let span = low - high
        let p = CGFloat(verticalPosition)

        var center: CGFloat
        if p >= 0 {
            center = low - p * span
        } else {
            // Below the bottom anchor: ~120pt of extra drop per 1.0 of negative
            // position, so the limited overscan region steps gradually.
            let overscanPerUnit: CGFloat = 120
            center = low - p * overscanPerUnit
        }

        if controlsVisible {
            let controlsFloor = height - 260
            center = min(center, controlsFloor)
        }
        return center
    }

    @ViewBuilder
    private var captionBackground: some View {
        switch backgroundStyle {
        case .none:
            Color.clear
        case .dim:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
        case .blur:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    // Reduce Transparency falls back to a solid dim slab.
                    glassDisabled
                        ? AnyShapeStyle(Color.black.opacity(0.82))
                        : AnyShapeStyle(.ultraThinMaterial)
                )
        }
    }
}

private extension AnyTransition {
    /// Blurs the slab in/out as part of the appear transition.
    static var captionBlur: AnyTransition {
        .modifier(
            active: CaptionBlurModifier(radius: 14),
            identity: CaptionBlurModifier(radius: 0)
        )
    }
}

private struct CaptionBlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

private extension View {
    /// Cheap text outline: four hard 1.5pt black shadows at the corners. Applied
    /// only when the user enables it, to stay legible over bright/no-background.
    @ViewBuilder
    func captionOutline(_ enabled: Bool) -> some View {
        if enabled {
            self
                .shadow(color: .black.opacity(0.9), radius: 0, x: 1.5, y: 1.5)
                .shadow(color: .black.opacity(0.9), radius: 0, x: -1.5, y: 1.5)
                .shadow(color: .black.opacity(0.9), radius: 0, x: 1.5, y: -1.5)
                .shadow(color: .black.opacity(0.9), radius: 0, x: -1.5, y: -1.5)
        } else {
            self
        }
    }
}
