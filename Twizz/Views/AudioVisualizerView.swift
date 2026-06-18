import SwiftUI

/// Full-bleed audio-only backdrop: a single liquid-glass orb that breathes and
/// ripples with the audio, the streamer's avatar floating at its core.
///
/// `level` (0...1) comes from `AudioLevelMonitor`. The decorative motion
/// (rotation, shimmer drift, ripple emanation) is time-driven so it stays smooth
/// regardless of the audio source; only the *amplitude* of breathing/ripples is
/// scaled by `level`.
struct AudioVisualizerView: View {
  let level: Double
  let avatarURL: URL?
  let palette: ThemePalette
  var showAvatar: Bool = true

  // Audio-flavoured accent so the orb pops on the black player backdrop.
  private let accentA = Color(red: 0.62, green: 0.42, blue: 1.00)  // violet
  private let accentB = Color(red: 0.32, green: 0.72, blue: 1.00)  // azure

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let diameter = side * 0.46

      TimelineView(.animation) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
        // Continuous gentle breath, lifted by the live audio level.
        let breath = (sin(t * 1.6) * 0.5 + 0.5) * 0.012
        let amp = level
        let scale = 1.0 + breath + amp * 0.06

        ZStack {
          halo(diameter: diameter, amp: amp, t: t)
          rippleRings(diameter: diameter, amp: amp, t: t)

          orb(diameter: diameter, amp: amp, t: t)
            .scaleEffect(scale)

          core(diameter: diameter, amp: amp)
            .scaleEffect(scale)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .position(x: geo.size.width / 2, y: geo.size.height / 2)
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  // MARK: - Glow halo + drifting caustics

  private func halo(diameter: CGFloat, amp: Double, t: Double) -> some View {
    let haloSize = diameter * 2.3
    return ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              accentA.opacity(0.45 * (0.5 + amp)),
              accentB.opacity(0.22 * (0.5 + amp)),
              .clear,
            ],
            center: .center,
            startRadius: diameter * 0.18,
            endRadius: haloSize * 0.5
          )
        )
        .frame(width: haloSize, height: haloSize)
        .blur(radius: 28)

      // Two slow caustic blobs that drift around the orb for a liquid feel.
      caustic(color: accentB, diameter: diameter, radius: diameter * 0.62,
              speed: 0.23, phase: 0, amp: amp, t: t)
      caustic(color: accentA, diameter: diameter, radius: diameter * 0.7,
              speed: -0.17, phase: 2.4, amp: amp, t: t)
    }
  }

  private func caustic(
    color: Color, diameter: CGFloat, radius: CGFloat,
    speed: Double, phase: Double, amp: Double, t: Double
  ) -> some View {
    let angle = t * speed + phase
    let x = cos(angle) * radius
    let y = sin(angle * 1.3) * radius * 0.7
    return Circle()
      .fill(color.opacity(0.30 + amp * 0.25))
      .frame(width: diameter * 0.5, height: diameter * 0.5)
      .blur(radius: 50)
      .offset(x: x, y: y)
  }

  // MARK: - Sonar-style ripple rings

  private func rippleRings(diameter: CGFloat, amp: Double, t: Double) -> some View {
    let ringCount = 3
    return ZStack {
      ForEach(0..<ringCount, id: \.self) { i in
        let phase = ((t * 0.32) + Double(i) / Double(ringCount))
          .truncatingRemainder(dividingBy: 1.0)
        let ringDiameter = diameter * (1.0 + phase * 0.95)
        let fade = (1.0 - phase)
        Circle()
          .stroke(
            LinearGradient(
              colors: [accentA.opacity(0.9), accentB.opacity(0.6)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1.5 + fade * 2.0
          )
          .frame(width: ringDiameter, height: ringDiameter)
          .opacity(fade * (0.08 + amp * 0.5))
      }
    }
  }

  // MARK: - Glass orb body

  private func orb(diameter: CGFloat, amp: Double, t: Double) -> some View {
    ZStack {
      // Translucent glass body.
      Circle()
        .fill(
          RadialGradient(
            colors: [
              .white.opacity(0.24),
              accentA.opacity(0.30),
              accentB.opacity(0.18),
              .black.opacity(0.32),
            ],
            center: UnitPoint(x: 0.36, y: 0.30),
            startRadius: 0,
            endRadius: diameter * 0.62
          )
        )

      // Inner liquid shimmer — blurred accent blobs orbiting inside the glass.
      shimmer(diameter: diameter, amp: amp, t: t)
        .clipShape(Circle())

      // Top-left specular highlight.
      Ellipse()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.55), .clear],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.26
          )
        )
        .frame(width: diameter * 0.5, height: diameter * 0.34)
        .blur(radius: 10)
        .offset(x: -diameter * 0.16, y: -diameter * 0.2)
        .clipShape(Circle())

      // Glass rim.
      Circle()
        .strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.7), .white.opacity(0.05), accentB.opacity(0.4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 2
        )
    }
    .frame(width: diameter, height: diameter)
    .modifier(LiquidGlassOrbRim(diameter: diameter))
    .shadow(color: accentA.opacity(0.45 + amp * 0.3), radius: 30 + amp * 24)
  }

  private func shimmer(diameter: CGFloat, amp: Double, t: Double) -> some View {
    ZStack {
      blob(color: accentB, size: diameter * 0.7, radius: diameter * 0.18,
           speed: 0.5, phase: 0.0, t: t)
      blob(color: accentA, size: diameter * 0.6, radius: diameter * 0.22,
           speed: -0.37, phase: 1.7, t: t)
      blob(color: .white, size: diameter * 0.32, radius: diameter * 0.16,
           speed: 0.8, phase: 3.1, t: t)
        .opacity(0.25 + amp * 0.2)
    }
  }

  private func blob(
    color: Color, size: CGFloat, radius: CGFloat,
    speed: Double, phase: Double, t: Double
  ) -> some View {
    let angle = t * speed + phase
    return Circle()
      .fill(color.opacity(0.4))
      .frame(width: size, height: size)
      .blur(radius: 26)
      .offset(x: cos(angle) * radius, y: sin(angle * 1.2) * radius)
  }

  // MARK: - Center (avatar or glowing core)

  @ViewBuilder
  private func core(diameter: CGFloat, amp: Double) -> some View {
    if showAvatar, let avatarURL {
      let avatarSize = diameter * 0.56
      AsyncImage(url: avatarURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        glowCore(diameter: diameter, amp: amp)
      }
      .frame(width: avatarSize, height: avatarSize)
      .clipShape(Circle())
      .overlay(
        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2)
      )
      .overlay(
        // Subtle inner vignette so the avatar sits *inside* the glass.
        Circle()
          .fill(
            RadialGradient(
              colors: [.clear, .black.opacity(0.28)],
              center: .center,
              startRadius: avatarSize * 0.3,
              endRadius: avatarSize * 0.52
            )
          )
      )
      .shadow(color: .black.opacity(0.4), radius: 12)
    } else {
      glowCore(diameter: diameter, amp: amp)
    }
  }

  private func glowCore(diameter: CGFloat, amp: Double) -> some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [
            .white.opacity(0.9),
            accentA.opacity(0.7 + amp * 0.3),
            .clear,
          ],
          center: .center,
          startRadius: 0,
          endRadius: diameter * 0.3
        )
      )
      .frame(width: diameter * 0.5, height: diameter * 0.5)
      .blur(radius: 6)
  }
}

/// Adds genuine Liquid Glass refraction to the orb rim on tvOS 26+, and is a
/// no-op on earlier systems (the hand-built gradient glass carries the look).
private struct LiquidGlassOrbRim: ViewModifier {
  let diameter: CGFloat

  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content.glassEffect(.regular, in: Circle())
    } else {
      content
    }
  }
}
