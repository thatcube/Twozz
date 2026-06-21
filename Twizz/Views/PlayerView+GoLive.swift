import SwiftUI

// "Just went live" banner shown over the player when a followed channel starts
// broadcasting. Anchored bottom-middle and styled like the raid banners (rather
// than the old top-trailing toast) so reaching its "Watch" button never routes
// focus up through the chat column. The focusable button is wired into
// PlayerView's own `focus` model (`.goLiveWatch`) instead of a detached
// `@FocusState`, so claiming focus here can't silently strand an active chat
// scroll — the banner explicitly resumes live chat first.
extension PlayerView {
  @ViewBuilder
  func goLiveBanner(_ watcher: GoLiveWatcher, event: GoLiveEvent) -> some View {
    VStack {
      Spacer()
      HStack(spacing: 16) {
        goLiveAvatar(event.profileImageURL)
        VStack(alignment: .leading, spacing: 2) {
          Text(event.headline)
            .font(.headline).bold()
            .foregroundStyle(.primary)
          if let subtitle = event.subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .accessibilityElement(children: .combine)
        Button {
          watchGoLive(watcher)
        } label: {
          HStack(spacing: 10) {
            Icon(glyph: .playerPlayFilled, size: 22)
            Text("Watch")
          }
          .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Switch to the channel that just went live")
        .focused($focus, equals: .goLiveWatch)
      }
      .padding(.leading, 20)
      .padding(.vertical, 20)
      .padding(.trailing, 28)
      .background {
        // Neutral, theme-aware surface (matches the raid banners) instead of a
        // fixed color: an opaque palette surface when transparency is reduced,
        // otherwise native glass. Stays legible in every theme.
        if glassDisabled {
          Capsule().fill(palette.chromeOpaqueSurface)
            .overlay(Capsule().strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
        } else if #available(tvOS 26.0, *) {
          Capsule().glassEffect(.regular, in: Capsule())
        } else {
          Capsule().fill(.ultraThinMaterial)
        }
      }
      .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
      .padding(.bottom, 60)
    }
    .ignoresSafeArea()
    .task(id: event.id) {
      // The banner is about to claim focus. If chat is frozen (soft-paused or
      // actively scrolling), resume the live feed *first* — restoreFocus:false so
      // it clears the freeze without the composer-focus stomp — so grabbing
      // `.goLiveWatch` sticks and auto-scroll can never be left stranded.
      if isChatScrolling || chatSoftPauseRemaining != nil {
        resumeChatLive()
      }
      // Let the move/opacity transition settle before claiming focus, so tvOS
      // reliably lands on the button instead of dropping the request mid-animation.
      try? await Task.sleep(for: .milliseconds(350))
      focus = .goLiveWatch
    }
  }

  /// The just-live channel's avatar, with a neutral placeholder while it loads.
  /// Mirrors the raid banner's avatar treatment.
  private func goLiveAvatar(_ url: URL?) -> some View {
    let size: CGFloat = 72
    return CachedAsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Circle().fill(glassDisabled ? AnyShapeStyle(palette.chromeOpaqueSurface) : AnyShapeStyle(.ultraThinMaterial))
        Icon(glyph: .broadcast, size: size * 0.42)
          .foregroundStyle(.red)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  /// Dismiss the banner and switch the player to the channel that just went live.
  /// Reuses the raid follow path — a full teardown + reload of playback, chat,
  /// and EventSub for the new channel.
  func watchGoLive(_ watcher: GoLiveWatcher) {
    guard let login = watcher.watch() else { return }
    guard login.caseInsensitiveCompare(activeChannel) != .orderedSame else { return }
    followRaid(login)
  }
}
