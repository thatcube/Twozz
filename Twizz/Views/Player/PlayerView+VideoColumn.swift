import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

extension PlayerView {
  /// The concurrent YouTube viewer count to show in the player's per-platform
  /// row, or `nil` when this stream's creator isn't live on YouTube. Resolves the
  /// streamer's YouTube channel ID from either the followed-channel enrichment
  /// (dual-platform follows) or the public Twitch→YouTube alias table (so it also
  /// covers simulcasters the viewer doesn't follow), then reads that channel's
  /// live presence from the same public snapshot the Home cards use. No YouTube
  /// API call is made from the device, and a count is never shown unless that
  /// YouTube channel is currently live — which also matches the source the player
  /// now defaults to for simulcasters.
  var youtubeViewerCountForCurrentStream: Int? {
    guard !isVOD else { return nil }
    let login = activeChannel.isEmpty ? channel : activeChannel
    guard !login.isEmpty else { return nil }

    let followedPresence = environment.follows.channels
      .first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame })?.youtube
    guard let channelID = followedPresence?.channelID
      ?? environment.youtubeAliases.youtubeChannelID(forTwitchLogin: login)
    else { return nil }

    // Prefer the freshest snapshot reading, falling back to the value already
    // enriched onto the followed channel; only show it while live on YouTube.
    let snapshot = environment.youtubeLive.presence(forChannelID: channelID)
    let isLive = snapshot?.isLive ?? followedPresence?.isLive ?? false
    guard isLive else { return nil }
    return snapshot?.viewerCount ?? followedPresence?.viewerCount
  }

  var videoColumn: some View {
    ZStack(alignment: .bottom) {
      VideoSurface(player: player)
        .ignoresSafeArea()
        // Shared loading surface: the stream's frame behind the channel's
        // avatar, name, and a native spinner. Anchored as an overlay on the
        // video so it tracks the *exact* video frame in every chat layout — the
        // shrunken column in side mode, full-bleed in overlay/glass — instead of
        // escaping to fullscreen. Cross-fades to live video once playback
        // starts, so opening a stream reads as a quick sharpen instead of a
        // black "Loading…" gap.
        .overlay {
          StreamLoadingView(
            posterURL: posterURL,
            avatarURL: channelAvatarURL,
            title: isVOD ? activeVOD?.title : offlineDisplayName
          )
          .padding(.trailing, loadingChatInset)
          .opacity(isLoading && errorMessage == nil && !isOffline ? 1 : 0)
          .allowsHitTesting(false)
          .animation(.easeOut(duration: 0.45), value: isLoading)
        }

      if isAudioOnlyActive, !isLoading, errorMessage == nil, !isOffline {
        AudioVisualizerContainer(
          monitor: audioLevelMonitor,
          avatarURL: channelAvatarURL,
          palette: palette
        )
        .transition(.opacity)
        .onAppear {
          audioLevelMonitor.start(
            audioPlaylistURL: audioOnlyPlaylistURL,
            headers: PlaybackService.streamHeaders,
            currentDate: { [weak player] in player?.currentItem?.currentDate() }
          )
        }
        .onDisappear { audioLevelMonitor.stop() }
      }

      if captionsEnabled, !isVOD, errorMessage == nil, !isOffline {
        CaptionOverlayView(
          controller: captionController,
          controlsVisible: showControls,
          fontScale: captionsFontScale,
          verticalPosition: captionsVerticalPosition,
          backgroundStyle: CaptionBackgroundStyle.from(captionsBackgroundStyleRaw),
          outline: captionsOutline,
          textColor: CaptionTextColor.from(captionsTextColorRaw).color,
          textOpacity: captionsTextOpacity
        )
        .transition(.opacity)
      }

      if showControls, !isLoading,
        errorMessage == nil, !isOffline
      {
        VStack {
          HStack(alignment: .top) {
            PlayerTitleHeader(
              title: streamTitle.isEmpty ? channelDisplayName : streamTitle,
              latency: latencyReadout,
              hermes: hermes,
              chat: chat,
              youtubeViewerCount: youtubeViewerCountForCurrentStream,
              showSubheader: !isVOD,
              showLatency: showLatencyBadge,
              showViewerCount: showViewerCount
            )
            Spacer(minLength: 24)
            if let remaining = sleepRemainingSeconds {
              SleepCountdownBadge(text: SleepCountdownBadge.format(seconds: remaining))
            } else if sleepUntilStreamEnds {
              SleepCountdownBadge(text: "End of stream")
            }
          }
          if showLatencyDiagnostics {
            HStack {
              DiagnosticsPanel(lines: diagnosticsLines, events: diagEvents)
              Spacer()
            }
            .padding(.top, 12)
          }
          Spacer()
        }
        .padding(.top, 36)
        .padding(.leading, 40)
        .padding(.trailing, controlsTrailingInset)
        .background(
          LinearGradient(
            stops: [
              .init(color: .black.opacity(1.0), location: 0.0),
              .init(color: .black.opacity(0.72), location: 0.44),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(maxWidth: .infinity)
          .frame(height: 280)
          .allowsHitTesting(false),
          alignment: .top
        )
      }

      // Only expose the video focus target while controls are hidden.
      // Otherwise, left-edge movement from the control cluster can escape
      // into this invisible target and appear as lost focus.
      if !showControls, !isOffline {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .focusable()
          .focused($focus, equals: .video)
          .onTapGesture { revealControls(preferredFocus: .quality) }
      }

      if isOffline {
        offlineState
      } else if let errorMessage {
        VStack(spacing: 24) {
          Text("Couldn't play \(activeChannel)")
            .font(.title2).bold()
          Text(errorMessage)
            .foregroundStyle(.secondary)
          Button("Back") { dismiss() }
            .focused($focus, equals: .errorBack)
        }
        .padding(40)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
      } else if showControls {
        bottomOverlay
      }
    }
    .onPlayPauseCommand {
      guard rewindAvailable, errorMessage == nil, !isOffline, !isLoading else { return }
      toggleRewindPlayPause()
    }
  }

  // MARK: - Offline empty state

  var offlineDisplayName: String {
    channelDisplayName.isEmpty ? activeChannel : channelDisplayName
  }

  /// Horizontal shift applied to the offline empty-state content so it stays
  /// visually centered in the *uncovered* area. In overlay/glass chat modes the
  /// video (and this empty state) spans the full screen while the chat pane
  /// floats over the right edge, so without this the content reads as
  /// off-center. Shift left by half the width the chat occupies. The chat width
  /// is user-customizable, so this tracks `chatWidth`.
  var offlineContentHorizontalOffset: CGFloat {
    guard showChat, chatLayoutMode.isOverlay else { return 0 }
    switch chatLayoutMode {
    case .glass:
      return -(chatWidth + GlassChatPaneStyle.edgeInset) / 2
    case .overlay:
      return -chatWidth / 2
    case .side:
      return 0
    }
  }

  var offlineState: some View {
    ZStack {
      // Opaque backdrop so the frozen last frame never bleeds through.
      palette.playerBackdrop.ignoresSafeArea()

      VStack(spacing: 28) {
        offlineAvatar

        VStack(spacing: 10) {
          Text("OFFLINE")
            .font(.caption.weight(.bold))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.white.opacity(0.10), in: Capsule())

          Text(offlineDisplayName)
            .font(.system(size: 46, weight: .bold))
            .foregroundStyle(.white)

          Text("The stream has ended.")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))

          Text("Catch up on recent videos and clips, or check back soon.")
            .font(.body)
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
        }

        HStack(spacing: 20) {
          Button {
            presentChannelPage()
          } label: {
            Label("View Channel", systemImage: "play.rectangle.on.rectangle")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .buttonStyle(.borderedProminent)
          .tint(ThemePalette.brandPurple)
          .focused($focus, equals: .offlineViewChannel)
          .onMoveCommand { direction in
            if direction == .right { focus = .offlineTryAgain }
          }

          Button {
            retryFromOffline()
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
              .font(.headline)
              .padding(.horizontal, 10)
          }
          .TwizzControlButtonStyle()
          .focused($focus, equals: .offlineTryAgain)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              focus = .offlineViewChannel
            case .right:
              // Deliberate exit out of the focus section into chat, mirroring
              // the control row's chat-toggle button.
              if showChat { focus = chatFocusAnchor }
            default:
              break
            }
          }
        }
        .padding(.top, 8)
        // Group the two buttons as one focus section so the full-height chat
        // pane (a strong geometric focus magnet) can't out-pull the adjacent
        // Try Again button. Within the section the explicit move handlers above
        // step View Channel -> Try Again, and only a right-press from Try Again
        // exits into chat. Mirrors the bottom control row's focus corralling.
        .focusSection()
      }
      .frame(maxWidth: 760)
      .padding(48)
      .offset(x: offlineContentHorizontalOffset)
      .animation(.easeOut(duration: 0.18), value: offlineContentHorizontalOffset)
    }
    .transition(.opacity)
  }

  @ViewBuilder
  var offlineAvatar: some View {
    Group {
      if let channelAvatarURL {
        CachedAsyncImage(url: channelAvatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          offlineAvatarPlaceholder
        }
      } else {
        offlineAvatarPlaceholder
      }
    }
    .frame(width: 132, height: 132)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    .grayscale(0.6)
    .opacity(0.9)
  }

  var offlineAvatarPlaceholder: some View {
    ZStack {
      Circle().fill(.white.opacity(0.10))
      Icon(glyph: .userCircle, size: 64)
        .foregroundStyle(.white.opacity(0.7))
    }
  }

}
