import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// A single timestamped diagnostics event (stall, jump, or reload) shown in the
/// experimental latency overlay so playback hiccups can be observed directly.
struct DiagnosticsEvent: Identifiable {
  let id = UUID()
  let at: Date
  let text: String
}

/// Passive latency HUD chip. Its own `View` type so the per-second latency
/// refresh only invalidates this chip, not the whole `PlayerView` body.
/// Holds the once-per-second monitoring bookkeeping written by the live-latency
/// and playback-watchdog tasks. It is a *plain* (non-`@Observable`) reference
/// type on purpose: `PlayerView` keeps it in `@State`, and mutating these
/// properties therefore never invalidates the view. Previously these were
/// individual `@State` values, so each per-second write re-executed the entire
/// PlayerView body and made the focused quality button's highlight flash. None
/// of these values drive the UI directly — the only on-screen latency reading is
/// pushed (de-duplicated) into `LatencyReadout`, which the badge observes.
final class PlaybackMonitorBox {
  var wallClockLatencySeconds: Double?
  var liveEdgeLatencySeconds: Double?
  var smoothedLatencySeconds: Double?
  /// Total settled latency samples since playback became active.
  var latencySampleCount = 0
  /// Consecutive samples whose smoothed value barely moved — i.e. the reading
  /// has stopped climbing off the live edge and looks trustworthy.
  var latencyStableCount = 0
  /// Consecutive samples deviating from the smoothed value by an outlier margin,
  /// used to hold back a transient latency spike until it is corroborated.
  var latencyOutlierStreak = 0
  var isPlaybackActive = false
  var didRequestPlayback = false
  var edgeLatencyLowConfidenceStreak = 0
  var wallClockLowConfidenceStreak = 0
  var lastPlaybackDateSample: Date?
  var lastPlaybackTimeSampleSeconds: Double?
  var lastObservedPlaybackTimeSeconds: Double?
  var stalledPlaybackSamples = 0
  var isRecoveringPlayback = false
  var lastRecoveryAttemptAt = Date.distantPast
  /// Throttle + escalation state for the lightweight live-edge resync that pulls
  /// the playhead back when AVPlayer involuntarily drifts far behind live (the
  /// "rewound 120s and never recovered" failure). Escalates to a full reload only
  /// after repeated resyncs fail to stick.
  var lastLiveResyncAt = Date.distantPast
  var liveResyncAttempts = 0
  /// Throttles the snap-to-true-live reload that fires when the viewer returns to
  /// the live edge atop a stale seekable window.
  var lastLiveEdgeSnapAt = Date.distantPast
  /// When the player first entered a sustained "waiting with a starved buffer"
  /// state. Drives the authoritative end-of-stream (offline) probe.
  var liveStallWaitingSince: Date?
  /// Highest live seekable-edge position seen, and when it stopped advancing.
  /// An ended broadcast freezes the edge, which is a cleaner end-of-stream signal
  /// than the waiting/stall state the anti-stall slow-down keeps flickering.
  var lastLiveEdgeSeconds: Double?
  var liveEdgeFrozenSince: Date?
  /// Guards against overlapping offline probes and rate-limits them.
  var offlineProbeInFlight = false
  var lastOfflineProbeAt = Date.distantPast
  /// Timestamps of recent counted stalls, pruned to a rolling window, used to
  /// detect a chronically-unstable stream (a struggling broadcaster encoder).
  var recentInstabilityEvents: [Date] = []
  /// Set when the stream-stability watchdog has switched into deep-buffer
  /// stability mode; `nil` while the stream is behaving. Latched (sticky) for the
  /// rest of the channel session.
  var streamUnstableSince: Date?
  /// When the most recent stall/jump was counted.
  var lastStallAt: Date?
  /// Set when the stability trip came from the proxy's predictive (manifest)
  /// signal rather than from observed stalls/jumps. Drives the overlay readout.
  var streamUnstableWasPredicted = false
  /// When playback first started advancing for this stream session, used to apply
  /// a more sensitive (single-event) instability trip during the opening seconds.
  var streamPlaybackStartedAt: Date?
  /// Soft-stall deadlock state: when AVPlayer first parked in "waiting despite a
  /// healthy buffer", and when we last issued a play nudge to break it.
  var softStallSince: Date?
  var lastSoftStallNudgeAt = Date.distantPast
  /// When we last nudged a buffer-agnostic frozen playhead (the `toMinimizeStalls`
  /// deadlock that satisfies neither the hard- nor soft-stall buffer signatures).
  var lastFrozenPlayheadNudgeAt = Date.distantPast
}

/// The only latency state SwiftUI observes for the on-screen badge. Updated once
/// per second (and only when the rendered value actually changes), so the badge
/// leaf re-renders in isolation instead of churning the whole player.
@Observable
final class LatencyReadout {
  var color: Color = .gray
  var label: String = "Waiting for playback"

  /// Assigns only on change so an unchanged tick produces no SwiftUI update.
  func update(color newColor: Color, label newLabel: String) {
    if color != newColor { color = newColor }
    if label != newLabel { label = newLabel }
  }
}

/// Top-left player header: the stream title in a large, left-aligned style with a
/// theme-respecting scrim behind it (applied by the caller), plus a plain
/// text + icon subheader holding the live viewer count and/or latency readout.
/// Reads `hermes.viewerCount` and `latency` here (not in the player body) so this
/// leaf re-renders in isolation as those values tick.
struct PlayerTitleHeader: View {
  let title: String
  @Bindable var latency: LatencyReadout
  let hermes: HermesEventService
  /// Source of the Kick live viewer count when a Kick target is merged into the
  /// player; `@Observable`, so the per-platform row re-renders as it resolves.
  let chat: ChatService
  /// Concurrent YouTube viewers for this stream, already gated to "live on
  /// YouTube" by the caller (`nil` when the creator isn't live on YouTube).
  let youtubeViewerCount: Int?
  /// Whether the viewer/latency subheader may appear at all (live only).
  let showSubheader: Bool
  let showLatency: Bool
  let showViewerCount: Bool

  /// Title/subheader foreground. The header sits on the always-dark top scrim
  /// (matching the bottom scrim), so white reads in every theme.
  private var foreground: Color { .white }

  /// Per-platform viewer counts for the platforms the stream is *currently live
  /// on*: Twitch from the pubsub-backed `hermes.viewerCount` (the header only
  /// renders while the Twitch channel is live), YouTube from the public live
  /// snapshot (passed in pre-gated to "live on YouTube"), and Kick from the
  /// merged channel when its Kick target resolved live with a known count. A
  /// platform is only included when it's live and its count is known.
  private var platformViewerCounts: [PlatformViewerCount] {
    guard showViewerCount else { return [] }
    var counts: [PlatformViewerCount] = []
    if let twitchViewers = hermes.viewerCount {
      counts.append(PlatformViewerCount(platform: .twitch, count: twitchViewers))
    }
    if let youtubeViewers = youtubeViewerCount {
      counts.append(PlatformViewerCount(platform: .youtube, count: youtubeViewers))
    }
    if chat.kickMergeEnabled, chat.kickResolvedIsLive, let kickViewers = chat.kickViewerCount {
      counts.append(PlatformViewerCount(platform: .kick, count: kickViewers))
    }
    return counts
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.title3.weight(.bold))
        .foregroundStyle(foreground)
        .lineLimit(2)
        .minimumScaleFactor(0.6)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

      if showSubheader {
        let counts = platformViewerCounts
        if !counts.isEmpty || showLatency {
          HStack(spacing: 16) {
            if !counts.isEmpty {
              HStack(spacing: 16) {
                ForEach(counts) { entry in
                  HStack(spacing: 8) {
                    Icon(glyph: entry.platform.glyph, size: 24)
                      .foregroundStyle(entry.platform.tint)
                    Text(entry.count.formatted(.number))
                      .font(.footnote)
                      .fontWeight(.semibold)
                      .foregroundStyle(foreground)
                      .monospacedDigit()
                      .contentTransition(.numericText())
                  }
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(
                    "\(entry.count.formatted(.number)) watching on \(entry.platform.accessibilityName)"
                  )
                }
              }
            }

            if showLatency {
              HStack(spacing: 8) {
                Circle()
                  .fill(latency.color)
                  .frame(width: 8, height: 8)
                Text(latency.label)
                  .font(.caption)
                  .fontWeight(.semibold)
                  .foregroundStyle(foreground)
              }
            }
          }
          .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
          .animation(.easeInOut(duration: 0.25), value: counts)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Shared frosted Liquid-Glass treatment for the player's small passive HUD chips
/// (viewer/latency readout, sleep countdown). Matches the interactive-moment
/// banner, chat pane, and settings panel: a real `.glassEffect(.regular)` over a
/// subtle black scrim on tvOS 26+, with an `.ultraThinMaterial` fallback, plus
/// the standard white hairline. Keeps every chip reading at the same darkness
/// instead of the lighter bare-material look they had before.
struct HUDChipGlassStyle: ViewModifier {
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette
  func body(content: Content) -> some View {
    let shape = Capsule(style: .continuous)
    if glassDisabled {
      content
        .background(palette.chromeOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
        .clipShape(shape)
    } else if #available(tvOS 26.0, *) {
      content
        .background(palette.chromeOverVideoTint(), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(palette.chromeOverVideoTint(), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
    }
  }
}

/// Isolated state the rewind transport bar observes, mirrored from the player's
/// real `seekableTimeRanges` once per second (and immediately after each seek).
/// Assigns only on change so an unchanged tick produces no SwiftUI update and the
/// bar re-renders in isolation instead of churning the whole player.
@Observable
final class RewindReadout {
  /// 0 = oldest retained moment, 1 = live edge.
  var positionFraction: Double = 1
  /// How far the playhead sits behind the live edge, in seconds.
  var behindLiveSeconds: Double = 0
  /// Total length of the seekable (retained) window, in seconds.
  var windowSeconds: Double = 0
  var isPaused: Bool = false
  var isAtLiveEdge: Bool = true
  /// VOD mode: show elapsed/total time and a neutral (non-live) track instead of
  /// the LIVE edge + "behind live" readout.
  var isVOD: Bool = false
  var elapsedSeconds: Double = 0
  var totalSeconds: Double = 0

  func update(
    positionFraction pf: Double,
    behindLiveSeconds behind: Double,
    windowSeconds window: Double,
    isPaused paused: Bool,
    isAtLiveEdge live: Bool
  ) {
    let clampedPF = min(max(pf, 0), 1)
    if abs(positionFraction - clampedPF) > 0.002 { positionFraction = clampedPF }
    if abs(behindLiveSeconds - behind) > 0.49 { behindLiveSeconds = behind }
    if abs(windowSeconds - window) > 0.49 { windowSeconds = window }
    if isPaused != paused { isPaused = paused }
    if isAtLiveEdge != live { isAtLiveEdge = live }
  }
}

/// Single DVR scrub bar shown along the bottom of the live player, modeled on
/// YouTube's live transport bar. It is the label of a focus-trapping `Button`
/// (the player surface is passive), so left/right step ±10s, the trackpad scrubs
/// with analog precision, clicking it (or the remote play/pause button) toggles
/// pause, and scrubbing/swiping right returns to the live edge. The container is a
/// subtle, fixed Liquid Glass pill; focus emphasis lives on the seek orb, which
/// grows and glows — not on the whole bar.
struct RewindScrubBar: View {
  @Bindable var readout: RewindReadout
  let isFocused: Bool
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  /// Foreground for the track/orb/label. The bar is now chrome-less and floats
  /// directly on the player's (always-dark) bottom scrim, so white reads in every
  /// theme.
  private var chromeForeground: Color {
    .white
  }

  private func behindLabel() -> String {
    if readout.isVOD {
      return "\(Self.clock(readout.elapsedSeconds)) / \(Self.clock(readout.totalSeconds))"
    }
    if readout.isAtLiveEdge { return "LIVE" }
    let total = Int(readout.behindLiveSeconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "-%d:%02d:%02d", h, m, s) }
    return String(format: "-%d:%02d", m, s)
  }

  /// Formats a number of seconds as M:SS, or H:MM:SS for hour-plus durations.
  private static func clock(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
  }

  var body: some View {
    let trackHeight: CGFloat = 6
    let orbSize: CGFloat = isFocused ? 30 : 16
    let fillColor = (readout.isAtLiveEdge && !readout.isVOD) ? Color.red : chromeForeground

    return HStack(spacing: 18) {
      GeometryReader { geo in
        let width = geo.size.width
        let x = max(0, min(width, width * readout.positionFraction))
        ZStack(alignment: .leading) {
          // Full track (retained window).
          Capsule()
            .fill(chromeForeground.opacity(0.20))
            .frame(height: trackHeight)
          // Played / behind-to-live portion.
          Capsule()
            .fill(fillColor)
            .frame(width: x, height: trackHeight)
          // Seek orb — the focus target. Grows and glows when focused.
          ZStack {
            Circle()
              .fill(chromeForeground)
              .frame(width: orbSize, height: orbSize)
              .shadow(
                color: .white.opacity(isFocused ? 0.7 : 0.0),
                radius: isFocused ? 10 : 0)
              .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            if readout.isPaused, isFocused {
              Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(glassDisabled ? palette.chromeOpaqueSurface : .black)
            }
          }
          .frame(width: orbSize, height: orbSize)
          .offset(x: x - orbSize / 2)
          .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .frame(maxHeight: .infinity, alignment: .center)
      }
      .frame(height: 36)

      HStack(spacing: 6) {
        if readout.isAtLiveEdge {
          Circle().fill(.red).frame(width: 8, height: 8)
        }
        Text(behindLabel())
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundStyle(chromeForeground)
          .monospacedDigit()
      }
      .frame(minWidth: 72, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
  }
}

/// Passthrough button style for the scrub bar: the bar provides its own focus
/// emphasis (the orb), so we suppress tvOS's default button chrome (the lift,
/// scale and pressed dimming) that would otherwise fight the custom look.
struct ScrubBarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Reads the Siri Remote trackpad as a *relative* swipe surface for scrubbing.
/// A plain (non-`@Observable`) reference type held in `@State` so its per-frame
/// work never invalidates `PlayerView`; it only calls back out through closures.
///
/// The Siri Remote surfaces as a `GCMicroGamepad`. Setting
/// `reportsAbsoluteDpadValues = true` makes `dpad` report the finger's absolute
/// position in [-1, 1], snapping to exactly (0, 0) on lift. We integrate the
/// frame-to-frame *change* in that position — so a resting finger (however
/// off-center) produces no movement, and only an actual swipe scrubs. The orb
/// tracks how far/fast the finger moved, and a momentum tail continues the glide
/// after release, decaying to a stop.
final class ScrubInputCoordinator {
  /// Fires once a swipe passes the tap threshold (so a click-to-pause never
  /// registers as a scrub). The view pauses playback here.
  var onScrubBegan: (() -> Void)?
  /// Per-frame finger travel (in trackpad units) while swiping or coasting. The
  /// view converts this to timeline seconds proportional to the window.
  var onScrubMoved: ((Double) -> Void)?
  /// Fires when the swipe and its momentum tail have fully settled.
  var onScrubEnded: (() -> Void)?

  private enum Phase { case idle, pending, tracking, momentum }

  private var displayLink: CADisplayLink?
  private var connectObserver: NSObjectProtocol?
  private var phase: Phase = .idle
  private var lastX: Double = 0
  private var pendingTravel: Double = 0
  /// Smoothed finger velocity in units/sec, used to seed the momentum tail.
  private var velocity: Double = 0

  /// Movement (in dpad units) required before a touch counts as a swipe rather
  /// than a tap/click.
  private let tapThreshold = 0.05
  /// Per-frame multiplicative decay applied to the momentum velocity.
  private let momentumDecay = 0.88
  /// Below this speed (units/sec) the momentum tail is considered stopped.
  private let momentumStop = 0.12
  /// Clamp on the seed velocity so a hard flick can't launch a huge jump.
  private let maxMomentumVelocity = 3.0

  func start() {
    guard displayLink == nil else { return }
    configureControllers()
    connectObserver = NotificationCenter.default.addObserver(
      forName: .GCControllerDidConnect, object: nil, queue: .main
    ) { [weak self] _ in self?.configureControllers() }
    let link = CADisplayLink(target: self, selector: #selector(handleTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    if let connectObserver {
      NotificationCenter.default.removeObserver(connectObserver)
    }
    connectObserver = nil
    let wasActive = (phase == .tracking || phase == .momentum)
    phase = .idle
    velocity = 0
    pendingTravel = 0
    if wasActive { onScrubEnded?() }
  }

  private func configureControllers() {
    for controller in GCController.controllers() {
      controller.microGamepad?.reportsAbsoluteDpadValues = true
    }
    GCController.current?.microGamepad?.reportsAbsoluteDpadValues = true
  }

  private func currentTouch() -> (x: Double, touching: Bool) {
    let pad = GCController.current?.microGamepad
      ?? GCController.controllers().first(where: { $0.microGamepad != nil })?.microGamepad
    let x = Double(pad?.dpad.xAxis.value ?? 0)
    let y = Double(pad?.dpad.yAxis.value ?? 0)
    // The dpad snaps to exactly (0, 0) only on lift; a mid-swipe pass through the
    // center still reports tiny non-zero noise, so exact-zero means "not touching".
    return (x, x != 0 || y != 0)
  }

  @objc private func handleTick(_ link: CADisplayLink) {
    let duration = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
    let sample = currentTouch()

    switch phase {
    case .idle:
      if sample.touching {
        phase = .pending
        lastX = sample.x
        pendingTravel = 0
        velocity = 0
      }

    case .pending:
      if sample.touching {
        let dx = sample.x - lastX
        lastX = sample.x
        pendingTravel += dx
        velocity = velocity * 0.6 + (dx / duration) * 0.4
        if abs(pendingTravel) > tapThreshold {
          phase = .tracking
          onScrubBegan?()
          onScrubMoved?(pendingTravel)
        }
      } else {
        // Released without moving far enough — it was a tap/click, not a scrub.
        phase = .idle
      }

    case .tracking:
      if sample.touching {
        let dx = sample.x - lastX
        lastX = sample.x
        velocity = velocity * 0.6 + (dx / duration) * 0.4
        if dx != 0 { onScrubMoved?(dx) }
      } else {
        // Finger lifted: start coasting from the smoothed release velocity.
        velocity = min(max(velocity, -maxMomentumVelocity), maxMomentumVelocity)
        phase = .momentum
      }

    case .momentum:
      // A new finger-down during the coast means the viewer is continuing to
      // scrub. Cancel the momentum tail and pick the live swipe back up
      // immediately rather than swallowing it until the coast decays — that
      // dropped-second-swipe is what felt unresponsive.
      if sample.touching {
        phase = .tracking
        lastX = sample.x
        velocity = 0
        break
      }
      velocity *= momentumDecay
      if abs(velocity) < momentumStop {
        phase = .idle
        velocity = 0
        onScrubEnded?()
      } else {
        onScrubMoved?(velocity * duration)
      }
    }
  }
}

