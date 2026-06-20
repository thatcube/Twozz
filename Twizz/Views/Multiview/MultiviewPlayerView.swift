import SwiftUI

/// Plays up to four live channels at once. The tvOS focus engine selects one
/// pane as "active": that pane is unmuted and highlighted while every other pane
/// runs muted. Two arrangements are offered — a symmetric **grid** and a
/// **spotlight** (one large primary pane plus a thumbnail filmstrip) — toggled
/// with the remote's Play/Pause button or the on-screen control. Panes can be
/// added or removed live, any pane can be promoted to the spotlight primary via
/// its long-press menu, and clicking a pane escalates it to the full
/// single-stream player. Menu exits multiview.
struct MultiviewPlayerView: View {
  let channels: [FollowedChannel]
  /// All currently-live channels, used to offer additions while watching.
  let availableChannels: [FollowedChannel]
  /// Invoked when the viewer clicks a pane to watch it full-screen (with chat,
  /// quality control, the works). The presenter tears down multiview and opens
  /// the normal `PlayerView`. The second argument is the current roster so the
  /// presenter can restore this multiview when the single player is dismissed.
  var onEscalate: (FollowedChannel, [FollowedChannel]) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @State private var controller: MultiviewController
  @FocusState private var focus: MultiviewFocusTarget?
  /// Drives the auto-hiding focused-pane metadata: true right after any focus
  /// change or remote interaction, then fades out so the video wall stays clean.
  @State private var chromeVisible = true
  @State private var chromeHideTask: Task<Void, Never>?
  @State private var showingAddPicker = false
  /// The reveal-on-up controls HUD. The wall is full-screen by default; pressing
  /// up from the top pane row (a focus move the engine can't satisfy) surfaces
  /// the control bar and hands focus to it. Pressing down / Menu hides it again.
  @State private var showingControls = false
  /// Last pane that held focus, so dismissing the HUD restores focus to it.
  @State private var lastPaneID: String?
  /// A brief on-appear coach hint explaining the hidden controls.
  @State private var hintVisible = true
  @State private var hintHideTask: Task<Void, Never>?
  /// Timestamp of the last unconsumed up-press, used to require a deliberate
  /// double-up to reveal the HUD so ordinary navigation doesn't trigger it.
  @State private var lastUpAt: Date?

  init(
    channels: [FollowedChannel],
    availableChannels: [FollowedChannel],
    onEscalate: @escaping (FollowedChannel, [FollowedChannel]) -> Void
  ) {
    self.channels = channels
    self.availableChannels = availableChannels
    self.onEscalate = onEscalate
    _controller = State(initialValue: MultiviewController(channels: channels))
  }

  private var focusedPaneID: String? {
    if case let .pane(id) = focus { return id }
    return nil
  }

  private var addableChannels: [FollowedChannel] {
    let present = Set(controller.panes.map(\.id))
    return availableChannels.filter { $0.isLive && !present.contains($0.id) }
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.ignoresSafeArea()

      // The video wall fills the entire screen edge-to-edge — no outer margins.
      Group {
        switch controller.layout {
        case .grid: gridLayout
        case .spotlight: spotlightLayout
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()

      // While the HUD is open, dim the wall a touch for contrast/modality.
      if showingControls {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      // Top layer: either the reveal HUD (focusable) or the coach hint. Both
      // float over the wall so the streams keep the full width and height.
      VStack(spacing: 0) {
        if showingControls {
          controlsBar
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if hintVisible {
          revealHint
            .padding(.top, 20)
            .transition(.opacity)
        }
        Spacer(minLength: 0)
      }
    }
    .onMoveCommand { direction in
      switch direction {
      case .up where !showingControls:
        // Require two up-presses in quick succession so simply navigating to
        // the top row doesn't pop the HUD by accident.
        let now = Date()
        if let last = lastUpAt, now.timeIntervalSince(last) < 0.7 {
          lastUpAt = nil
          revealControls()
        } else {
          lastUpAt = now
        }
      case .down where showingControls:
        hideControls()
      default:
        lastUpAt = nil
      }
    }
    .onAppear {
      controller.start()
      if focus == nil {
        focus = controller.panes.first.map { .pane($0.id) }
      }
      bumpChrome()
      showHintBriefly()
    }
    .onChange(of: focus) { _, newValue in
      if case let .pane(id) = newValue {
        lastPaneID = id
        controller.setAudiblePane(id)
        // If the focus engine moved back down into a pane, retire the HUD.
        if showingControls {
          withAnimation(.easeOut(duration: 0.25)) { showingControls = false }
        }
      }
      bumpChrome()
    }
    .onPlayPauseCommand {
      controller.toggleLayout()
      bumpChrome()
      showHintBriefly()
    }
    .onDisappear {
      chromeHideTask?.cancel()
      hintHideTask?.cancel()
      controller.teardown()
    }
    .onExitCommand {
      if showingControls {
        hideControls()
      } else {
        dismiss()
      }
    }
    .fullScreenCover(isPresented: $showingAddPicker) {
      MultiviewAddView(
        channels: addableChannels,
        onPick: { add($0) },
        onCancel: { showingAddPicker = false }
      )
    }
  }

  // MARK: Controls

  /// A slim, non-focusable coach mark shown briefly on appear so the hidden
  /// controls are discoverable. Styled as a standard tvOS material pill.
  private var revealHint: some View {
    HStack(spacing: 10) {
      Icon(glyph: .selector, size: 18)
      Text("Press Up twice for controls")
        .font(.callout.weight(.medium))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 20)
    .padding(.vertical, 11)
    .background(
      Capsule().fill(glassDisabled ? AnyShapeStyle(Color.black.opacity(0.72))
                                   : AnyShapeStyle(.regularMaterial))
    )
  }

  private var controlsBar: some View {
    // A compact, centered pill of native tvOS buttons — the system supplies the
    // standard focus capsule/highlight, so it matches buttons elsewhere.
    HStack(spacing: 22) {
      Button {
        controller.toggleLayout()
        bumpChrome()
      } label: {
        Label {
          Text(controller.layout == .grid ? "Spotlight" : "Grid")
        } icon: {
          Icon(glyph: controller.layout == .grid ? .layoutBottombar : .layoutGrid, size: 22)
        }
        .font(.headline)
      }
      .focused($focus, equals: .layoutButton)

      if controller.canAddPane && !addableChannels.isEmpty {
        Button {
          showingAddPicker = true
        } label: {
          Label {
            Text("Add")
          } icon: {
            Icon(glyph: .plus, size: 22)
          }
          .font(.headline)
        }
        .focused($focus, equals: .addButton)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 14)
    .background(
      Capsule().fill(glassDisabled ? AnyShapeStyle(Color.black.opacity(0.72))
                                   : AnyShapeStyle(.regularMaterial))
    )
  }

  // MARK: Grid layout

  @ViewBuilder
  private var gridLayout: some View {
    let panes = controller.panes
    switch panes.count {
    case 0:
      EmptyView()
    case 1:
      paneView(panes[0], style: .full)
    case 2:
      HStack(spacing: 16) {
        paneView(panes[0], style: .full)
        paneView(panes[1], style: .full)
      }
    case 3:
      HStack(spacing: 16) {
        paneView(panes[0], style: .full)
        VStack(spacing: 16) {
          paneView(panes[1], style: .full)
          paneView(panes[2], style: .full)
        }
      }
    default:
      VStack(spacing: 16) {
        HStack(spacing: 16) {
          paneView(panes[0], style: .full)
          paneView(panes[1], style: .full)
        }
        HStack(spacing: 16) {
          paneView(panes[2], style: .full)
          paneView(panes[3], style: .full)
        }
      }
    }
  }

  // MARK: Spotlight layout

  @ViewBuilder
  private var spotlightLayout: some View {
    let primary = controller.primaryPane
    let others = controller.panes.filter { $0.id != primary?.id }
    VStack(spacing: 16) {
      if let primary {
        paneView(primary, style: .full)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !others.isEmpty {
        HStack(spacing: 16) {
          ForEach(others) { pane in
            paneView(pane, style: .compact)
              .frame(width: 300, height: 169)
          }
          Spacer(minLength: 0)
        }
        .frame(height: 169)
      }
    }
  }

  // MARK: Pane

  private func paneView(_ pane: MultiviewPane, style: MultiviewPaneTile.Style) -> some View {
    MultiviewPaneTile(
      pane: pane,
      isFocused: focusedPaneID == pane.id,
      isPrimary: controller.layout == .spotlight && controller.primaryPane?.id == pane.id,
      showsMetadata: chromeVisible && focusedPaneID == pane.id,
      style: style,
      palette: palette,
      glassDisabled: glassDisabled,
      onRetry: { controller.load(pane) }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .focusable()
    .focused($focus, equals: .pane(pane.id))
    .onTapGesture { escalate(pane) }
    .contextMenu { paneMenu(pane) }
  }

  @ViewBuilder
  private func paneMenu(_ pane: MultiviewPane) -> some View {
    Button {
      escalate(pane)
    } label: {
      Label {
        Text("Watch Stream")
      } icon: {
        Icon(glyph: .arrowsMaximize)
      }
    }

    if controller.layout == .grid {
      Button {
        controller.makePrimary(pane.id)
        controller.layout = .spotlight
        bumpChrome()
      } label: {
        Label { Text("Spotlight") } icon: { Icon(glyph: .maximize) }
      }
    } else if controller.primaryPane?.id != pane.id {
      Button {
        controller.makePrimary(pane.id)
        bumpChrome()
      } label: {
        Label { Text("Make Primary") } icon: { Icon(glyph: .maximize) }
      }
    }

    if controller.panes.count > 1 {
      Button(role: .destructive) {
        remove(pane)
      } label: {
        Label { Text("Remove") } icon: { Icon(glyph: .trash) }
      }
    }

    if controller.canAddPane && !addableChannels.isEmpty {
      Button {
        showingAddPicker = true
      } label: {
        Label { Text("Add Channel") } icon: { Icon(glyph: .plus) }
      }
    }
  }

  // MARK: Actions

  /// Escalates a pane to the full single-stream player, handing the presenter
  /// the current roster so it can restore this exact multiview on return.
  private func escalate(_ pane: MultiviewPane) {
    onEscalate(pane.channel, controller.panes.map(\.channel))
  }

  private func add(_ channel: FollowedChannel) {
    if let id = controller.addPane(channel) {
      focus = .pane(id)
    }
    showingAddPicker = false
  }

  private func remove(_ pane: MultiviewPane) {
    let wasFocused = focusedPaneID == pane.id
    controller.removePane(pane.id)
    if wasFocused {
      focus = controller.panes.first.map { .pane($0.id) }
    }
    bumpChrome()
  }

  private func bumpChrome() {
    chromeVisible = true
    chromeHideTask?.cancel()
    chromeHideTask = Task {
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.4)) {
        chromeVisible = false
      }
    }
  }

  private func revealControls() {
    hintHideTask?.cancel()
    withAnimation(.easeOut(duration: 0.25)) {
      hintVisible = false
      showingControls = true
    }
    focus = .layoutButton
  }

  private func hideControls() {
    withAnimation(.easeOut(duration: 0.25)) { showingControls = false }
    focus = (lastPaneID.map { .pane($0) }) ?? controller.panes.first.map { .pane($0.id) }
  }

  private func showHintBriefly() {
    hintVisible = true
    hintHideTask?.cancel()
    hintHideTask = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.5)) { hintVisible = false }
    }
  }
}

/// Focus targets in the multiview screen: each pane plus the two control chips.
private enum MultiviewFocusTarget: Hashable {
  case pane(String)
  case layoutButton
  case addButton
}

/// A single video tile with focus highlight, status overlays, an auto-hiding
/// focused metadata pill, and a prominent audio cue on the audible pane.
private struct MultiviewPaneTile: View {
  enum Style {
    /// A primary / grid quadrant.
    case full
    /// A spotlight filmstrip thumbnail.
    case compact
  }

  let pane: MultiviewPane
  let isFocused: Bool
  let isPrimary: Bool
  let showsMetadata: Bool
  let style: Style
  let palette: ThemePalette
  let glassDisabled: Bool
  var onRetry: () -> Void

  private var cornerRadius: CGFloat { style == .compact ? 12 : 16 }
  private var focusScale: CGFloat { style == .compact ? 1.06 : 1.02 }

  var body: some View {
    ZStack {
      PreviewVideoSurface(player: pane.player, cornerRadius: cornerRadius)
        .opacity(pane.isLoading || pane.hasError ? 0 : 1)

      if pane.isLoading {
        statusOverlay {
          ProgressView()
          if style == .full {
            Text(pane.channel.displayName)
              .font(.headline)
              .foregroundStyle(.secondary)
          }
        }
      } else if pane.hasError {
        statusOverlay {
          Text(pane.channel.displayName)
            .font(style == .compact ? .subheadline : .headline)
            .foregroundStyle(.white)
          if style == .full {
            Text("Couldn't load — click to retry")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .onTapGesture(perform: onRetry)
      }

      overlays
    }
    .background(Color.black)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    }
    .scaleEffect(isFocused ? focusScale : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.2), value: pane.isAudible)
    .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 8)
  }

  private var borderColor: Color {
    // The multiview wall is always a black video surface, so the native tvOS
    // focus treatment here is a white border (as on any dark screen). The
    // audible-but-unfocused pane keeps a lighter white hairline as a quiet cue.
    if isFocused { return .white }
    if pane.isAudible { return Color.white.opacity(0.5) }
    return Color.white.opacity(0.12)
  }

  private var borderWidth: CGFloat {
    if isFocused { return style == .compact ? 4 : 5 }
    if pane.isAudible { return 3 }
    return 1
  }

  @ViewBuilder
  private func statusOverlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 12) { content() }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
  }

  /// Auto-hiding metadata (focused pane only) plus the persistent audio cue.
  private var overlays: some View {
    ZStack(alignment: .topTrailing) {
      // Audio cue: a bold, always-on badge on whichever pane owns sound, so the
      // active channel is obvious even after the metadata fades.
      if pane.isAudible {
        audioCue
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }

      if showsMetadata {
        metadataPill
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.opacity)
      }
    }
    .opacity(pane.isLoading || pane.hasError ? 0 : 1)
  }

  private var audioCue: some View {
    HStack(spacing: 6) {
      Icon(glyph: .volume, size: style == .compact ? 18 : 22)
      if style == .full {
        Text("Audio")
          .font(.subheadline.weight(.semibold))
      }
    }
    .foregroundStyle(.black)
    .padding(.horizontal, style == .compact ? 9 : 12)
    .padding(.vertical, style == .compact ? 7 : 8)
    .background(Color.white, in: Capsule())
    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
  }

  /// Focused-pane metadata: name, game, and the shared live/viewer badge. Sits
  /// over the video on a dark scrim, so white content stays legible in every
  /// theme and with Reduce Transparency on (the scrim is opaque, not theme-tinted).
  private var metadataPill: some View {
    VStack(alignment: .leading, spacing: style == .compact ? 2 : 4) {
      Text(pane.channel.displayName)
        .font(style == .compact ? .subheadline.weight(.semibold) : .headline)
        .foregroundStyle(.white)
        .lineLimit(1)

      if style == .full, !pane.channel.gameName.isEmpty {
        Text(pane.channel.gameName)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
          .lineLimit(1)
      }

      LiveBadge(
        isLive: pane.channel.isLive,
        viewerCount: pane.channel.viewerCount,
        prominent: style == .full
      )
    }
    .padding(.horizontal, style == .compact ? 10 : 14)
    .padding(.vertical, style == .compact ? 7 : 10)
    .background(
      glassDisabled
        ? AnyShapeStyle(Color.black.opacity(0.62))
        : AnyShapeStyle(.regularMaterial),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }
}

/// Live channel picker presented from inside multiview to add another pane.
/// Reuses ``StreamChannelCard`` so the add flow matches the setup screen.
private struct MultiviewAddView: View {
  let channels: [FollowedChannel]
  var onPick: (FollowedChannel) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  @FocusState private var focusedID: String?

  private let columns = [GridItem(.adaptive(minimum: 360, maximum: 480), spacing: 28)]

  var body: some View {
    ZStack {
      AppBackground(palette: palette).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Label {
          Text("Add a channel")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .plus, size: 34)
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 48)

        if channels.isEmpty {
          Text("No other live channels to add.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(channels) { channel in
                StreamChannelCard(
                  channel: channel,
                  isFocused: focusedID == channel.id,
                  layout: .grid(),
                  showsGameName: true
                )
                .scaleEffect(focusedID == channel.id ? 1.04 : 1)
                .animation(.easeOut(duration: 0.18), value: focusedID == channel.id)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .focusable(true)
                .focused($focusedID, equals: channel.id)
                .focusEffectDisabled()
                .onTapGesture { onPick(channel) }
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
}

/// Container that runs the multiview flow inside a single full-screen cover:
/// channel picker first, then the live grid. Keeps the chained-presentation
/// timing issues of stacked covers out of the caller.
struct MultiviewRootView: View {
  let liveChannels: [FollowedChannel]
  /// When non-nil, multiview opens straight into the video wall with this
  /// roster, skipping the setup picker — used to restore a session after the
  /// viewer escalated a pane to full-screen and pressed Back.
  var initialChannels: [FollowedChannel]? = nil
  /// Called when the viewer escalates a pane to full-screen single-stream. The
  /// second argument is the current roster, so the caller can restore it later.
  var onWatchFull: (FollowedChannel, [FollowedChannel]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var startedChannels: [FollowedChannel]?

  var body: some View {
    Group {
      if let startedChannels {
        MultiviewPlayerView(
          channels: startedChannels,
          availableChannels: liveChannels,
          onEscalate: onWatchFull
        )
      } else {
        MultiviewSetupView(
          channels: liveChannels,
          onStart: { startedChannels = $0 },
          onCancel: { dismiss() }
        )
      }
    }
    .onAppear {
      if startedChannels == nil, let initialChannels, !initialChannels.isEmpty {
        startedChannels = initialChannels
      }
    }
  }
}
