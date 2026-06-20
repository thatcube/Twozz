import SwiftUI

/// The shared live/viewer indicator: a status dot, a textual "LIVE" tag, and the
/// viewer count (or "Offline"). Extracted from `StreamChannelCard` so the Home
/// grid card and the Multiview pane overlay render the exact same badge instead
/// of each reinventing it.
///
/// It is always laid over a guaranteed-dark surface — the bottom video scrim on
/// a card, or a frosted material/dark video frame in a multiview pane — so white
/// content is the correct, legible choice here (this is over-video chrome, not a
/// themed panel). The status is never conveyed by color alone: the red dot is
/// paired with the word "LIVE" for accessibility.
struct LiveBadge: View {
  let isLive: Bool
  let viewerCount: Int?
  /// Larger type + weight for the focused multiview pane, where the badge reads
  /// from across the room; the default matches the compact card treatment.
  var prominent: Bool = false

  private var dotSize: CGFloat { prominent ? 10 : 8 }
  private var labelFont: Font { prominent ? .subheadline.weight(.bold) : .caption2.weight(.bold) }
  private var countFont: Font { prominent ? .subheadline : .caption2 }

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isLive ? Color.red : Color.gray)
        .frame(width: dotSize, height: dotSize)

      if isLive {
        Text("LIVE")
          .font(labelFont)
          .foregroundStyle(Color.white)
          .lineLimit(1)
      }

      if let viewerCount {
        Text("\(viewerCount) watching")
          .font(countFont)
          .foregroundStyle(Color.white.opacity(0.92))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      } else if !isLive {
        Text("Offline")
          .font(countFont)
          .foregroundStyle(Color.white.opacity(0.92))
          .lineLimit(1)
      }
    }
  }
}
