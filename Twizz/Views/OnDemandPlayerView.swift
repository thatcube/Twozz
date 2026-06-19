import AVKit
import SwiftUI
import UIKit

/// A piece of on-demand content opened from the channel page.
enum OnDemandItem: Identifiable, Hashable {
  case clip(slug: String, title: String)
  case vod(id: String, title: String)

  var id: String {
    switch self {
    case .clip(let slug, _): return "clip:\(slug)"
    case .vod(let id, _): return "vod:\(id)"
    }
  }

  var title: String {
    switch self {
    case .clip(_, let title), .vod(_, let title): return title
    }
  }

  var kindNoun: String {
    switch self {
    case .clip: return "clip"
    case .vod: return "broadcast"
    }
  }

  /// The VOD id for broadcasts (used to fetch chat replay); nil for clips.
  var vodID: String? {
    if case .vod(let id, _) = self { return id }
    return nil
  }
}

/// Full-screen player for clips and VODs.
///
/// It hosts a native `AVPlayerViewController` so the Siri Remote gets Apple's
/// full transport UI for free — scrub/seek, skip, play-pause, and the native
/// playback-speed control — which is exactly what on-demand content wants.
///
/// VODs additionally get a Twitch-style **chat replay**: the live player's
/// `ChatView` is rendered into the player's `contentOverlayView` (above the
/// video, below the controls) as a non-interactive, auto-scrolling panel kept in
/// sync with the playback offset by `VODChatReplayService`. It reuses the same
/// global chat appearance settings as the live player. Show/hide chat and
/// playback speed live in the transport-bar menu.
struct OnDemandPlayerView: View {
  let item: OnDemandItem
  /// Login of the channel that owns this content, used to resolve the right
  /// emote/badge catalogs for chat replay. Optional; replay still works without
  /// it (global emotes/badges only).
  var channelLogin: String? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var player = AVPlayer()
  @State private var replay = VODChatReplayService()
  @State private var phase: Phase = .loading
  @State private var timeObserver: Any?
  @State private var showChat = UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool
    ?? true
  @FocusState private var backFocused: Bool

  @AppStorage("chatTextSizeValue") private var chatTextSizeValue = Double(
    ChatAppearance.defaultTextSize)
  @AppStorage("chatEmoteAuto") private var chatEmoteAuto = ChatAppearance.defaultEmoteAuto
  @AppStorage("chatEmoteSizeValue") private var chatEmoteSizeValue = Double(
    ChatAppearance.defaultEmoteSize)
  @AppStorage("chatLineHeightValue") private var chatLineHeightValue = Double(
    ChatAppearance.defaultLineHeight)
  @AppStorage("chatMessageSpacingValue") private var chatMessageSpacingValue = Double(
    ChatAppearance.defaultMessageSpacing)
  @AppStorage("chatWidthValue") private var chatWidthValue = Double(ChatAppearance.defaultWidth)
  @AppStorage("chatAnimatedEmotes") private var chatAnimatedEmotes = ChatAppearance
    .defaultAnimatedEmotes
  @AppStorage("chatFontStyle") private var chatFontStyleRaw = ChatAppearance.defaultFontStyle
    .rawValue
  @AppStorage("chatShowBadges") private var chatShowBadges = ChatAppearance.defaultShowBadges
  @AppStorage("chatLayoutMode") private var chatLayoutModeRaw = ChatLayoutMode.side.rawValue

  private enum Phase { case loading, playing, failed }

  private var isVOD: Bool { item.vodID != nil }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      switch phase {
      case .loading:
        VStack(spacing: 18) {
          ProgressView()
          Text("Loading \(item.title)…")
            .font(.title3)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      case .failed:
        VStack(spacing: 20) {
          Text("Couldn't play this \(item.kindNoun) right now.")
            .font(.title2)
          Button("Back") { dismiss() }
            .focused($backFocused)
        }
        .padding(40)
      case .playing:
        VODPlayerSurface(
          player: player,
          replay: replay,
          isVOD: isVOD,
          showChat: $showChat,
          appearance: overlayAppearance
        )
        .ignoresSafeArea()
      }
    }
    .onExitCommand { dismiss() }
    .task(id: item.id) { await start() }
    .onChange(of: phase) { _, newPhase in
      if newPhase == .failed { backFocused = true }
    }
    .onDisappear {
      removeTimeObserver()
      replay.stop()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  private var overlayAppearance: ChatOverlayAppearance {
    ChatOverlayAppearance(
      channel: channelLogin ?? "",
      textSize: chatTextSize,
      emoteSize: chatEmoteSize,
      messageSpacing: chatMessageSpacing,
      lineHeight: chatLineHeight,
      animatedEmotes: chatAnimatedEmotes,
      fontDesign: chatFontStyle.design,
      showBadges: chatShowBadges,
      layout: chatLayoutMode,
      width: chatWidth
    )
  }

  // MARK: - Chat appearance (mirrors the live player's global settings)

  private var chatTextSize: CGFloat { CGFloat(chatTextSizeValue) }
  private var chatLineHeight: CGFloat { CGFloat(chatLineHeightValue) }
  private var chatMessageSpacing: CGFloat { CGFloat(chatMessageSpacingValue) }
  private var chatWidth: CGFloat { CGFloat(chatWidthValue) }

  private var chatEmoteSize: CGFloat {
    chatEmoteAuto
      ? ChatAppearance.autoEmoteHeight(forTextSize: chatTextSize)
      : CGFloat(chatEmoteSizeValue)
  }

  private var chatLayoutMode: ChatLayoutMode {
    ChatLayoutMode(rawValue: chatLayoutModeRaw) ?? .side
  }

  private var chatFontStyle: ChatFontStyle {
    ChatFontStyle(rawValue: chatFontStyleRaw) ?? .standard
  }

  // MARK: - Playback

  private func start() async {
    phase = .loading
    do {
      let url: URL
      let headers: [String: String]
      switch item {
      case .clip(let slug, _):
        url = try await PlaybackService.clipSourceURL(slug: slug)
        headers = [:]
      case .vod(let id, _):
        url = try await PlaybackService.vodMasterURL(id: id)
        headers = PlaybackService.streamHeaders
        replay.start(vodID: id, channelLogin: channelLogin)
      }

      let asset = headers.isEmpty
        ? AVURLAsset(url: url)
        : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      let playerItem = AVPlayerItem(asset: asset)
      player.replaceCurrentItem(with: playerItem)
      player.play()
      if isVOD { installTimeObserver() }
      phase = .playing
    } catch {
      phase = .failed
    }
  }

  private func installTimeObserver() {
    removeTimeObserver()
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      replay.update(toOffset: time.seconds)
    }
  }

  private func removeTimeObserver() {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
  }
}

/// Snapshot of the global chat appearance settings, passed into the overlay.
struct ChatOverlayAppearance {
  let channel: String
  let textSize: CGFloat
  let emoteSize: CGFloat
  let messageSpacing: CGFloat
  let lineHeight: CGFloat
  let animatedEmotes: Bool
  let fontDesign: Font.Design
  let showBadges: Bool
  let layout: ChatLayoutMode
  let width: CGFloat
}

/// Hosts a native `AVPlayerViewController` (full transport controls + speed) and
/// renders the VOD chat replay into its `contentOverlayView`. The chat overlay
/// is non-interactive so the player keeps full remote focus; show/hide chat and
/// playback speed are exposed as transport-bar menu items.
struct VODPlayerSurface: UIViewControllerRepresentable {
  let player: AVPlayer
  let replay: VODChatReplayService
  let isVOD: Bool
  @Binding var showChat: Bool
  let appearance: ChatOverlayAppearance

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    controller.loadViewIfNeeded()

    context.coordinator.playerVC = controller

    if isVOD {
      let host = UIHostingController(rootView: context.coordinator.makeOverlay())
      host.view.backgroundColor = .clear
      host.view.isUserInteractionEnabled = false
      controller.addChild(host)
      if let overlay = controller.contentOverlayView {
        host.view.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(host.view)
        NSLayoutConstraint.activate([
          host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
          host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
          host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
          host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
        ])
      }
      host.didMove(toParent: controller)
      context.coordinator.chatHost = host
    }

    context.coordinator.apply()
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    context.coordinator.parent = self
    if controller.player !== player {
      controller.player = player
    }
    context.coordinator.apply()
  }

  @MainActor
  final class Coordinator {
    var parent: VODPlayerSurface
    weak var playerVC: AVPlayerViewController?
    var chatHost: UIHostingController<AnyView>?

    private let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    init(_ parent: VODPlayerSurface) {
      self.parent = parent
    }

    func makeOverlay() -> AnyView {
      AnyView(
        VODChatOverlay(
          replay: parent.replay,
          appearance: parent.appearance,
          visible: parent.showChat
        )
      )
    }

    /// Push the latest state into the live controller: overlay visibility +
    /// content, and the transport-bar menu items.
    func apply() {
      chatHost?.view.isHidden = !(parent.isVOD && parent.showChat)
      chatHost?.rootView = makeOverlay()
      refreshMenus()
    }

    private func refreshMenus() {
      guard parent.isVOD, let controller = playerVC else { return }
      controller.transportBarCustomMenuItems = [chatToggleItem(), speedMenu()]
    }

    private func chatToggleItem() -> UIMenuElement {
      let on = parent.showChat
      let action = UIAction(
        title: on ? "Hide Chat" : "Show Chat",
        image: UIImage(systemName: on ? "bubble.left.fill" : "bubble.left")
      ) { [weak self] _ in
        guard let self else { return }
        self.parent.showChat.toggle()
        self.apply()
      }
      action.state = on ? .on : .off
      return action
    }

    private func speedMenu() -> UIMenu {
      let current = parent.player.defaultRate == 0 ? 1.0 : parent.player.defaultRate
      let actions = speeds.map { speed in
        UIAction(
          title: speedTitle(speed),
          state: abs(current - speed) < 0.01 ? .on : .off
        ) { [weak self] _ in
          guard let self else { return }
          let player = self.parent.player
          player.defaultRate = speed
          if player.timeControlStatus != .paused {
            player.rate = speed
          }
          self.refreshMenus()
        }
      }
      return UIMenu(
        title: "Playback Speed",
        image: UIImage(systemName: "speedometer"),
        children: actions
      )
    }

    private func speedTitle(_ speed: Float) -> String {
      speed == 1.0 ? "Normal" : String(format: "%g×", speed)
    }
  }
}

/// The chat-replay panel rendered inside the player's content overlay. Reads
/// `replay` (which is `@Observable`) directly, so it re-renders as new messages
/// surface without the host controller pushing updates each tick.
private struct VODChatOverlay: View {
  let replay: VODChatReplayService
  let appearance: ChatOverlayAppearance
  let visible: Bool

  var body: some View {
    if visible {
      ChatView(
        channel: appearance.channel,
        messages: replay.messages,
        textSize: appearance.textSize,
        emoteSize: appearance.emoteSize,
        messageSpacing: appearance.messageSpacing,
        lineHeight: appearance.lineHeight,
        animatedEmotes: appearance.animatedEmotes,
        fontDesign: appearance.fontDesign,
        showBadges: appearance.showBadges,
        isConnected: replay.isReady,
        emoteURLs: replay.emoteURLs,
        badgeURLs: replay.badgeURLs,
        useGlassBackground: appearance.layout == .glass,
        useLighterOverlayBackground: appearance.layout != .glass
      )
      .frame(width: appearance.width)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
      .modifier(VODChatGlassStyle(enabled: appearance.layout == .glass))
      .allowsHitTesting(false)
    }
  }
}

/// Lightweight rounded "glass" container for the VOD chat overlay so the glass
/// layout mode reads similarly to the live player without depending on that
/// file's private styling.
private struct VODChatGlassStyle: ViewModifier {
  let enabled: Bool
  private let edgeInset: CGFloat = 24
  private let corner: CGFloat = 28

  func body(content: Content) -> some View {
    if enabled {
      content
        .padding(.vertical, edgeInset)
        .padding(.trailing, edgeInset)
    } else {
      content
    }
  }
}
