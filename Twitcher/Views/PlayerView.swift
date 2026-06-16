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
    @State private var streamTitle: String = ""
    @State private var hideTask: Task<Void, Never>?

    @FocusState private var focus: Focusable?
    private enum Focusable: Hashable {
        case video, quality, captions, chatToggle, errorBack
        case qualityOption(Int)
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
                        isConnected: chat.isConnected
                    )
                    .frame(width: chatWidth)
                    .frame(maxHeight: .infinity)
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
            await refreshStreamTitle()
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
                focus = .quality
                scheduleHide()
            } else if showControls {
                hideControls()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Video + controls

    private var videoColumn: some View {
        ZStack(alignment: .bottom) {
            VideoSurface(player: player)
                .ignoresSafeArea()

            // Invisible full-area catcher: pressing the remote reveals controls.
            // A plain focusable view (not a Button) avoids tvOS's full-screen
            // focus halo that made the whole video look like a giant card.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .focusable()
                .focused($focus, equals: .video)
                .onTapGesture { revealControls() }

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
                        .focused($focus, equals: .errorBack)
                }
                .padding(40)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
            } else if showControls && !showQualityPicker {
                bottomOverlay
                    .transition(.opacity)
            }
        }
    }

    private var bottomOverlay: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Text(streamTitle.isEmpty ? channel : streamTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 860, alignment: .leading)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    showQualityPicker = true
                    hideTask?.cancel()
                } label: {
                    Label("Quality", systemImage: "gauge.with.dots.needle.67percent")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .quality)

                Button {
                    captionsOn.toggle()
                    applyCaptions()
                    scheduleHide()
                } label: {
                    Label(captionsOn ? "Captions On" : "Captions Off",
                          systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .captions)

                Button {
                    showChat.toggle()
                    scheduleHide()
                } label: {
                    Label(showChat ? "Hide Chat" : "Show Chat",
                          systemImage: showChat ? "sidebar.right" : "bubble.left.and.bubble.right.fill")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .chatToggle)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 42)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 240)
                .allowsHitTesting(false),
            alignment: .bottom
        )
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

                ForEach(Array(qualityOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        selectQuality(at: index)
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
                    .focused($focus, equals: .qualityOption(index))
                }
            }
            .padding(40)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 28))
            .focusSection()
        }
        .onAppear {
            // Move focus into the picker once it's on screen; the underlying
            // control bar is hidden while the picker is open so it can't steal focus.
            let target = qualityOptions.firstIndex(of: preferredQuality) ?? 0
            focus = .qualityOption(target)
        }
    }

    private var qualityOptions: [String] {
        ["Auto"] + (playback?.qualities.map(\.name) ?? [])
    }

    private func selectQuality(at index: Int) {
        guard qualityOptions.indices.contains(index) else { return }
        let option = qualityOptions[index]
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
        streamTitle = ""
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

    private func refreshStreamTitle() async {
        if let title = await PlaybackService.streamTitle(for: channel), !title.isEmpty {
            streamTitle = title
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
