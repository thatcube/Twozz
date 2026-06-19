import SwiftUI

/// Full-bleed audio backdrop in the spirit of Apple Music's "now playing"
/// screen: a slow, living `MeshGradient` that drifts and shifts through the
/// brand's violet → azure → magenta range, with the streamer's avatar resting
/// at center like album art. The audio `level` (0...1) gently nudges the motion
/// and brightness so loud moments bloom without the gradient ever feeling jumpy.
///
/// `MeshGradient` is a single Metal-rendered pass, so this is dramatically
/// cheaper than the previous stack of ~10 overlapping Gaussian blurs.
/// Bridges the observable `AudioLevelMonitor` to `AudioVisualizerView` from
/// within its own small view body. The monitor publishes `level` ~60 times a
/// second; keeping the read here means those updates only invalidate this tiny
/// container (and the orb that needs the value) instead of re-evaluating the
/// whole ~3,700-line `PlayerView` body that hosts it. Purely a scoping wrapper —
/// the visualizer renders identically.
struct AudioVisualizerContainer: View {
  let monitor: AudioLevelMonitor
  let avatarURL: URL?
  let palette: ThemePalette

  var body: some View {
    AudioVisualizerView(
      level: monitor.level,
      avatarURL: avatarURL,
      palette: palette,
      isReactive: monitor.isReceivingRealAudio,
      debugInfo: String(
        format: "%@  lvl %.2f  seg %d  q %d  lag %dms",
        monitor.isReceivingRealAudio ? "REAL" : "AMBIENT",
        monitor.level,
        monitor.decodedSegmentCount,
        monitor.pendingRealSamples,
        monitor.syncLagMs
      )
    )
  }
}

struct AudioVisualizerView: View {
  let level: Double
  let avatarURL: URL?
  let palette: ThemePalette
  var showAvatar: Bool = true
  /// Whether the level is real decoded audio (vs the ambient fallback) — shown
  /// in a temporary on-screen readout while tuning reactivity.
  var isReactive: Bool = false
  var debugInfo: String? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)

      if reduceMotion {
        // Reduce Motion: a single static frame — no mesh drift, ring rotation,
        // or audio-reactive pulsing.
        scene(side: side, t: 0, amp: 0)
      } else {
        TimelineView(.animation) { timeline in
          let t = timeline.date.timeIntervalSinceReferenceDate
          scene(side: side, t: t, amp: level)
        }
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private func scene(side: CGFloat, t: Double, amp: Double) -> some View {
    ZStack {
      MeshGradient(
        width: 3,
        height: 3,
        points: meshPoints(t: t),
        colors: meshColors(t: t),
        smoothsColors: true
      )
      .ignoresSafeArea()

      if showAvatar, let avatarURL {
        avatar(url: avatarURL, side: side, amp: amp, t: t)
      }
    }
    .overlay(alignment: .topLeading) {
      if let debugInfo {
        debugBadge(debugInfo)
      }
    }
  }

  // MARK: - Mesh geometry

  /// Nine control points (row-major 3×3). Corners are pinned; the edge
  /// midpoints and the center drift on gentle, out-of-phase sines so the
  /// gradient morphs continuously. Motion is purely time-driven — the audio
  /// level deliberately does *not* affect the background, only the avatar.
  private func meshPoints(t: Double) -> [SIMD2<Float>] {
    let d: Float = 0.11
    func wob(_ freq: Double, _ phase: Double) -> Float { Float(sin(t * freq + phase)) }

    // Layer a second, slower sine on the center so it traces a wandering
    // figure-eight rather than a simple back-and-forth — more variable motion.
    let cx = 0.5 + d * (wob(0.23, 0.0) * 0.7 + wob(0.11, 1.7) * 0.5)
    let cy = 0.5 + d * (wob(0.19, 1.3) * 0.7 + wob(0.09, 0.4) * 0.5)

    return [
      SIMD2(0, 0),
      SIMD2(0.5 + d * wob(0.27, 0.6), 0),
      SIMD2(1, 0),
      SIMD2(0, 0.5 + d * wob(0.31, 2.1)),
      SIMD2(cx, cy),
      SIMD2(1, 0.5 + d * wob(0.24, 3.4)),
      SIMD2(0, 1),
      SIMD2(0.5 + d * wob(0.29, 4.2), 1),
      SIMD2(1, 1),
    ]
  }

  // MARK: - Mesh color

  /// Shared hue anchors spanning a soft blue → violet → magenta range. This is
  /// clearly multi-color (like Apple Music's now-playing backdrop) yet stays
  /// cohesive and muted. The ring around the avatar samples these *same* hues,
  /// so it always matches whatever the background is currently showing. Hues
  /// only sway on bounded sines, so they never drift into unrelated colors (the
  /// old version accumulated hue over time and wandered into neon green).
  private static let hueAnchors: [Double] = [
    0.58, 0.70, 0.84,
    0.62, 0.74, 0.90,
    0.55, 0.80, 0.88,
  ]

  /// The hue anchors gently swaying over time — shared by the mesh and the ring.
  private func swayedHues(_ t: Double) -> [Double] {
    Self.hueAnchors.enumerated().map { i, h in
      h + sin(t * (0.05 + Double(i) * 0.004) + Double(i) * 0.7) * 0.03
    }
  }

  /// A soft, muted backdrop that morphs gently. Corners sit deep, edges mid, the
  /// center brightest — and each point's brightness breathes slightly so it
  /// feels alive. Saturation stays low for the soft, Apple-Music look. The
  /// motion is purely time-driven and independent of the audio level.
  private func meshColors(t: Double) -> [Color] {
    let hues = swayedHues(t)
    let sat: [Double] = [0.42, 0.40, 0.40, 0.44, 0.34, 0.42, 0.42, 0.40, 0.42]
    let baseBri: [Double] = [0.17, 0.30, 0.17, 0.30, 0.42, 0.30, 0.17, 0.30, 0.17]
    return hues.indices.map { i in
      let bri = baseBri[i] + sin(t * 0.05 + Double(i)) * 0.035
      return Color(hue: hues[i], saturation: sat[i], brightness: bri)
    }
  }

  /// The same hues as the background mesh, but brighter and a touch more
  /// saturated so the ring reads clearly on top while staying in-palette.
  private func ringColors(t: Double) -> [Color] {
    swayedHues(t).map { Color(hue: $0, saturation: 0.6, brightness: 0.78) }
  }

  // MARK: - Center avatar (album-art style)

  /// The avatar rests at center like album art. This is the *only* element that
  /// reacts to the audio: a soft glow blooms behind it, and a multi-color ring —
  /// sampled from the background palette — grows *outward* from the avatar's rim
  /// as a border, so the artwork itself pulses while the background keeps its
  /// slow, independent morph.
  private func avatar(url: URL, side: CGFloat, amp: Double, t: Double) -> some View {
    let size = side * 0.24
    let pulse = CGFloat(amp)
    let ringWidth = 5 + pulse * 18
    let ring = ringColors(t: t)
    return ZStack {
      // Audio-reactive soft glow behind the avatar — blooms with the level.
      Circle()
        .fill(.white.opacity(0.08 + amp * 0.20))
        .frame(width: size * (1.5 + pulse * 0.6), height: size * (1.5 + pulse * 0.6))
        .blur(radius: 44)

      // Multi-color ring growing OUTWARD as a border. The stroke is centered on
      // a circle of diameter `size + ringWidth`, so its inner edge stays pinned
      // exactly to the avatar's rim while louder audio pushes the colored border
      // outward. The conic gradient (closed by repeating the first color) slowly
      // rotates and is sampled from the same hues as the background mesh.
      Circle()
        .stroke(
          AngularGradient(colors: ring + [ring[0]], center: .center, angle: .degrees(t * 12)),
          lineWidth: ringWidth
        )
        .frame(width: size + ringWidth, height: size + ringWidth)
        .opacity(0.6 + amp * 0.4)

      CachedAsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Circle().fill(.white.opacity(0.08))
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
    }
    .animation(.easeOut(duration: 0.12), value: amp)
  }

  private func debugBadge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 22, weight: .semibold, design: .monospaced))
      .foregroundStyle(isReactive ? Color.green : Color.orange)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
      .padding(.top, 40)
      .padding(.leading, 48)
  }
}
