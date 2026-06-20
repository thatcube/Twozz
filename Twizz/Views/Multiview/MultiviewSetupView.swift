import SwiftUI

/// One titled group of channels offered on the multiview setup screen — e.g.
/// "Following", "Recommended for you", "Popular right now". Sections let the
/// picker double as a discovery surface instead of only listing follows.
struct MultiviewChannelSection: Identifiable {
  let id: String
  let title: String
  let channels: [FollowedChannel]
}

/// Picks up to ``multiviewPaneLimit`` live channels to watch together, then
/// hands the ordered selection to the multiview grid.
///
/// Channels are grouped into discovery sections (Following first, then
/// recommendations and popular streams) and rendered as native horizontal rails
/// of ``StreamChannelCard`` — the same card the Home grid uses, so each option
/// brings the thumbnail, hover-preview video, LIVE/viewer badge, avatar, and
/// title for free — wrapped in a selection overlay that shows the pick order, a
/// native focus-color ring when selected, and dims unselected cards once the
/// four-pick limit is reached.
struct MultiviewSetupView: View {
  let sections: [MultiviewChannelSection]
  var onStart: ([FollowedChannel]) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  /// Selected channel ids, in pick order — that order drives grid placement.
  @State private var selectedIDs: [String] = []
  /// Set when the user activates a tile that's already at the pick limit; drives
  /// the "max streams" toast. A fresh token on each rejection restarts the
  /// auto-dismiss timer so rapid presses keep the toast visible.
  @State private var limitToastToken: UUID?
  @FocusState private var focusedID: String?

  /// Each card's media is a 16:9 thumbnail; this width keeps roughly three
  /// cards visible per rail on a 1080/4K tvOS layout.
  private let cardWidth: CGFloat = 440

  /// Live channels per section, deduped so a channel that appears in several
  /// pools is only offered once (in its highest-priority section).
  private var resolvedSections: [MultiviewChannelSection] {
    var seen = Set<String>()
    var result: [MultiviewChannelSection] = []
    for section in sections {
      let live = section.channels.filter { $0.isLive && seen.insert($0.id).inserted }
      if !live.isEmpty {
        result.append(MultiviewChannelSection(id: section.id, title: section.title, channels: live))
      }
    }
    return result
  }

  /// Flattened lookup of every offered channel, for resolving the selection.
  private var allChannels: [FollowedChannel] {
    resolvedSections.flatMap(\.channels)
  }

  private var hasChannels: Bool { !resolvedSections.isEmpty }
  private var isAtLimit: Bool { selectedIDs.count >= multiviewPaneLimit }
  private var canStart: Bool { selectedIDs.count >= 2 }

  private var orderedSelection: [FollowedChannel] {
    selectedIDs.compactMap { id in allChannels.first { $0.id == id } }
  }

  var body: some View {
    ZStack {
      AppBackground(palette: palette).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        header

        if !hasChannels {
          emptyState
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
              ForEach(resolvedSections) { section in
                sectionRail(section)
              }
            }
            .padding(.vertical, 28)
          }
        }
      }
    }
    .overlay(alignment: .bottom) {
      if limitToastToken != nil {
        limitToast
          .padding(.bottom, 56)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: limitToastToken)
    .task(id: limitToastToken) {
      guard limitToastToken != nil else { return }
      try? await Task.sleep(for: .seconds(2.4))
      limitToastToken = nil
    }
    .onExitCommand(perform: onCancel)
  }

  /// Lightweight, non-focusable toast shown when the viewer tries to pick a 5th
  /// stream. It never steals focus — the disabled tiles stay reachable — it just
  /// explains why nothing happened.
  private var limitToast: some View {
    HStack(spacing: 12) {
      Icon(glyph: .alertCircle, size: 26)
        .foregroundStyle(.secondary)
      Text("You can watch up to \(multiviewPaneLimit) streams at once")
        .font(.headline)
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 18)
    .background {
      if glassDisabled {
        Capsule().fill(palette.chromeOpaqueSurface)
          .overlay(Capsule().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    .accessibilityElement(children: .combine)
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text("Multiview")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .borderAll, size: 34)
        }
        Text("Choose up to \(multiviewPaneLimit) live channels to watch together.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        onStart(orderedSelection)
      } label: {
        Text(canStart ? "Start Multiview (\(selectedIDs.count))" : "Pick 2+ channels")
          .font(.headline)
          .padding(.horizontal, 12)
      }
      .disabled(!canStart)
    }
    .padding(.horizontal, AppLayout.horizontalPadding)
    .padding(.top, 48)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text("Not enough live channels")
        .font(.title2.weight(.semibold))
      Text("Multiview needs at least two channels that are live right now.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Section rail

  private func sectionRail(_ section: MultiviewChannelSection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(section.title)
        .font(.system(size: 30, weight: .bold))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, AppLayout.horizontalPadding)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 28) {
          ForEach(section.channels) { channel in
            tile(channel)
              .frame(width: cardWidth)
          }
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.vertical, 16)
      }
      .scrollClipDisabled()
    }
    .focusSection()
  }

  // MARK: Tile

  private func tile(_ channel: FollowedChannel) -> some View {
    let order = selectedIDs.firstIndex(of: channel.id)
    let isSelected = order != nil
    let isFocused = focusedID == channel.id
    let dimmed = isAtLimit && !isSelected

    return StreamChannelCard(
      channel: channel,
      isFocused: isFocused,
      layout: .grid(),
      showsGameName: true
    )
    .overlay(alignment: .topTrailing) {
      Group {
        if let order {
          selectionBadge(order: order + 1)
        } else {
          selectionPlaceholder
        }
      }
      .padding(20)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          isSelected ? selectionColor : Color.clear,
          lineWidth: 4
        )
    }
    .opacity(dimmed ? 0.4 : 1)
    .scaleEffect(isFocused ? 1.04 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.18), value: isSelected)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .focusable(true)
    .focused($focusedID, equals: channel.id)
    .focusEffectDisabled()
    .onTapGesture { toggle(channel) }
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(
      dimmed
        ? "Limit of \(multiviewPaneLimit) reached"
        : (isSelected
            ? "Selected, position \((order ?? 0) + 1). Click to remove."
            : "Click to add to multiview")
    )
  }

  /// The native tvOS selection/focus color: white on dark and OLED, black on
  /// the Light theme — never brand purple.
  private var selectionColor: Color {
    palette.isLight ? .black : .white
  }

  /// Numbered pick-order badge. A clean solid disc in the selection color with a
  /// contrasting, monospaced numeral so it reads at a glance and never feels
  /// cramped.
  private func selectionBadge(order: Int) -> some View {
    Text("\(order)")
      .font(.system(size: 26, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(palette.isLight ? Color.white : Color.black)
      .frame(width: 52, height: 52)
      .background(selectionColor, in: Circle())
      .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }

  /// Unselected (addable) indicator: a circle that exactly matches the numbered
  /// badge's size and position, so every selectable stream advertises the same
  /// tap target. A bold ring in the native selection color over a lightly
  /// frosted disc — the glass material is dialed to a low opacity so there's
  /// just a slight blur, not a heavy frost. Becomes an opaque palette disc under
  /// Reduce Transparency.
  private var selectionPlaceholder: some View {
    ZStack {
      if glassDisabled {
        Circle().fill(palette.chromeOpaqueSurface.opacity(0.85))
      } else {
        Circle().fill(.ultraThinMaterial).opacity(0.55)
        Circle().fill(selectionColor.opacity(0.08))
      }
      Circle().strokeBorder(selectionColor.opacity(0.9), lineWidth: 3)
    }
    .frame(width: 52, height: 52)
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }

  private func toggle(_ channel: FollowedChannel) {
    if let idx = selectedIDs.firstIndex(of: channel.id) {
      selectedIDs.remove(at: idx)
    } else if isAtLimit {
      limitToastToken = UUID()
    } else {
      selectedIDs.append(channel.id)
    }
  }
}
