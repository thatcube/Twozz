import SwiftUI

/// Picks up to ``multiviewPaneLimit`` live channels to watch together, then
/// hands the ordered selection to the multiview grid.
struct MultiviewSetupView: View {
  let channels: [FollowedChannel]
  var onStart: ([FollowedChannel]) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  /// Selected channel ids, in pick order — that order drives grid placement.
  @State private var selectedIDs: [String] = []
  @FocusState private var focusedID: String?

  private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 28)]

  private var liveChannels: [FollowedChannel] { channels.filter(\.isLive) }
  private var isAtLimit: Bool { selectedIDs.count >= multiviewPaneLimit }
  private var canStart: Bool { selectedIDs.count >= 2 }

  private var orderedSelection: [FollowedChannel] {
    selectedIDs.compactMap { id in liveChannels.first { $0.id == id } }
  }

  var body: some View {
    ZStack {
      AppBackground(palette: palette).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        header

        if liveChannels.count < 2 {
          emptyState
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(liveChannels) { channel in
                tile(channel)
              }
            }
            .padding(.horizontal, AppLayout.horizontalPadding)
            .padding(.vertical, 28)
          }
        }
      }
    }
    .onExitCommand(perform: onCancel)
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text("Multiview")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .layoutGrid, size: 34)
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
      .tint(ThemePalette.brandPurple)
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

  // MARK: Tile

  private func tile(_ channel: FollowedChannel) -> some View {
    let order = selectedIDs.firstIndex(of: channel.id)
    let isSelected = order != nil
    let isFocused = focusedID == channel.id
    let dimmed = isAtLimit && !isSelected

    return Button {
      toggle(channel)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        ZStack(alignment: .topTrailing) {
          CachedAsyncImage(url: channel.thumbnailURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Rectangle().fill(Color.primary.opacity(0.12))
          }
          .aspectRatio(16.0 / 9.0, contentMode: .fill)
          .frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

          if let order {
            selectionBadge(order: order + 1)
              .padding(12)
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
              isSelected ? ThemePalette.brandPurple : Color.clear,
              lineWidth: 5
            )
        }

        Text(channel.displayName)
          .font(.headline)
          .lineLimit(1)
          .foregroundStyle(.primary)
      }
    }
    .buttonStyle(.card)
    .focused($focusedID, equals: channel.id)
    .opacity(dimmed ? 0.4 : 1)
    .scaleEffect(isFocused ? 1.04 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
  }

  private func selectionBadge(order: Int) -> some View {
    Text("\(order)")
      .font(.headline.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 40, height: 40)
      .background(ThemePalette.brandPurple, in: Circle())
      .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
  }

  private func toggle(_ channel: FollowedChannel) {
    if let idx = selectedIDs.firstIndex(of: channel.id) {
      selectedIDs.remove(at: idx)
    } else if !isAtLimit {
      selectedIDs.append(channel.id)
    }
  }
}
