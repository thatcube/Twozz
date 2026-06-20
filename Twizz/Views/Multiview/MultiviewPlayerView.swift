import SwiftUI

/// Plays up to four live channels at once in a focusable grid. The tvOS focus
/// engine selects one pane as "active": that pane is unmuted and highlighted,
/// every other pane runs muted. Clicking the focused pane escalates to the full
/// single-stream player; Menu exits multiview.
struct MultiviewPlayerView: View {
  let channels: [FollowedChannel]
  /// Invoked when the viewer clicks a pane to watch it full-screen (with chat,
  /// quality control, the works). The presenter tears down multiview and opens
  /// the normal `PlayerView`.
  var onEscalate: (FollowedChannel) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @State private var controller: MultiviewController
  @FocusState private var focusedPaneID: String?

  init(channels: [FollowedChannel], onEscalate: @escaping (FollowedChannel) -> Void) {
    self.channels = channels
    self.onEscalate = onEscalate
    _controller = State(initialValue: MultiviewController(channels: channels))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      grid
        .padding(20)
    }
    .onAppear {
      controller.start()
      if focusedPaneID == nil {
        focusedPaneID = controller.panes.first?.id
      }
    }
    .onChange(of: focusedPaneID) { _, newID in
      controller.setAudiblePane(newID)
    }
    .onDisappear { controller.teardown() }
    .onExitCommand { dismiss() }
  }

  // MARK: Layout

  /// Classic multiview arrangements: 1 full, 2 side-by-side, 1-big-plus-2, 2×2.
  @ViewBuilder
  private var grid: some View {
    let panes = controller.panes
    switch panes.count {
    case 0:
      EmptyView()
    case 1:
      tile(panes[0])
    case 2:
      HStack(spacing: 16) {
        tile(panes[0])
        tile(panes[1])
      }
    case 3:
      HStack(spacing: 16) {
        tile(panes[0])
        VStack(spacing: 16) {
          tile(panes[1])
          tile(panes[2])
        }
      }
    default:
      VStack(spacing: 16) {
        HStack(spacing: 16) {
          tile(panes[0])
          tile(panes[1])
        }
        HStack(spacing: 16) {
          tile(panes[2])
          tile(panes[3])
        }
      }
    }
  }

  private func tile(_ pane: MultiviewPane) -> some View {
    MultiviewPaneTile(
      pane: pane,
      isFocused: focusedPaneID == pane.id,
      palette: palette,
      onRetry: { controller.load(pane) }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .focusable()
    .focused($focusedPaneID, equals: pane.id)
    .onTapGesture { onEscalate(pane.channel) }
  }
}

/// A single video tile with focus highlight and status overlays.
private struct MultiviewPaneTile: View {
  let pane: MultiviewPane
  let isFocused: Bool
  let palette: ThemePalette
  var onRetry: () -> Void

  private var cornerRadius: CGFloat { 16 }

  var body: some View {
    ZStack {
      PreviewVideoSurface(player: pane.player, cornerRadius: cornerRadius)
        .opacity(pane.isLoading || pane.hasError ? 0 : 1)

      if pane.isLoading {
        statusOverlay {
          ProgressView()
          Text(pane.channel.displayName)
            .font(.headline)
            .foregroundStyle(.secondary)
        }
      } else if pane.hasError {
        statusOverlay {
          Text(pane.channel.displayName)
            .font(.headline)
          Text("Couldn't load — click to retry")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .onTapGesture(perform: onRetry)
      }

      infoOverlay
    }
    .background(Color.black)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(
          isFocused ? ThemePalette.brandPurple : Color.white.opacity(0.08),
          lineWidth: isFocused ? 5 : 1
        )
    }
    .scaleEffect(isFocused ? 1.02 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 8)
  }

  @ViewBuilder
  private func statusOverlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 12) { content() }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
  }

  /// Channel name plus a live dot and an audio indicator, laid over the video.
  private var infoOverlay: some View {
    VStack {
      HStack {
        Label {
          Text(pane.channel.displayName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        } icon: {
          Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())

        Spacer()

        Icon(glyph: pane.isAudible ? .volume : .volumeOff, size: 22)
          .foregroundStyle(pane.isAudible ? ThemePalette.brandPurple : .secondary)
          .padding(9)
          .background(.regularMaterial, in: Circle())
      }
      Spacer()
    }
    .padding(12)
    .opacity(pane.isLoading || pane.hasError ? 0 : 1)
  }
}

/// Container that runs the multiview flow inside a single full-screen cover:
/// channel picker first, then the live grid. Keeps the chained-presentation
/// timing issues of stacked covers out of the caller.
struct MultiviewRootView: View {
  let liveChannels: [FollowedChannel]
  /// Called when the viewer escalates a pane to full-screen single-stream.
  var onWatchFull: (FollowedChannel) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var startedChannels: [FollowedChannel]?

  var body: some View {
    Group {
      if let startedChannels {
        MultiviewPlayerView(channels: startedChannels, onEscalate: onWatchFull)
      } else {
        MultiviewSetupView(
          channels: liveChannels,
          onStart: { startedChannels = $0 },
          onCancel: { dismiss() }
        )
      }
    }
  }
}
