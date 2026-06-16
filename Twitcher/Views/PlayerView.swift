import SwiftUI
import AVKit

/// Hosts an `AVPlayerLayer` so the video keeps its aspect ratio (letterboxed and
/// centered) inside whatever space the layout gives it — required for the
/// side-by-side video + chat layout.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen player for a live channel. Video sits on the left and the chat
/// panel docks to the right at full height (the video shrinks to make room,
/// never overlapping). We use a custom `AVPlayerLayer` surface with our own
/// overlay UI rather than the native player transport — the native controls are
/// VOD/scrubbing-oriented and unsuited to a live, side-by-side chat layout.
/// Controls auto-hide and are revealed by pressing the remote.
struct PlayerView: View {
    let channel: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredQuality") private var preferredQuality = "Auto"

    @State private var chat = ChatService()
    @State private var player = AVPlayer()
    @State private var playback: StreamPlayback?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showChat = true
    @State private var showQualityPicker = false
    @State private var showControls = false
    @State private var captionsOn = false
    @State private var hideTask: Task<Void, Never>?

    @FocusState private var focus: Focusable?
    private enum Focusable: Hashable {
        case video, quality, captions, exit, chatTab
        case qualityOption(String)
    }

    private let chatWidth: CGFloat = 460

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                videoColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showChat {
                    ChatView(
                        channel: channel,
                        messages: chat.messages,
                        isConnected: chat.isConnected,
                        onCollapse: { setChat(false) }
                    )
                    .frame(width: chatWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                } else {
                    collapsedChatTab
                        .transition(.move(edge: .trailing))
                }
            }
            .ignoresSafeArea()

            if showQualityPicker {
                qualityPicker
            }
        }
        .task {
            chat.connect(to: channel)
            await load()
            focus = .video
        }
        .onDisappear {
            hideTask?.cancel()
            player.pause()
            chat.disconnect()
        }
        .onExitCommand {
            if showQualityPicker {
                showQualityPicker = false
                focus = .video
            } else if showControls {
                hideControls()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Video + controls

    private var videoColumn: some View {
        ZStack(alignment: .top) {
            VideoSurface(player: player)
                .ignoresSafeArea()

            // Invisible full-area catcher: pressing the remote reveals controls.
            Button(action: revealControls) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .video)

            if isLoading {
                ProgressView("Loading \(channel)…")
                    .font(.title3)
            }

            if let errorMessage {
                VStack(spacing: 24) {
                    Text("Couldn't play \(channel)")
                        .font(.title2).bold()
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    Button("Back") { dismiss() }
                        .focused($focus, equals: .exit)
                }
                .padding(40)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
            } else if showControls {
                controlBar
                    .transition(.opacity)
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            Button {
                showQualityPicker = true
                focus = .qualityOption(preferredQuality)
                hideTask?.cancel()
            } label: {
                Label("Quality • \(preferredQuality)", systemImage: "gauge.with.dots.needle.67percent")
            }
            .focused($focus, equals: .quality)

            Button {
                captionsOn.toggle()
                applyCaptions()
                scheduleHide()
            } label: {
                Label(captionsOn ? "Captions On" : "Captions Off",
                      systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble")
            }
            .focused($focus, equals: .captions)

            Spacer()

            Button {
                dismiss()
            } label: {
                Label("Exit", systemImage: "xmark")
            }
            .focused($focus, equals: .exit)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
                .allowsHitTesting(false),
            alignment: .top
        )
    }

    /// Thin focusable strip shown on the right edge when chat is collapsed.
    private var collapsedChatTab: some View {
        Button {
            setChat(true)
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "chevron.left")
                Image(systemName: "bubble.left.and.bubble.right.fill")
            }
            .font(.title3)
            .frame(maxHeight: .infinity)
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .chatTab)
        .background(Color(white: 0.07).opacity(0.96))
    }

    private func setChat(_ shown: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { showChat = shown }
        focus = shown ? .video : .chatTab
    }

    // MARK: - Controls visibility

    private func revealControls() {
        guard !showControls else { scheduleHide(); return }
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        focus = .quality
        scheduleHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        focus = .video
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !showQualityPicker else { return }
                hideControls()
            }
        }
    }

    // MARK: - Quality picker

    private var qualityPicker: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Text("Quality")
                    .font(.title2).bold()
                    .padding(.bottom, 8)

                ForEach(qualityOptions, id: \.self) { option in
                    Button {
                        select(quality: option)
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if option == preferredQuality {
                                Image(systemName: "checkmark")
                            }
                        }
                        .frame(width: 360)
                    }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .qualityOption(option))
                }
            }
            .padding(40)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private var qualityOptions: [String] {
        ["Auto"] + (playback?.qualities.map(\.name) ?? [])
    }

    private func select(quality option: String) {
        preferredQuality = option
        showQualityPicker = false
        if let url = url(for: option) {
            player.replaceCurrentItem(with: makeItem(url: url))
            player.play()
        }
        focus = .quality
        scheduleHide()
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        player.appliesMediaSelectionCriteriaAutomatically = false
        do {
            let resolved = try await PlaybackService.resolve(for: channel)
            playback = resolved
            let startURL = url(for: preferredQuality) ?? resolved.master
            player.replaceCurrentItem(with: makeItem(url: startURL))
            player.play()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Resolves a quality option name to a playable URL. "Auto" (or an unknown
    /// name, e.g. a persisted quality this stream doesn't offer) uses the master
    /// playlist so AVPlayer does adaptive bitrate.
    private func url(for option: String) -> URL? {
        guard let playback else { return nil }
        if option == "Auto" { return playback.master }
        if let match = playback.qualities.first(where: { $0.name == option }) { return match.url }
        return playback.master
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        applyCaptions(to: item)
        return item
    }

    /// Applies the current captions preference to the active item.
    private func applyCaptions() {
        if let item = player.currentItem { applyCaptions(to: item) }
    }

    /// Turns the in-band/closed captions on or off for a given item. Twitch
    /// streams carry CEA-608 captions in the legible selection group; we
    /// explicitly deselect them so they default off and can be toggled.
    private func applyCaptions(to item: AVPlayerItem) {
        let wantCaptions = captionsOn
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            await MainActor.run {
                if wantCaptions, let option = group.options.first {
                    item.select(option, in: group)
                } else {
                    item.select(nil, in: group)
                }
            }
        }
    }
}
