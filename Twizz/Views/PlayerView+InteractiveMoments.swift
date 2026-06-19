import SwiftUI
import UIKit

/// Describes the surface the docked interactive-moment card sits on, so it can
/// match the chat list beneath it. The card is only ever *light* when the chat
/// itself is light (Side layout under the light theme); Glass and Overlay chat
/// always float on the dark translucent player and stay dark.
struct MomentDockStyle: Equatable {
  enum Surface: Equatable {
    /// Glass chat pane: real Liquid Glass over a dark scrim.
    case glass
    /// Overlay chat: a dark lighter-than-side translucent panel.
    case darkOverlay
    /// Side chat: a solid themed panel. Carries the theme surface + text colors
    /// so light mode reads light and dark mode reads dark.
    case side(surface: Color, primaryText: Color)
  }
  let surface: Surface

  /// True only when docked over a genuinely light surface (light-theme Side
  /// chat). Drives text/track contrast so nothing is light unless chat is.
  var isLight: Bool {
    guard case let .side(surface, _) = surface else { return false }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(surface).getWhite(&white, alpha: &alpha)
    return white > 0.5
  }

  var primaryText: Color {
    if case let .side(_, primaryText) = surface, isLight { return primaryText }
    return .white
  }
  var secondaryText: Color {
    isLight ? primaryText.opacity(0.62) : .white.opacity(0.6)
  }
  /// Unfilled progress-bar track.
  var trackColor: Color {
    isLight ? .black.opacity(0.10) : .white.opacity(0.14)
  }
}

// Passive, read-only banners that surface live interactive moments (polls,
// predictions, hype trains, creator goals) for the channel being watched, so
// couch viewers don't miss them. Non-interactive by design: Twitch exposes no
// viewer-side API to vote, and these never take focus or steal input.
extension PlayerView {
  /// Docked above the chat list (see `chatPane`): surfaces the current live
  /// interactive moment sharing the chat's width and surface treatment. Passive
  /// and non-interactive — Twitch exposes no viewer-side API to vote, and this
  /// never takes focus or steals input.
  @ViewBuilder
  func dockedInteractiveMoment(_ moment: InteractiveMoment, style: MomentDockStyle) -> some View {
    let glass = style.surface == .glass
    Group {
      switch moment {
      case .poll(let poll): pollBanner(poll, style: style)
      case .prediction(let prediction): predictionBanner(prediction, style: style)
      case .hypeTrain(let train): hypeTrainBanner(train, style: style)
      case .goal(let goal): goalBanner(goal, style: style)
      }
    }
    // Inset a touch in glass mode so the card clears the pane's rounded corners;
    // flush to the chat width otherwise.
    .padding(.horizontal, glass ? 10 : 12)
    .padding(.top, glass ? 10 : 12)
    .padding(.bottom, 10)
    .allowsHitTesting(false)
  }

  // MARK: - Poll

  @ViewBuilder
  private func pollBanner(_ poll: LivePoll, style: MomentDockStyle) -> some View {
    let ranked = poll.choices.sorted { $0.votes > $1.votes }.prefix(4)
    let leadingID = ranked.first?.id
    momentCard(
      glyph: .chartBar,
      kicker: poll.isActive ? "Live poll" : "Poll results",
      tint: Color(red: 0.65, green: 0.45, blue: 0.95),
      title: poll.title,
      style: style
    ) {
      ForEach(Array(ranked)) { choice in
        MomentBar(
          label: choice.title,
          trailing: Self.percentText(poll.fraction(of: choice)),
          fraction: poll.fraction(of: choice),
          tint: Color(red: 0.65, green: 0.45, blue: 0.95),
          style: style,
          emphasized: choice.id == leadingID)
      }
      Text("\(Self.compact(poll.totalVotes)) votes")
        .font(.caption)
        .foregroundStyle(style.secondaryText)
    }
  }

  // MARK: - Prediction

  @ViewBuilder
  private func predictionBanner(_ prediction: LivePrediction, style: MomentDockStyle) -> some View {
    momentCard(
      glyph: .chartLine,
      kicker: Self.predictionKicker(prediction.status),
      tint: Color(red: 0.36, green: 0.42, blue: 0.95),
      title: prediction.title,
      style: style
    ) {
      ForEach(prediction.outcomes) { outcome in
        MomentBar(
          label: outcome.title,
          trailing: Self.percentText(prediction.fraction(of: outcome)),
          fraction: prediction.fraction(of: outcome),
          tint: Self.predictionColor(outcome.color),
          style: style,
          emphasized: outcome.id == prediction.winningOutcomeID,
          subtitle: "\(Self.compact(outcome.points)) pts · \(Self.compact(outcome.users)) users")
      }
    }
  }

  // MARK: - Hype train

  @ViewBuilder
  private func hypeTrainBanner(_ train: LiveHypeTrain, style: MomentDockStyle) -> some View {
    let tint = Color(red: 0.95, green: 0.45, blue: 0.2)
    momentCard(
      glyph: .flame,
      kicker: Self.hypeTrainKicker(train.phase),
      tint: tint,
      title: Self.hypeTrainTitle(train),
      style: style,
      trailing: {
        if let expiresAt = train.expiresAt, train.phase != .completed {
          HypeTrainCountdown(expiresAt: expiresAt, tint: tint, style: style)
        }
      }
    ) {
      if train.goal > 0 {
        MomentBar(
          label: train.phase == .approaching ? "Contributions to start" : "Progress to next level",
          trailing: Self.percentText(train.fraction),
          fraction: train.fraction,
          tint: tint,
          style: style,
          emphasized: true)
        .padding(.bottom, 8)
      }
    }
  }

  static func hypeTrainKicker(_ phase: LiveHypeTrain.Phase) -> String {
    switch phase {
    case .approaching: return "Hype Train incoming"
    case .active: return "Hype Train"
    case .completed: return "Hype Train complete"
    }
  }

  static func hypeTrainTitle(_ train: LiveHypeTrain) -> String {
    switch train.phase {
    case .approaching:
      return "Starting soon"
    case .active, .completed:
      // Only show a level when we actually know it — better to say nothing than
      // a wrong "Level 1" when the end event omitted the level. The kicker
      // already conveys the completed/active state, so drop the title entirely.
      if let level = train.level { return "Level \(level)" }
      return ""
    }
  }

  // MARK: - Goal

  @ViewBuilder
  private func goalBanner(_ goal: LiveGoal, style: MomentDockStyle) -> some View {
    let tint = Color(red: 0.2, green: 0.78, blue: 0.55)
    momentCard(
      glyph: .targetArrow,
      kicker: goal.kindLabel,
      tint: tint,
      title: goal.description.isEmpty ? goal.kindLabel : goal.description,
      style: style
    ) {
      MomentBar(
        label: "\(Self.compact(goal.current)) / \(Self.compact(goal.target))",
        trailing: Self.percentText(goal.fraction),
        fraction: goal.fraction,
        tint: tint,
        style: style,
        emphasized: true)
    }
  }

  // MARK: - Shared card

  private func momentCard<Trailing: View, Content: View>(
    glyph: Glyph,
    kicker: String,
    tint: Color,
    title: String,
    style: MomentDockStyle,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) -> some View {
    let kickerRow = HStack(spacing: 8) {
      Icon(glyph: glyph, size: 22)
        .foregroundStyle(tint)
      Text(kicker.uppercased())
        .font(.caption2).bold()
        .tracking(1.1)
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }
    return VStack(alignment: .leading, spacing: 10) {
      // Keep the trailing accessory (e.g. the Hype Train timer) on the kicker
      // row when it fits, but let it flow onto its own line once the chat pane
      // is too narrow (the panel is user-resizable down to 300pt).
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          kickerRow
          Spacer(minLength: 8)
          trailing()
        }
        VStack(alignment: .leading, spacing: 6) {
          kickerRow
          trailing()
        }
      }
      if !title.isEmpty {
        Text(title)
          .font(.headline)
          .foregroundStyle(style.primaryText)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .contentTransition(.numericText())
          .animation(.snappy, value: title)
      }
      VStack(alignment: .leading, spacing: 8) {
        content()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(MomentDockSurface(style: style))
  }

  // MARK: - Formatting helpers

  static func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
  }

  static func predictionKicker(_ status: LivePrediction.Status) -> String {
    switch status {
    case .active: return "Prediction open"
    case .locked: return "Prediction locked"
    case .resolved: return "Prediction result"
    case .canceled: return "Prediction canceled"
    }
  }

  /// Compact large counts: 2_444_810 → "2.4M", 12_300 → "12.3K".
  static func compact(_ value: Int) -> String {
    let v = Double(value)
    switch abs(value) {
    case 1_000_000...: return trimmed(v / 1_000_000) + "M"
    case 10_000...: return trimmed(v / 1_000) + "K"
    default: return value.formatted(.number.grouping(.automatic))
    }
  }

  private static func trimmed(_ d: Double) -> String {
    let s = String(format: "%.1f", d)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
  }

  static func predictionColor(_ raw: String) -> Color {
    raw.uppercased() == "PINK"
      ? Color(red: 0.93, green: 0.28, blue: 0.6)
      : Color(red: 0.36, green: 0.55, blue: 0.98)
  }

  /// Debug-only: cycle a sample moment through all four banner types so the
  /// overlay can be verified on-device without waiting for a real broadcaster
  /// event. Order: poll → prediction → hype train → goal → clear.
  func simulateInteractiveMoment() {
    showChatSettings = false
    let samples: [InteractiveMoment?] = [
      .poll(
        LivePoll(
          id: "debug-poll",
          title: "Which map next?",
          choices: [
            .init(id: "a", title: "Dust II", votes: 1842),
            .init(id: "b", title: "Mirage", votes: 1207),
            .init(id: "c", title: "Inferno", votes: 663),
          ],
          isActive: true
        )
      ),
      .prediction(
        LivePrediction(
          id: "debug-pred",
          title: "Will they clutch this round?",
          outcomes: [
            .init(id: "blue", title: "Yes, easy", color: "BLUE", points: 48200, users: 312),
            .init(id: "pink", title: "No chance", color: "PINK", points: 21750, users: 145),
          ],
          status: .active,
          winningOutcomeID: nil
        )
      ),
      .hypeTrain(
        LiveHypeTrain(
          id: "debug-train-approaching", level: 1, progress: 2, goal: 3,
          phase: .approaching, expiresAt: Date().addingTimeInterval(45))
      ),
      .hypeTrain(
        LiveHypeTrain(
          id: "debug-train", level: 3, progress: 1280, goal: 2500,
          phase: .active, expiresAt: Date().addingTimeInterval(255))
      ),
      .goal(
        LiveGoal(
          id: "debug-goal",
          description: "Road to 10k followers",
          contributionType: "FOLLOWERS",
          current: 8420,
          target: 10000
        )
      ),
      nil,
    ]
    let moment = samples[debugMomentIndex % samples.count]
    debugMomentIndex += 1
    hermes.debugInject(moment)
  }
}

/// A labelled horizontal progress bar used inside moment cards.
private struct MomentBar: View {
  let label: String
  let trailing: String
  let fraction: Double
  let tint: Color
  let style: MomentDockStyle
  var emphasized: Bool = false
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
          .font(.subheadline).fontWeight(emphasized ? .semibold : .regular)
          .foregroundStyle(style.primaryText)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(trailing)
          .font(.subheadline).bold()
          .foregroundStyle(style.primaryText.opacity(0.9))
          .monospacedDigit()
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(style.trackColor)
          Capsule()
            .fill(tint.opacity(emphasized ? 1 : 0.75))
            .frame(width: max(6, geo.size.width * fraction))
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: fraction)
        }
      }
      .frame(height: 8)
      if let subtitle {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(style.secondaryText)
      }
    }
  }
}

/// A live, self-updating countdown to a Hype Train's expiry, sized to tuck into
/// the card header's top-right. Uses SwiftUI's `Text(timerInterval:)` so the
/// clock ticks without a manual timer, and clamps to `0:00` once the window has
/// lapsed (an out-of-order range would trap).
private struct HypeTrainCountdown: View {
  let expiresAt: Date
  let tint: Color
  let style: MomentDockStyle

  var body: some View {
    HStack(spacing: 4) {
      Icon(glyph: .clock, size: 13)
        .foregroundStyle(tint)
      Group {
        if expiresAt > .now {
          Text(timerInterval: Date.now...expiresAt, countsDown: true)
        } else {
          Text("0:00")
        }
      }
      .font(.caption).bold()
      .monospacedDigit()
      .foregroundStyle(style.primaryText.opacity(0.9))
      .lineLimit(1)
      .fixedSize()
    }
  }
}
/// every chat variant (Glass / Overlay / Side), matching the chat pane and
/// settings panel: `.glassEffect(.regular)` over a light/dark scrim with a plain
/// neutral hairline. The scrim and hairline only go light when the chat itself
/// is light (Side layout under the light theme); otherwise the glass stays dark.
/// No tinted border — the glass is left to read naturally.
private struct MomentDockSurface: ViewModifier {
  let style: MomentDockStyle

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 30, style: .continuous)
  }

  /// Subtle scrim under the glass so card text stays legible over busy chat.
  private var scrim: Color {
    style.isLight ? .white.opacity(0.35) : .black.opacity(0.22)
  }
  private var hairline: Color {
    style.isLight ? .black.opacity(0.08) : .white.opacity(0.12)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(tvOS 26.0, *) {
      content
        .background(scrim, in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(hairline, lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(scrim, in: shape)
        .overlay(shape.strokeBorder(hairline, lineWidth: 1))
    }
  }
}
