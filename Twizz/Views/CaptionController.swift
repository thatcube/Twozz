import SwiftUI

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
        playerClock: (() -> Date?)? = nil
    ) {
        let shouldRun = enabled && isLive && isReady && playlistURL != nil && Self.isSupported
        let key = shouldRun ? playlistURL?.absoluteString : nil
        // Keep the latest clock even when the config key is unchanged, so the
        // playhead sampler always reads the current player.
        self.playerClock = shouldRun ? playerClock : nil
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
                Task { await engine.setPlayhead(date) }
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
    }

    private func clearText() {
        finalizedLines.removeAll()
        volatileLine = ""
        failed = false
    }
}

/// Rolling on-video caption overlay. Native styling: a legible material slab,
/// system fonts, bottom-center, lifted above the control bar when controls are
/// visible. Honors Reduce Transparency (`glassDisabled`) and Reduce Motion.
struct CaptionOverlayView: View {
    let controller: CaptionController
    /// True while the player's bottom control bar is on screen, so the overlay
    /// can sit higher and not collide with it (or the interactive-moment dock).
    let controlsVisible: Bool

    @Environment(\.glassDisabled) private var glassDisabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String { controller.displayText }

    var body: some View {
        Group {
            if !text.isEmpty {
                Text(text)
                  .font(.system(.title2, weight: .semibold))
                  .multilineTextAlignment(.center)
                  .foregroundStyle(.white)
                  .lineLimit(2)
                  // Keep the most recent words visible; drop older ones off the
                  // front rather than hiding what was just said.
                  .truncationMode(.head)
                  .fixedSize(horizontal: false, vertical: true)
                  .padding(.horizontal, 28)
                  .padding(.vertical, 14)
                  .background(captionBackground)
                  .frame(maxWidth: 1200)
                  .padding(.bottom, controlsVisible ? 260 : 96)
                  .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                  .accessibilityLabel("Live captions")
                  .accessibilityValue(text)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private var captionBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                glassDisabled
                    ? AnyShapeStyle(Color.black.opacity(0.82))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
    }
}
