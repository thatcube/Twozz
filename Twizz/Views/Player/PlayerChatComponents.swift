import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// Wraps `ChatView` and reads the live `ChatService` itself. New chat messages
/// mutate `chat.messages`; doing that read inside this small view (instead of in
/// the giant PlayerView body) means only the chat column re-renders per message.
/// Previously the PlayerView body observed `chat.messages`, so every incoming
/// message re-executed the whole body and flashed the open Quality menu's focus
/// many times a second on busy channels.
struct ChatMessagesColumn: View {
  /// Live IRC source (live player). Mutually exclusive with `replay`.
  var chat: ChatService? = nil
  /// VOD chat-replay source. Mutually exclusive with `chat`.
  var replay: VODChatReplayService? = nil
  let channel: String
  let replayStartMessageID: ChatMessage.ID?
  /// When non-nil, the viewer is paused/scrolling: render this fixed snapshot
  /// instead of the live buffer so the list can't shift under them. While nil,
  /// `visibleMessages` reads the live buffer inside this wrapper's own body (the
  /// reason this view exists) so PlayerView's body isn't re-run per message.
  var frozenMessages: [ChatMessage]? = nil
  let textSize: CGFloat
  let emoteSize: CGFloat
  let messageSpacing: CGFloat
  let lineHeight: CGFloat
  let letterSpacing: CGFloat
  let animatedEmotes: Bool
  let fontStyle: ChatFontStyle
  let showBadges: Bool
  let showPlatformBadges: Bool
  /// Highlight (mention) inputs, passed straight through to `ChatView`.
  var highlightEnabled: Bool = true
  var viewerLogin: String? = nil
  var viewerDisplayName: String? = nil
  var highlightKeywords: [String] = []
  let useGlassBackground: Bool
  let useLighterOverlayBackground: Bool
  let autoScroll: Bool
  let softPauseRemaining: Int?
  let softPauseTotal: Int
  let scrollTarget: ChatScrollTarget?

  private var visibleMessages: [ChatMessage] {
    if let frozenMessages { return frozenMessages }
    if let replay { return replay.messages }
    guard let chat else { return [] }
    guard let startID = replayStartMessageID else { return chat.messages }
    guard let startIndex = chat.messages.firstIndex(where: { $0.id == startID }) else {
      return chat.messages
    }
    return Array(chat.messages[startIndex...])
  }

  private var isConnected: Bool { replay?.isReady ?? chat?.isConnected ?? false }
  private var emoteURLs: [String: URL] { replay?.emoteURLs ?? chat?.emoteURLs ?? [:] }
  private var badgeURLs: [String: URL] { replay?.badgeURLs ?? chat?.badgeURLs ?? [:] }
  private var cheermotes: [Cheermote] { replay?.cheermotes ?? chat?.cheermotes ?? [] }
  /// VOD comments carry no `bits` tag, so cheermote tokens there are matched by
  /// token alone (the way Twitch renders VOD cheers). Live chat stays gated on
  /// the IRC `bits` tag to avoid false positives.
  private var matchCheersWithoutBits: Bool { replay != nil }

  var body: some View {
    ChatView(
      channel: channel,
      messages: visibleMessages,
      textSize: textSize,
      emoteSize: emoteSize,
      messageSpacing: messageSpacing,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      animatedEmotes: animatedEmotes,
      fontStyle: fontStyle,
      showBadges: showBadges,
      showPlatformBadges: showPlatformBadges,
      highlightEnabled: highlightEnabled,
      viewerLogin: viewerLogin,
      viewerDisplayName: viewerDisplayName,
      highlightKeywords: highlightKeywords,
      isConnected: isConnected,
      emoteURLs: emoteURLs,
      badgeURLs: badgeURLs,
      cheermotes: cheermotes,
      matchCheersWithoutBits: matchCheersWithoutBits,
      useGlassBackground: useGlassBackground,
      useLighterOverlayBackground: useLighterOverlayBackground,
      autoScroll: autoScroll,
      softPauseRemaining: softPauseRemaining,
      softPauseTotal: softPauseTotal,
      scrollTarget: scrollTarget
    )
  }
}

/// The native quality picker, extracted into its own `Equatable` view so the
/// player's once-per-second latency/diagnostics state churn doesn't re-render
/// (and visibly re-focus / "blink") the open `Menu`. SwiftUI only re-evaluates
/// this view when one of the value inputs compared in `==` actually changes.
struct QualityMenu: View, Equatable {
  let options: [String]
  let selectedOption: String
  let buttonLabel: String
  let reservedWidthLabels: [String]
  let displayLabel: (String) -> String
  let onSelect: (Int) -> Void
  let onMenuPresented: () -> Void
  let onMenuDismissed: () -> Void
  // Stream source, nested as a submenu (Twitch / YouTube simulcast). Only shown
  // when the channel actually has a resolvable YouTube simulcast.
  let sourceAvailable: Bool
  let sourceOptions: [String]
  let sourceSelectedIndex: Int
  let onSelectSource: (Int) -> Void
  // Sleep timer, nested as a submenu under the quality list (no extra button).
  let sleepOptions: [String]
  let sleepSelectedIndex: Int
  let sleepIsArmed: Bool
  let onSelectSleep: (Int) -> Void
  // Stream Rewind + Viewer Count: user-facing playback toggles relocated out of
  // the old custom Playback page into this native menu.
  let rewindEnabled: Bool
  let onToggleRewind: () -> Void
  let viewerCountEnabled: Bool
  let onToggleViewerCount: () -> Void
  // Captions: demoted here (low priority — auto-generated). On/off plus an
  // "Options…" deep-link to the captions appearance panel. Hidden on
  // unsupported hardware.
  let captionsSupported: Bool
  let captionsEnabled: Bool
  let onToggleCaptions: () -> Void
  let onOpenCaptionOptions: () -> Void
  // Diagnostics submenu: the "never touched" latency/debug knobs, tucked one
  // level deeper. The Simulate actions only appear while the overlay is on.
  let latencyBadgeEnabled: Bool
  let onToggleLatencyBadge: () -> Void
  let diagnosticsEnabled: Bool
  let onToggleDiagnostics: () -> Void
  let chatSyncEnabled: Bool
  let onToggleChatSync: () -> Void
  let prefetchProxyEnabled: Bool
  let onTogglePrefetchProxy: () -> Void
  let onSimulateOutgoingRaid: () -> Void
  let onSimulateIncomingRaid: () -> Void
  let onSimulateOffline: () -> Void
  let onSimulateMoment: () -> Void
  let onSimulateGoLive: () -> Void

  nonisolated static func == (lhs: QualityMenu, rhs: QualityMenu) -> Bool {
    lhs.options == rhs.options
      && lhs.selectedOption == rhs.selectedOption
      && lhs.buttonLabel == rhs.buttonLabel
      && lhs.reservedWidthLabels == rhs.reservedWidthLabels
      && lhs.sourceAvailable == rhs.sourceAvailable
      && lhs.sourceOptions == rhs.sourceOptions
      && lhs.sourceSelectedIndex == rhs.sourceSelectedIndex
      && lhs.sleepSelectedIndex == rhs.sleepSelectedIndex
      && lhs.sleepIsArmed == rhs.sleepIsArmed
      && lhs.rewindEnabled == rhs.rewindEnabled
      && lhs.viewerCountEnabled == rhs.viewerCountEnabled
      && lhs.captionsSupported == rhs.captionsSupported
      && lhs.captionsEnabled == rhs.captionsEnabled
      && lhs.latencyBadgeEnabled == rhs.latencyBadgeEnabled
      && lhs.diagnosticsEnabled == rhs.diagnosticsEnabled
      && lhs.chatSyncEnabled == rhs.chatSyncEnabled
      && lhs.prefetchProxyEnabled == rhs.prefetchProxyEnabled
  }

  /// Drives the inline `Picker` selection. Reading derives the current index
  /// from `selectedOption`; writing routes through `onSelect` so the player
  /// applies the quality change and its side effects.
  private var selection: Binding<Int> {
    Binding(
      get: { options.firstIndex(of: selectedOption) ?? 0 },
      set: { onSelect($0) }
    )
  }

  private var sourceSelection: Binding<Int> {
    Binding(
      get: { sourceSelectedIndex },
      set: { onSelectSource($0) }
    )
  }

  /// Submenu row label for the nested Quality picker, e.g. "Quality · Auto
  /// (1080p60)", so the current rendition is visible without drilling in.
  private var qualityMenuLabel: String {
    "Quality · \(buttonLabel)"
  }

  /// Submenu row label for the nested Stream Source picker, e.g.
  /// "Source · YouTube".
  private var sourceMenuLabel: String {
    guard sourceOptions.indices.contains(sourceSelectedIndex) else { return "Source" }
    return "Source · \(sourceOptions[sourceSelectedIndex])"
  }

  private var sleepSelection: Binding<Int> {
    Binding(
      get: { sleepSelectedIndex },
      set: { onSelectSleep($0) }
    )
  }

  // Boolean menu toggles. Toggle passes the new value; we ignore it and route
  // through the closure, which flips the underlying @AppStorage on PlayerView.
  private var rewindBinding: Binding<Bool> {
    Binding(get: { rewindEnabled }, set: { _ in onToggleRewind() })
  }
  private var viewerCountBinding: Binding<Bool> {
    Binding(get: { viewerCountEnabled }, set: { _ in onToggleViewerCount() })
  }
  private var captionsBinding: Binding<Bool> {
    Binding(get: { captionsEnabled }, set: { _ in onToggleCaptions() })
  }
  private var latencyBadgeBinding: Binding<Bool> {
    Binding(get: { latencyBadgeEnabled }, set: { _ in onToggleLatencyBadge() })
  }
  private var diagnosticsBinding: Binding<Bool> {
    Binding(get: { diagnosticsEnabled }, set: { _ in onToggleDiagnostics() })
  }
  private var chatSyncBinding: Binding<Bool> {
    Binding(get: { chatSyncEnabled }, set: { _ in onToggleChatSync() })
  }
  private var prefetchProxyBinding: Binding<Bool> {
    Binding(get: { prefetchProxyEnabled }, set: { _ in onTogglePrefetchProxy() })
  }

  private var sleepMenuLabel: String {
    guard sleepIsArmed, sleepOptions.indices.contains(sleepSelectedIndex) else {
      return "Sleep timer"
    }
    return "Sleep timer: \(sleepOptions[sleepSelectedIndex])"
  }

  var body: some View {
    // Invisible barrier: hidden copies of every possible label reserve the
    // width of the widest one, so the in-player title's available space stays
    // constant. The barrier draws nothing and isn't focusable — only the Menu
    // is interactive, and its platter hugs the live label, so the visible
    // button stays variable-width. Trailing alignment parks the button against
    // the next control, letting the reserved slack sit (invisibly) on its left.
    ZStack(alignment: .trailing) {
      ForEach(reservedWidthLabels, id: \.self) { candidate in
        qualityLabelText(candidate).hidden()
      }

      Menu {
        // NOTE (tvOS 27 dev-beta regression, build 24J5289o): on a focused
        // submenu row the white focus pill correctly inverts the row's text and
        // leading icon to dark, but the *system* trailing disclosure chevron does
        // NOT invert — it stays white and disappears on the white pill. Verified
        // fine on the tvOS 26.5 simulator with identical code, so this is an OS
        // bug, not ours. There is no public API to recolor/hide that specific
        // chevron (`.menuIndicator(.hidden)` doesn't affect the nested-submenu
        // indicator, and a hand-drawn chevron just doubles up with the system
        // one). Left as-is intentionally — do not add custom chevrons or color
        // overrides to "fix" it; revisit when the tvOS 27 GA ships.
        //
        // Quality is a nested submenu alongside Stream Source and Sleep timer.
        // The lifecycle hooks live on this submenu's row (a direct child of the
        // top-level menu) so they fire on the top menu's open/close, not when
        // drilling into a sibling submenu.
        Menu {
          // A `Picker` is Apple's recommended single-selection control inside a
          // menu: it renders a checkmark in a reserved leading gutter so every
          // row's text stays aligned (no per-row shift), unlike hand-placed
          // checkmark labels.
          Picker("Quality", selection: selection) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
              Text(displayLabel(option)).tag(index)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label(qualityMenuLabel, systemImage: "rectangle.on.rectangle")
        }
        .onAppear(perform: onMenuPresented)
        .onDisappear(perform: onMenuDismissed)

        // Stream Source: swap the live video between Twitch and the streamer's
        // YouTube simulcast (lower latency). Only offered when a YouTube
        // simulcast actually resolved for this channel.
        if sourceAvailable {
          Menu {
            Picker("Source", selection: sourceSelection) {
              ForEach(Array(sourceOptions.enumerated()), id: \.element) { index, option in
                Text(option).tag(index)
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label(sourceMenuLabel, systemImage: "dot.radiowaves.left.and.right")
          }
        }

        Divider()

        // Playback toggles relocated from the old custom Playback page. Native
        // Toggles render as checkmark rows in the menu.
        Toggle(isOn: rewindBinding) {
          Label("Stream Rewind", systemImage: "gobackward")
        }
        Toggle(isOn: viewerCountBinding) {
          Label("Viewer Count", systemImage: "person.2")
        }

        // Captions: deliberately low-key here rather than a dedicated transport
        // button. On/off inline; the fiddly appearance controls hide behind
        // "Caption Options…", which opens the dedicated captions panel.
        if captionsSupported {
          Toggle(isOn: captionsBinding) {
            Label("Captions", systemImage: "captions.bubble")
          }
          if captionsEnabled {
            Button {
              onOpenCaptionOptions()
            } label: {
              Label("Caption Options…", systemImage: "textformat")
            }
          }
        }

        Divider()

        // Sleep timer kept as a nested submenu so Quality stays the primary,
        // one-tap control while the timer hides one level deeper.
        Menu {
          Picker("Sleep timer", selection: sleepSelection) {
            ForEach(Array(sleepOptions.enumerated()), id: \.element) { index, option in
              Text(option).tag(index)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label(sleepMenuLabel, systemImage: "moon.zzz")
        }

        // Diagnostics: the latency/debug knobs end users never touch, tucked one
        // level deeper. Prefetch proxy + the Simulate actions only surface once
        // the Diagnostics overlay is on.
        Menu {
          Toggle(isOn: latencyBadgeBinding) {
            Label("Latency Readout", systemImage: "speedometer")
          }
          Toggle(isOn: diagnosticsBinding) {
            Label("Diagnostics Overlay", systemImage: "waveform.path.ecg")
          }
          Toggle(isOn: chatSyncBinding) {
            Label("Match Stream Delay", systemImage: "timer")
          }

          if diagnosticsEnabled {
            Toggle(isOn: prefetchProxyBinding) {
              Label("Prefetch Proxy", systemImage: "bolt.horizontal")
            }

            Divider()

            Button { onSimulateOutgoingRaid() } label: {
              Label("Simulate Outgoing Raid", systemImage: "arrowshape.turn.up.right")
            }
            Button { onSimulateIncomingRaid() } label: {
              Label("Simulate Incoming Raid", systemImage: "arrowshape.turn.up.left")
            }
            Button { onSimulateOffline() } label: {
              Label("Simulate Stream Offline", systemImage: "wifi.slash")
            }
            Button { onSimulateMoment() } label: {
              Label("Simulate Interactive Moment", systemImage: "sparkles")
            }
            Button { onSimulateGoLive() } label: {
              Label("Simulate Go Live", systemImage: "dot.radiowaves.left.and.right")
            }
          }
        } label: {
          Label("Diagnostics", systemImage: "stethoscope")
        }
      } label: {
        qualityLabelText(buttonLabel)
          .accessibilityLabel("Quality, \(buttonLabel)")
      }
    }
  }

  /// `true` for the live "Auto (1080p60)" form, which we render slightly
  /// smaller so the parenthetical resolution reads as a secondary detail.
  private func isAutoResolutionLabel(_ text: String) -> Bool {
    text.hasPrefix("Auto (")
  }

  @ViewBuilder
  private func qualityLabelText(_ text: String) -> some View {
    Group {
      if isAutoResolutionLabel(text) {
        Text(text)
          .font(.system(size: Self.compactQualityFontSize, weight: .semibold))
      } else {
        Text(text)
          .font(.subheadline)
          .fontWeight(.semibold)
      }
    }
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
    // Match the sibling control buttons' height. Those (chat settings, chat
    // toggle) wrap a 40pt `Icon.controlButtonSize` glyph, so reserve that same
    // content height for the quality label. Without it the much shorter text
    // line (even at regular `.subheadline`, and more so the compact "Auto
    // (1080p60)" form) makes this button's platter sit a few px shorter than its
    // neighbors. `minHeight` only affects height, so the variable width is
    // untouched.
    .frame(minHeight: Icon.controlButtonSize)
  }

  /// 20% smaller than `.subheadline`, used for the "Auto (1080p60)" label.
  private static var compactQualityFontSize: CGFloat {
    UIFont.preferredFont(forTextStyle: .subheadline).pointSize * 0.8
  }
}

/// A `UITextField` subclass that refuses focus-engine focus on tvOS. The chat
/// composer's SwiftUI `Button` owns focus and draws the visible capsule; this
/// field exists only to host the keyboard via `becomeFirstResponder()`. Without
/// this, the tvOS focus engine focuses the embedded field too and paints its own
/// rounded platter, producing a "button inside the input" look.
final class NonFocusableTextField: UITextField {
  override var canBecomeFocused: Bool { false }
}

/// Hosts the tvOS keyboard for the chat composer. The visible capsule and draft
/// text are drawn in SwiftUI; this `UITextField` stays visually clear so only
/// the Liquid Glass capsule shows. It deliberately keeps a normal (non‑zero)
/// alpha — tvOS treats near‑invisible views as hidden and instantly resigns
/// their first responder, which is why the previous version's keyboard vanished
/// the moment it appeared. Becoming first responder is also deferred off the
/// SwiftUI update pass so it isn't torn down by the in‑flight view update.
struct ChatKeyboardHostField: UIViewRepresentable {
  @Binding var text: String
  var activationToken: Int = 0
  var onSubmit: () -> Void = {}
  /// Keyboard return-key label. The chat composer uses `.send`; the settings
  /// URL field uses `.done` (and dismisses on return rather than posting).
  var returnKeyType: UIReturnKeyType = .send
  /// When true, pressing return resigns first responder and dismisses the
  /// keyboard instead of keeping the field active.
  var dismissesOnReturn: Bool = false

  /// Shown only as the prompt at the top of the tvOS keyboard entry screen
  /// (the placeholder is surfaced there by the system). It is applied just
  /// before the keyboard presents and cleared when editing ends, so it never
  /// renders inline behind the resting glass capsule.
  var keyboardPrompt: String = "Your message posts to chat immediately"

  func makeUIView(context: Context) -> UITextField {
    let field = NonFocusableTextField()
    field.delegate = context.coordinator
    field.borderStyle = .none
    field.backgroundColor = .clear
    field.textColor = .clear
    field.tintColor = .clear
    field.font = .preferredFont(forTextStyle: .callout)
    field.returnKeyType = returnKeyType
    field.enablesReturnKeyAutomatically = !dismissesOnReturn
    field.autocorrectionType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.addTarget(
      context.coordinator,
      action: #selector(Coordinator.editingChanged(_:)),
      for: .editingChanged
    )
    return field
  }

  func updateUIView(_ uiView: UITextField, context: Context) {
    context.coordinator.parent = self
    if uiView.text != text {
      uiView.text = text
    }

    if context.coordinator.lastActivationToken != activationToken {
      context.coordinator.lastActivationToken = activationToken
      DispatchQueue.main.async {
        if !uiView.isFirstResponder {
          // Set the prompt right before presenting so the keyboard screen shows
          // it; it's cleared again in textFieldDidEndEditing to avoid leaking
          // behind the resting capsule.
          uiView.placeholder = self.keyboardPrompt
          uiView.becomeFirstResponder()
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self, lastActivationToken: activationToken)
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: ChatKeyboardHostField
    var lastActivationToken: Int

    init(_ parent: ChatKeyboardHostField, lastActivationToken: Int) {
      self.parent = parent
      self.lastActivationToken = lastActivationToken
    }

    @objc func editingChanged(_ field: UITextField) {
      parent.text = field.text ?? ""
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      // Clear the prompt so it never renders inline behind the resting capsule.
      textField.placeholder = nil
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.onSubmit()
      if parent.dismissesOnReturn {
        textField.resignFirstResponder()
        return true
      }
      return false
    }
  }
}

/// A small progress pill shown after sending a chat message while stream-sync
/// is holding chat back, counting down until the sent message reaches the
/// delayed video on screen.
struct ChatSyncSendIndicator: View {
  let deadline: Date
  let total: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if reduceMotion {
        // Reduce Motion: step the countdown once a second (no smooth 60fps
        // progress fill) and drop the animated bar.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          indicator(now: context.date)
        }
      } else {
        TimelineView(.animation) { context in
          indicator(now: context.date)
        }
      }
    }
  }

  private func indicator(now: Date) -> some View {
    let remaining = max(0, deadline.timeIntervalSince(now))
    let progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 1
    return HStack(spacing: 10) {
      Icon(glyph: .clock, size: 16)
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(
          remaining > 0.5
            ? "Sent — appears in \(Int(remaining.rounded()))s"
            : "Appearing now…"
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.82))
        if !reduceMotion {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(.purple)
            .accessibilityHidden(true)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// Styles the chat pane as a floating, rounded Liquid Glass panel when enabled,
/// otherwise leaves it as a full-height docked panel.
struct GlassChatPaneStyle: ViewModifier {
  let enabled: Bool
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  /// Inset between the glass panel and the screen edges.
  static let edgeInset: CGFloat = 24

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 40, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      glassBody(content)
        .padding(.vertical, GlassChatPaneStyle.edgeInset)
        .padding(.trailing, GlassChatPaneStyle.edgeInset)
    } else {
      content.frame(maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func glassBody(_ content: Content) -> some View {
    if glassDisabled {
      content
        .frame(maxHeight: .infinity)
        .background(palette.chromeOpaqueSurface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
      content
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

/// Gives the floating chat-settings panel the same real Liquid Glass surface as
/// the Glass chat pane (`.glassEffect(.regular)`), with a matching subtle white
/// hairline. Unlike `GlassChatPaneStyle` it does not clip or inset, so the
/// panel can size to its content and its inner focus effects can lift freely.
struct ChatSettingsPanelGlassStyle: ViewModifier {
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 40, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(palette.chromeOpaqueSurface, in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder, lineWidth: 1))
    } else if #available(tvOS 26.0, *) {
      content
        // Same darkening scrim the Glass chat pane paints over its glass
        // (ChatView uses Color.black.opacity(0.22)); without it the panel's bare
        // glass read noticeably lighter than the chat beside it. Flips to a white
        // scrim in the Light theme so it lightens rather than darkens the glass.
        .background(palette.chromeGlassTint(0.22), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .background(palette.chromeGlassTint(0.22), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
  }
}

