import SwiftUI
import AVKit
import UIKit

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twitcher UI while preserving Apple media rendering paths
/// (including subtitle/caption rendering) better than raw AVPlayerLayer.
struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        // Keep output mode stable while toggling in-app layouts (chat on/off).
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.appliesPreferredDisplayCriteriaAutomatically = false
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
    @State private var showCaptionsPicker = false
    @State private var showControls = false
    @State private var captionsOn = UIAccessibility.isClosedCaptioningEnabled
    @State private var captionGroup: AVMediaSelectionGroup?
    @State private var captionOptions: [AVMediaSelectionOption] = []
    @State private var captionSelectionKey: String?
    @State private var streamTitle: String = ""
    @State private var channelDisplayName: String = ""
    @State private var channelAvatarURL: URL?
    @State private var chatDraft: String = ""
    @State private var hideTask: Task<Void, Never>?
    @State private var focusRecoveryTask: Task<Void, Never>?
    @State private var latencyTask: Task<Void, Never>?
    @State private var wallClockLatencySeconds: Double?
    @State private var liveEdgeLatencySeconds: Double?
    @State private var isPlaybackActive = false
    @State private var didRequestPlayback = false
    @State private var lastHardCatchUpJumpAt = Date.distantPast
    @State private var lastWallClockCatchUpAt = Date.distantPast
    @State private var edgeLatencyLowConfidenceStreak = 0
    @State private var wallClockHighLatencyStreak = 0
    @State private var wallClockLowConfidenceStreak = 0
    @State private var lastPlaybackDateSample: Date?
    @State private var lastPlaybackTimeSampleSeconds: Double?
    @State private var lastControlFocus: Focusable = .quality

    private let controlsAutoHideSeconds: Double = 10
    private let targetLiveEdgeSeconds: Double = 3.5
    private let softCatchUpThresholdSeconds: Double = 8
    private let hardCatchUpThresholdSeconds: Double = 14
    private let hardCatchUpCooldownSeconds: Double = 20
    private let maxCatchUpRate: Float = 1.04
    private let edgeLatencyUnavailableEpsilonSeconds: Double = 0.2
    private let edgeLatencyUnavailableSamples = 4
    private let wallClockSoftCatchUpThresholdSeconds: Double = 12
    private let wallClockHardCatchUpThresholdSeconds: Double = 16
    private let wallClockHardCatchUpRequiredSamples = 10
    private let wallClockHardCatchUpCooldownSeconds: Double = 90
    private let targetWallClockSeconds: Double = 6.5
    private let wallClockUnavailableSamples = 4
    private let wallClockStaleDateDeltaEpsilonSeconds: Double = 0.08
    private let wallClockStalePlaybackAdvanceThresholdSeconds: Double = 0.6

    @FocusState private var focus: Focusable?
    private enum Focusable: Hashable {
        case video, streamInfo, quality, captions, chatToggle, chatInput, errorBack
        case qualityOption(Int)
        case captionsOption(Int)
    }

    private let chatWidth: CGFloat = 460

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                videoColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showChat {
                    chatPane
                        .transition(.move(edge: .trailing))
                }
            }
            .ignoresSafeArea()

            if showQualityPicker {
                qualityPicker
            }

            if showCaptionsPicker {
                captionsPicker
            }
        }
        .task {
            configurePlayerForLive()
            chat.connect(to: channel)
            async let metadataTask: Void = refreshChannelMetadata()
            await load()
            _ = await metadataTask
            focus = .video
        }
        .onAppear {
            setIdleTimer(disabled: true)
        }
        .onDisappear {
            hideTask?.cancel()
            focusRecoveryTask?.cancel()
            stopLatencyMonitor()
            player.pause()
            chat.disconnect()
            setIdleTimer(disabled: false)
        }
        .onExitCommand {
            if showQualityPicker {
                showQualityPicker = false
                focus = .quality
                scheduleHide()
            } else if showCaptionsPicker {
                showCaptionsPicker = false
                focus = .captions
                scheduleHide()
            } else if showControls {
                hideControls()
            } else {
                dismiss()
            }
        }
        .onMoveCommand { direction in
            guard !showQualityPicker, !showCaptionsPicker else { return }

            if !showControls {
                // Directional movement should immediately surface controls and
                // land on chat toggle so moving off chat feels instant.
                revealControls(preferredFocus: .chatToggle)
            } else {
                scheduleHide()
            }
        }
        .onChange(of: focus) { _, newFocus in
            // Keep control navigation deterministic: if tvOS drops focus to nil
            // while controls are visible, immediately restore last valid control.
            guard showControls, !showQualityPicker, !showCaptionsPicker else { return }

            if let newFocus, isControlFocus(newFocus) {
                focusRecoveryTask?.cancel()
                lastControlFocus = newFocus
                scheduleHide()
            }
        }
    }

    // MARK: - Video + controls

    private var videoColumn: some View {
        ZStack(alignment: .bottom) {
            VideoSurface(player: player)
                .ignoresSafeArea()

            if showControls, !showQualityPicker, !showCaptionsPicker, !isLoading, errorMessage == nil {
                VStack {
                    HStack {
                        latencyBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 36)
                .padding(.leading, 40)
            }

            // Only expose the video focus target while controls are hidden.
            // Otherwise, left-edge movement from the control cluster can escape
            // into this invisible target and appear as lost focus.
            if !showControls && !showQualityPicker {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focus, equals: .video)
                    .onTapGesture { revealControls(preferredFocus: .quality) }
            }

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
            }
        }
    }

    private var bottomOverlay: some View {
        HStack(alignment: .top, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    scheduleHide()
                } label: {
                    Group {
                        if let channelAvatarURL {
                            AsyncImage(url: channelAvatarURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                ZStack {
                                    Circle().fill(.white.opacity(0.16))
                                    Image(systemName: "person.crop.circle.fill")
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        } else {
                            ZStack {
                                Circle().fill(.white.opacity(0.16))
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                }
                .twitcherControlButtonStyle()
                .focused($focus, equals: .streamInfo)
                .onMoveCommand { direction in
                    switch direction {
                    case .right:
                        focus = .quality
                    case .left:
                        focus = .streamInfo
                    default:
                        break
                    }
                }

                Text(streamTitle.isEmpty ? channelDisplayName : streamTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 18)

            HStack(spacing: 14) {
                Button {
                    showQualityPicker = true
                    showCaptionsPicker = false
                    hideTask?.cancel()
                } label: {
                    Label("Quality", systemImage: "gauge.with.dots.needle.67percent")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .quality)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        focus = .streamInfo
                    case .right:
                        focus = .captions
                    default:
                        break
                    }
                }

                Button {
                    showQualityPicker = false
                    prepareCaptionsPicker()
                } label: {
                    Label(captionsOn ? "Captions On" : "Captions Off",
                          systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .captions)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        focus = .quality
                    case .right:
                        focus = .chatToggle
                    default:
                        break
                    }
                }

                Button {
                    showChat.toggle()
                    if !showChat, focus == .chatInput {
                        focus = .chatToggle
                    }
                    scheduleHide()
                } label: {
                    Label(showChat ? "Hide Chat" : "Show Chat",
                          systemImage: showChat ? "sidebar.right" : "bubble.left.and.bubble.right.fill")
                        .labelStyle(.iconOnly)
                }
                .focused($focus, equals: .chatToggle)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        focus = .captions
                    case .right:
                        if showChat {
                            focus = .chatInput
                        }
                    default:
                        break
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .twitcherControlButtonStyle()
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 48)
        .padding(.top, 12)
        .padding(.bottom, 42)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.72), location: 0.56),
                    .init(color: .black.opacity(1.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    private var latencyBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(latencyColor)
                .frame(width: 8, height: 8)

            Text(latencyLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            if wallClockLatencySeconds != nil {
                if let edge = liveEdgeLatencySeconds {
                    Text("(edge \(formatLatencySeconds(edge)))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Text("(edge n/a)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: Capsule())
    }

    // MARK: - Controls visibility

    private func revealControls(preferredFocus: Focusable) {
        focusRecoveryTask?.cancel()
        if !showControls {
            showControls = true
        }
        if isControlFocus(preferredFocus) {
            lastControlFocus = preferredFocus
        }
        focus = preferredFocus
        scheduleHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        focusRecoveryTask?.cancel()
        showControls = false
        focus = .video
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(controlsAutoHideSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !showQualityPicker else { return }
                guard !showCaptionsPicker else { return }
                hideControls()
            }
        }
    }

    private func isControlFocus(_ focus: Focusable) -> Bool {
        switch focus {
        case .streamInfo, .quality, .captions, .chatToggle, .chatInput:
            return true
        default:
            return false
        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            ChatView(
                channel: channel,
                messages: chat.messages,
                isConnected: chat.isConnected,
                emoteURLs: chat.emoteURLs,
                badgeURLs: chat.badgeURLs
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            chatComposerBar
        }
        .frame(width: chatWidth)
        .frame(maxHeight: .infinity)
    }

    private var chatComposerBar: some View {
        HStack(spacing: 10) {
            TextField("Send a message", text: $chatDraft)
                .textFieldStyle(.plain)
                .focused($focus, equals: .chatInput)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        revealControls(preferredFocus: .chatToggle)
                    case .right:
                        focus = .chatInput
                    default:
                        break
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.07).opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(height: 1)
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

    private var captionsPicker: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Text("Captions")
                    .font(.title2).bold()
                    .padding(.bottom, 8)

                Button {
                    selectCaptionOption(at: 0)
                } label: {
                    HStack {
                        Text("Off")
                        Spacer()
                        if !captionsOn {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(width: 460)
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .captionsOption(0))

                if captionOptions.isEmpty {
                    Text("No caption tracks available right now.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ForEach(Array(captionOptions.enumerated()), id: \.offset) { index, option in
                        Button {
                            selectCaptionOption(at: index + 1)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                if captionsOn, captionSelectionKey == captionKey(option) {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(width: 460)
                        }
                        .buttonStyle(.bordered)
                        .focused($focus, equals: .captionsOption(index + 1))
                    }
                }
            }
            .padding(40)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 28))
            .focusSection()
        }
        .onAppear {
            let selectedIndex: Int
            if captionsOn,
               let selected = captionSelectionKey,
               let optionIndex = captionOptions.firstIndex(where: { captionKey($0) == selected }) {
                selectedIndex = optionIndex + 1
            } else {
                selectedIndex = 0
            }
            focus = .captionsOption(selectedIndex)
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
        applyQualityPreference(option)
        focus = .quality
        scheduleHide()
    }

    private func prepareCaptionsPicker() {
        hideTask?.cancel()

        Task {
            let item = player.currentItem
            let group = try? await item?.asset.loadMediaSelectionGroup(for: .legible)
            await MainActor.run {
                captionGroup = group
                captionOptions = group?.options ?? []
                showCaptionsPicker = true
            }
        }
    }

    private func selectCaptionOption(at index: Int) {
        guard index == 0 || captionOptions.indices.contains(index - 1) else { return }

        if index == 0 {
            captionsOn = false
            captionSelectionKey = nil
        } else {
            let option = captionOptions[index - 1]
            captionsOn = true
            captionSelectionKey = captionKey(option)
        }

        applyCaptions()
        showCaptionsPicker = false
        focus = .captions
        scheduleHide()
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        streamTitle = ""
        player.appliesMediaSelectionCriteriaAutomatically = true
        do {
            let resolved = try await PlaybackService.resolve(for: channel)
            playback = resolved
            player.replaceCurrentItem(with: makeItem(url: resolved.master))
            applyQualityPreference(preferredQuality)
            startPlayback()
            startLatencyMonitor()
            isLoading = false
        } catch {
            stopLatencyMonitor()
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Keeps the player on the master playlist for video qualities so caption
    /// tracks remain discoverable. We bias ABR with preferredPeakBitRate.
    private func applyQualityPreference(_ option: String) {
        guard let playback else { return }

        if option == "Auto" {
            switchToMasterItemIfNeeded(playback.master)
            player.currentItem?.preferredPeakBitRate = 0
            return
        }

        guard let match = playback.qualities.first(where: { $0.name == option }) else {
            switchToMasterItemIfNeeded(playback.master)
            player.currentItem?.preferredPeakBitRate = 0
            return
        }

        if match.isAudioOnly {
            player.replaceCurrentItem(with: makeItem(url: match.url))
            player.currentItem?.preferredPeakBitRate = 0
            startPlayback()
            return
        }

        switchToMasterItemIfNeeded(playback.master)
        let targetBitrate = match.bitrate > 0 ? Double(match.bitrate) * 1.08 : 0
        player.currentItem?.preferredPeakBitRate = targetBitrate
    }

    private func switchToMasterItemIfNeeded(_ masterURL: URL) {
        guard let asset = player.currentItem?.asset as? AVURLAsset else {
            player.replaceCurrentItem(with: makeItem(url: masterURL))
            startPlayback()
            return
        }

        guard asset.url != masterURL else { return }
        player.replaceCurrentItem(with: makeItem(url: masterURL))
        startPlayback()
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        applyCaptions(to: item, retries: 12)
        return item
    }

    private var measuredLatencySeconds: Double? {
        liveEdgeLatencySeconds ?? wallClockLatencySeconds
    }

    private var latencyColor: Color {
        guard let seconds = measuredLatencySeconds else { return .gray }
        if seconds <= 8 { return .green }
        if seconds <= 15 { return .yellow }
        return .orange
    }

    private var latencyLabel: String {
        if !isPlaybackActive {
            return "Latency: waiting for playback"
        }
        if let liveEdgeLatencySeconds {
            return "Live latency \(formatLatencySeconds(liveEdgeLatencySeconds))"
        }
        if let wallClockLatencySeconds {
            return "Estimated latency \(formatLatencySeconds(wallClockLatencySeconds))"
        }
        return "Latency unavailable"
    }

    private func formatLatencySeconds(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        if clamped < 10 {
            let tenths = (clamped * 10).rounded() / 10
            return "\(tenths)s"
        }
        return "\(Int(clamped.rounded()))s"
    }

    private func configurePlayerForLive() {
        // Prefer reliable startup; latency is corrected by explicit catch-up logic.
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func startPlayback() {
        didRequestPlayback = true
        player.playImmediately(atRate: 1.0)
    }

    private func startLatencyMonitor() {
        stopLatencyMonitor()
        latencyTask = Task {
            while !Task.isCancelled {
                await MainActor.run {
                    updateLatencyMetrics()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopLatencyMonitor() {
        latencyTask?.cancel()
        latencyTask = nil
        wallClockLatencySeconds = nil
        liveEdgeLatencySeconds = nil
        isPlaybackActive = false
        didRequestPlayback = false
        edgeLatencyLowConfidenceStreak = 0
        wallClockHighLatencyStreak = 0
        wallClockLowConfidenceStreak = 0
        lastPlaybackDateSample = nil
        lastPlaybackTimeSampleSeconds = nil
    }

    private func updateLatencyMetrics() {
        guard let item = player.currentItem else {
            wallClockLatencySeconds = nil
            liveEdgeLatencySeconds = nil
            isPlaybackActive = false
            wallClockLowConfidenceStreak = 0
            lastPlaybackDateSample = nil
            lastPlaybackTimeSampleSeconds = nil
            return
        }

        let status = player.timeControlStatus
        let hasSeekableRange = item.seekableTimeRanges.last?.timeRangeValue != nil
        let currentSeconds = CMTimeGetSeconds(item.currentTime())
        let hasAdvancedTime = currentSeconds.isFinite && currentSeconds > 0

        // Treat waiting/buffering as active once playback has been requested.
        isPlaybackActive = status == .playing
            || (didRequestPlayback && status == .waitingToPlayAtSpecifiedRate)
            || hasSeekableRange
            || hasAdvancedTime

        if !isPlaybackActive {
            wallClockLatencySeconds = nil
            liveEdgeLatencySeconds = nil
        }

        if let playbackDate = item.currentDate() {
            let wallClock = Date().timeIntervalSince(playbackDate)
            let playbackSeconds = CMTimeGetSeconds(item.currentTime())

            if let lastDate = lastPlaybackDateSample,
               let lastPlaybackSeconds = lastPlaybackTimeSampleSeconds,
               playbackSeconds.isFinite,
               lastPlaybackSeconds.isFinite {
                let playbackAdvance = playbackSeconds - lastPlaybackSeconds
                let dateAdvance = playbackDate.timeIntervalSince(lastDate)

                if playbackAdvance >= wallClockStalePlaybackAdvanceThresholdSeconds,
                   abs(dateAdvance) <= wallClockStaleDateDeltaEpsilonSeconds {
                    wallClockLowConfidenceStreak += 1
                } else if wallClockLowConfidenceStreak > 0 {
                    wallClockLowConfidenceStreak -= 1
                }
            }

            lastPlaybackDateSample = playbackDate
            if playbackSeconds.isFinite {
                lastPlaybackTimeSampleSeconds = playbackSeconds
            }

            let hasValidWallClock = wallClock.isFinite && wallClock >= 0
            let hasReliableWallClock = hasValidWallClock
                && wallClockLowConfidenceStreak < wallClockUnavailableSamples

            if hasReliableWallClock {
                wallClockLatencySeconds = wallClock
            } else if !hasValidWallClock {
                wallClockLatencySeconds = nil
            } else {
                // Wall-clock telemetry appears stale. Keep the last reliable
                // value instead of counting up forever.
            }
        } else {
            wallClockLatencySeconds = nil
            wallClockLowConfidenceStreak = 0
            lastPlaybackDateSample = nil
            lastPlaybackTimeSampleSeconds = nil
        }

        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let liveEdge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let current = CMTimeGetSeconds(item.currentTime())
            if liveEdge.isFinite, current.isFinite, liveEdge > 0 {
                let liveEdgeLatencyRaw = max(0, liveEdge - current)
                if liveEdgeLatencyRaw <= edgeLatencyUnavailableEpsilonSeconds {
                    edgeLatencyLowConfidenceStreak += 1
                } else {
                    edgeLatencyLowConfidenceStreak = 0
                }

                let liveEdgeLatency: Double? = edgeLatencyLowConfidenceStreak >= edgeLatencyUnavailableSamples
                    ? nil
                    : liveEdgeLatencyRaw
                liveEdgeLatencySeconds = liveEdgeLatency
                applyLiveLatencyCorrection(
                    item: item,
                    range: range,
                    wallClockLatency: wallClockLatencySeconds,
                    liveEdgeLatency: liveEdgeLatency
                )
            } else {
                liveEdgeLatencySeconds = nil
                edgeLatencyLowConfidenceStreak = 0
            }
        } else {
            liveEdgeLatencySeconds = nil
            edgeLatencyLowConfidenceStreak = 0
            applyLiveLatencyCorrection(
                item: item,
                range: nil,
                wallClockLatency: wallClockLatencySeconds,
                liveEdgeLatency: nil
            )
        }
    }

    /// Keeps playback close to the live edge without constant hard seeks.
    private func applyLiveLatencyCorrection(
        item: AVPlayerItem,
        range: CMTimeRange?,
        wallClockLatency: Double?,
        liveEdgeLatency: Double?
    ) {
        guard isPlaybackActive else { return }
        let now = Date()

        if let liveEdgeLatency {
            // Ignore tiny/unstable values to avoid oscillation.
            guard liveEdgeLatency >= 0.8 else {
                if abs(player.rate - 1.0) > 0.01 {
                    player.playImmediately(atRate: 1.0)
                }
                return
            }

            if liveEdgeLatency >= hardCatchUpThresholdSeconds {
                guard now.timeIntervalSince(lastHardCatchUpJumpAt) >= hardCatchUpCooldownSeconds else { return }

                guard let range else { return }

                let edge = CMTimeRangeGetEnd(range)
                let edgeSeconds = CMTimeGetSeconds(edge)
                let floorSeconds = CMTimeGetSeconds(range.start)
                let targetSeconds = max(floorSeconds, edgeSeconds - targetLiveEdgeSeconds)

                guard targetSeconds.isFinite else { return }
                let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: edge.timescale == 0 ? 600 : edge.timescale)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                player.playImmediately(atRate: 1.0)
                lastHardCatchUpJumpAt = now
                wallClockHighLatencyStreak = 0
                return
            }

            if liveEdgeLatency > softCatchUpThresholdSeconds {
                // Mild speed-up only; prioritize smooth playback over aggressive chasing.
                let overshoot = liveEdgeLatency - softCatchUpThresholdSeconds
                let targetRate = min(maxCatchUpRate, 1.01 + Float(overshoot / 60.0))
                if abs(player.rate - targetRate) > 0.01 {
                    player.playImmediately(atRate: targetRate)
                }
                wallClockHighLatencyStreak = 0
                return
            }

            wallClockHighLatencyStreak = 0
            if liveEdgeLatency <= targetLiveEdgeSeconds + 0.8, abs(player.rate - 1.0) > 0.01 {
                player.playImmediately(atRate: 1.0)
            }
            return
        }

        // Fallback for channels where seekable-range edge latency is unreliable.
        wallClockHighLatencyStreak = 0
        if abs(player.rate - 1.0) > 0.01 {
            player.playImmediately(atRate: 1.0)
        }
    }

    private func refreshChannelMetadata() async {
        guard let metadata = await PlaybackService.channelMetadata(for: channel) else {
            channelDisplayName = channel
            channelAvatarURL = nil
            return
        }
        channelDisplayName = metadata.displayName
        channelAvatarURL = metadata.profileImageURL
        streamTitle = metadata.title
    }

    /// Applies the current captions preference to the active item.
    private func applyCaptions() {
        if let item = player.currentItem { applyCaptions(to: item, retries: 12) }
    }

    private func captionKey(_ option: AVMediaSelectionOption) -> String {
        let language = option.extendedLanguageTag ?? option.locale?.identifier ?? ""
        return "\(language)|\(option.displayName)"
    }

    /// Turns in-band closed captions on or off for a given item. Twitch streams
    /// carry CEA-608 captions in the legible selection group.
    ///
    /// The legible group can appear slightly after playback starts, so we retry
    /// for a short window instead of failing one-shot.
    private func applyCaptions(to item: AVPlayerItem, retries: Int) {
        let wantCaptions = captionsOn
        let preferredCaption = captionSelectionKey
        Task {
            for attempt in 0...retries {
                if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                    await MainActor.run {
                        captionGroup = group
                        captionOptions = group.options
                        guard !group.options.isEmpty else { return }

                        if wantCaptions {
                            let preferred = group.options.first {
                                captionKey($0) == preferredCaption
                            } ?? group.options.first {
                                !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                            } ?? group.options.first
                            if let option = preferred {
                                captionSelectionKey = captionKey(option)
                                item.select(option, in: group)
                            }
                        } else {
                            captionSelectionKey = nil
                            item.select(nil, in: group)
                        }
                    }
                    return
                }

                if attempt < retries {
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        }
    }

    private func setIdleTimer(disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

private extension View {
    @ViewBuilder
    func twitcherControlButtonStyle() -> some View {
        if #available(tvOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.automatic)
        }
    }
}
