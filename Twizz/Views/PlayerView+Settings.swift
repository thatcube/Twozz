import SwiftUI

// Floating chat settings panels: main page, playback/diagnostics and appearance sub-pages, the reusable settings controls, and the open/close/toggle plumbing.
extension PlayerView {
  // MARK: - Floating chat settings

  /// The focus target for the first control on whichever settings page is shown.
  var firstChatSettingsFocus: Focusable {
    switch chatSettingsPage {
    case .appearance, .playback, .events:
      return .chatAdvancedBack
    case .main:
      let index =
        (activeChatPreset.flatMap { ChatAppearancePreset.allCases.firstIndex(of: $0) }) ?? 1
      return .chatPresetOption(index)
    }
  }

  func chatSettingsPanel(maxHeight: CGFloat) -> some View {
    // Measured content height, capped to the space available beside the chat.
    // When the content is shorter than the cap the panel shrinks to fit; only
    // when it would overflow does the inner ScrollView start scrolling.
    let resolvedHeight =
      chatSettingsContentHeight > 0
      ? min(chatSettingsContentHeight, maxHeight)
      : maxHeight

    return ScrollView(.vertical, showsIndicators: false) {
      Group {
        switch chatSettingsPage {
        case .main:
          mainSettingsContent
        case .appearance:
          appearanceSettingsContent
        case .playback:
          playbackSettingsContent
        case .events:
          eventsSettingsContent
        }
      }
      .padding(.vertical, 18)
      .padding(.horizontal, 30)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: ChatSettingsHeightKey.self,
            value: proxy.size.height
          )
        }
      )
    }
    .frame(maxWidth: .infinity)
    .frame(height: resolvedHeight, alignment: .top)
    .onPreferenceChange(ChatSettingsHeightKey.self) { height in
      chatSettingsContentHeight = height
    }
    // Clip scrolled content to the panel shape so rows that scroll past the top
    // or bottom edge are hidden inside the menu instead of bleeding out over the
    // chat. tvOS auto-scrolls a focused row fully into view, and the content's
    // generous interior padding keeps focus halos off this clip edge.
    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
    // Match the chat pane's real Liquid Glass (`.glassEffect(.regular)`) so the
    // panel reads the same as the Glass chat layout, instead of a flatter
    // frosted material.
    .modifier(ChatSettingsPanelGlassStyle())
    .shadow(color: .black.opacity(0.30), radius: 22, x: 0, y: 10)
    .animation(.easeOut(duration: 0.22), value: resolvedHeight)
    .focusSection()
  }

  // MARK: Main settings page

  var mainSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Appearance")

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatAppearancePreset.allCases.enumerated()), id: \.element) {
            index, preset in
            settingsPill(
              title: preset.title,
              isSelected: activeChatPreset == preset,
              focusTag: .chatPresetOption(index)
            ) {
              applyChatPreset(preset)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        settingsDisclosureRow(
          title: "Advanced",
          detail: activeChatPreset?.title ?? "Custom",
          focusTag: .chatAdvancedButton
        ) {
          openSubpage(.appearance)
        }
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Chat Width")
        settingsStepperRow(.width)
      }

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Chat Position")

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatLayoutMode.allCases.enumerated()), id: \.element) { index, mode in
            settingsPill(
              title: mode.title,
              isSelected: mode == chatLayoutMode,
              focusTag: .chatLayoutOption(index)
            ) {
              chatLayoutModeRaw = mode.rawValue
              // Switching layout restructures the view tree (chat moves
              // between docked and overlay), which drops focus. Re-assert it
              // on the just-selected pill once the new tree is laid out.
              Task { @MainActor in
                focus = .chatLayoutOption(index)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      settingsDisclosureRow(
        title: "Events",
        detail: eventsSettingsSummary,
        focusTag: .chatEventsButton
      ) {
        openSubpage(.events)
      }
      .focusSection()

      settingsDisclosureRow(
        title: "Playback & Diagnostics",
        detail: lowLatencyProxyEnabled ? "Low-Latency On" : nil,
        focusTag: .chatMoreButton
      ) {
        openSubpage(.playback)
      }
      .focusSection()
    }
  }

  // MARK: Playback & diagnostics sub-page

  var playbackSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      subpageHeader("Playback & Diagnostics")

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Stream Sync")

        settingsPill(
          title: chatSyncToStream ? "Synced to Stream Delay" : "Match Stream Delay",
          isSelected: chatSyncToStream,
          focusTag: .chatSyncToggle
        ) {
          chatSyncToStream.toggle()
          applyChatSyncSettings()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(chatSyncStatusDescription)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)
      }
      .focusSection()

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Playback")

        settingsPill(
          title: lowLatencyProxyEnabled ? "Low-Latency Mode On" : "Low-Latency Mode Off",
          isSelected: lowLatencyProxyEnabled,
          focusTag: .chatLowLatencyToggle
        ) {
          lowLatencyProxyEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: streamRewindEnabled ? "Stream Rewind On" : "Stream Rewind Off",
          isSelected: streamRewindEnabled,
          focusTag: .chatRewindToggle
        ) {
          streamRewindEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: showViewerCount ? "Viewer Count On" : "Viewer Count Off",
          isSelected: showViewerCount,
          focusTag: .chatViewerCountToggle
        ) {
          showViewerCount.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: showLatencyBadge ? "Latency Readout On" : "Latency Readout Off",
          isSelected: showLatencyBadge,
          focusTag: .chatLatencyToggle
        ) {
          showLatencyBadge.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: showLatencyDiagnostics ? "Diagnostics Overlay On" : "Diagnostics Overlay Off",
          isSelected: showLatencyDiagnostics,
          focusTag: .chatDiagnosticsToggle
        ) {
          showLatencyDiagnostics.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if showLatencyDiagnostics {
          // Debug-only: outgoing raids can't be triggered on demand, so this
          // injects a simulated one (raiding to Monstercat, a near-24/7 stream)
          // to exercise the auto-follow banner + redirect. Visible only while the
          // Diagnostics overlay is enabled.
          settingsPill(
            title: "Simulate Outgoing Raid",
            isSelected: false,
            focusTag: .simulateRaidButton
          ) {
            simulateOutgoingRaid()
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          // Debug-only: there's no way to force a watched channel offline, so
          // this drops straight into the offline empty state to exercise its
          // layout, copy, and View Channel / Try Again actions. Visible only
          // while the Diagnostics overlay is enabled.
          settingsPill(
            title: "Simulate Stream Offline",
            isSelected: false,
            focusTag: .simulateOfflineButton
          ) {
            showChatSettings = false
            presentOfflineState()
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          // Debug-only: real polls/predictions/hype-trains only fire when a
          // broadcaster runs one, so this cycles a sample moment through all
          // four banner types (poll → prediction → hype train → goal → clear)
          // to exercise the overlay on-device. Visible only while the
          // Diagnostics overlay is enabled.
          settingsPill(
            title: "Simulate Interactive Moment",
            isSelected: false,
            focusTag: .simulateMomentButton
          ) {
            simulateInteractiveMoment()
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          // Debug-only: real follows rarely go live on cue, so this injects a
          // simulated "just went live" toast (for Monstercat, a near-24/7
          // stream) to exercise the toast, its auto-dismiss countdown, and the
          // "Watch" channel switch. Visible only while Diagnostics is enabled.
          settingsPill(
            title: "Simulate Go Live",
            isSelected: false,
            focusTag: .simulateGoLiveButton
          ) {
            showChatSettings = false
            // Let the settings sheet finish dismissing before the toast appears,
            // otherwise it surfaces mid-transition and the focus engine can't
            // reliably hand focus to its "Watch" button.
            Task {
              try? await Task.sleep(for: .milliseconds(600))
              goLive?.simulateGoLive()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text(
          "Low-Latency Mode rewrites Twitch prefetch segments to reduce delay. Stream Rewind keeps recent video buffered so you can pause and rewind live — focus the scrub bar, then swipe or press left/right to jump back or forward 10s and click or press play/pause to pause. Diagnostics shows live render/bitrate/buffer and freeze/jump events."
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      }
      .focusSection()

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Experimental")

        settingsPill(
          title: "Merge with YouTube Chat",
          isSelected: experimentalYouTubeMergeEnabled,
          focusTag: .youtubeMergeToggle
        ) {
          experimentalYouTubeMergeEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          // Seed the keyboard with the value the field is showing so editing
          // starts from the resolved default rather than a blank line.
          if experimentalYouTubeMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty,
            !youtubeMergeDefaultTarget.isEmpty
          {
            experimentalYouTubeMergeChannelOrURL = youtubeMergeDefaultTarget
          }
          youtubeInputActivationToken &+= 1
        } label: {
          Text(youtubeMergeDisplayText)
            .font(.subheadline)
            .foregroundStyle(focus == .youtubeMergeURL ? .black : .white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .youtubeMergeURL))
            .background(
              ChatKeyboardHostField(
                text: $experimentalYouTubeMergeChannelOrURL,
                activationToken: youtubeInputActivationToken,
                onSubmit: {},
                returnKeyType: .done,
                dismissesOnReturn: true,
                keyboardPrompt: "YouTube handle or channel URL"
              )
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            )
        }
        .buttonStyle(ChatInputButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .youtubeMergeURL)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: focus == .youtubeMergeURL)

        if let status = chat.youtubeStatusMessage, experimentalYouTubeMergeEnabled {
          HStack(spacing: 6) {
            if status.hasPrefix("YouTube chat connected") {
              Icon(glyph: .circleCheckFilled, size: 18)
                .foregroundStyle(.green)
            }

            Text(status)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.76))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .focusSection()
    }
  }

  // MARK: Events sub-page

  /// Short summary for the main-page Events row: "All on" when nothing is
  /// hidden, otherwise how many are hidden.
  var eventsSettingsSummary: String {
    let hidden = [
      showRaidEvents, showHypeTrainEvents, showPollEvents,
      showPredictionEvents, showGoalEvents,
    ].filter { !$0 }.count
    return hidden == 0 ? "All on" : "\(hidden) hidden"
  }

  var eventsSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      subpageHeader("Events")

      VStack(alignment: .leading, spacing: 7) {
        settingsSectionHeader("Show on Screen")

        settingsPill(
          title: "Raids",
          isSelected: showRaidEvents,
          focusTag: .chatRaidEventToggle
        ) {
          showRaidEvents.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: "Hype Trains",
          isSelected: showHypeTrainEvents,
          focusTag: .chatHypeTrainEventToggle
        ) {
          showHypeTrainEvents.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: "Polls",
          isSelected: showPollEvents,
          focusTag: .chatPollEventToggle
        ) {
          showPollEvents.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: "Predictions",
          isSelected: showPredictionEvents,
          focusTag: .chatPredictionEventToggle
        ) {
          showPredictionEvents.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        settingsPill(
          title: "Creator Goals",
          isSelected: showGoalEvents,
          focusTag: .chatGoalEventToggle
        ) {
          showGoalEvents.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .focusSection()

      Text(
        "Choose which live moments appear while you watch. These banners are passive and read-only — turning one off just hides it."
      )
      .font(.caption2)
      .foregroundStyle(.white.opacity(0.6))
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Appearance (Advanced) sub-page

  var appearanceSettingsContent: some View {
    VStack(alignment: .leading, spacing: 30) {
      subpageHeader("Advanced")

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Readability")

        settingsStepperRow(.text)
        settingsStepperRow(.lineHeight)
        settingsStepperRow(.letterSpacing)
        settingsStepperRow(.messageSpacing)
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Emotes")

        settingsPill(
          title: chatEmoteAuto ? "Emote Size: Auto" : "Emote Size: Custom",
          isSelected: chatEmoteAuto,
          focusTag: .chatEmoteAutoToggle
        ) {
          chatEmoteAuto.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        if !chatEmoteAuto {
          settingsStepperRow(.emote)
        }

        settingsPill(
          title: chatAnimatedEmotes ? "Animated Emotes On" : "Animated Emotes Off",
          isSelected: chatAnimatedEmotes,
          focusTag: .chatAnimatedToggle
        ) {
          chatAnimatedEmotes.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        Text(
          chatEmoteAuto
            ? "Auto keeps emotes proportional to the text size."
            : "Custom sets emote height independently of the text size."
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Typeface")

        ChatFlowLayout(itemSpacing: 8, rowSpacing: 8) {
          ForEach(Array(ChatFontStyle.allCases.enumerated()), id: \.element) { index, style in
            settingsPill(
              title: style.title,
              isSelected: style == chatFontStyle,
              fontDesign: style.design,
              focusTag: .chatFontOption(index)
            ) {
              chatFontStyleRaw = style.rawValue
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Badges")

        settingsPill(
          title: chatShowBadges ? "Badges On" : "Badges Off",
          isSelected: chatShowBadges,
          focusTag: .chatBadgesToggle
        ) {
          chatShowBadges.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        Text("Hides the small mod, sub, and other badges shown before each name.")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        settingsSectionHeader("Highlights")

        settingsPill(
          title: chatHighlightMentionsEnabled ? "Highlight Mentions On" : "Highlight Mentions Off",
          isSelected: chatHighlightMentionsEnabled,
          focusTag: .chatHighlightToggle
        ) {
          chatHighlightMentionsEnabled.toggle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()

        if chatHighlightMentionsEnabled {
          Button {
            highlightKeywordsActivationToken &+= 1
          } label: {
            Text(highlightKeywordsDisplayText)
              .font(.subheadline)
              .foregroundStyle(focus == .chatHighlightKeywords ? .black : .white)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 28)
              .frame(maxWidth: .infinity)
              .frame(height: 52)
              .modifier(ChatGlassFieldStyle(isFocused: focus == .chatHighlightKeywords))
              .background(
                ChatKeyboardHostField(
                  text: $chatHighlightKeywords,
                  activationToken: highlightKeywordsActivationToken,
                  onSubmit: {},
                  returnKeyType: .done,
                  dismissesOnReturn: true,
                  keyboardPrompt: "Keywords, separated by commas"
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
              )
          }
          .buttonStyle(ChatInputButtonStyle())
          .focusEffectDisabled()
          .focused($focus, equals: .chatHighlightKeywords)
          .frame(maxWidth: .infinity)
          .animation(.easeOut(duration: 0.18), value: focus == .chatHighlightKeywords)
        }

        Text(
          chatHighlightMentionsEnabled
            ? "Highlights any line that mentions or replies to you, plus any keywords above (other handles, a game name, \"giveaway\"…)."
            : "Turn on to highlight lines that mention you or match your keywords."
        )
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .fixedSize(horizontal: false, vertical: true)
      }

      Button {
        resetChatAppearance()
      } label: {
        Text("Reset to Normal")
          .font(.subheadline.weight(.semibold))
      }
      .chatSettingsGlassButton()
      .buttonBorderShape(.capsule)
      .focused($focus, equals: .chatResetButton)
      .focusSection()
    }
  }

  func settingsSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.84))
      .textCase(.uppercase)
  }

  // MARK: Settings controls

  func settingsPill(
    title: String,
    isSelected: Bool,
    icon: Glyph? = nil,
    fontDesign: Font.Design? = nil,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      pinChatFocus(focusTag)
      action()
    } label: {
      HStack(spacing: 8) {
        if let icon {
          Icon(glyph: icon, size: 22)
        }

        Text(title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .fontDesign(fontDesign)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)

        // Trailing checkmark marks the active option, mirroring the main
        // SettingsView pills. Shown only when selected (not a reserved-space
        // placeholder), so unselected pills stay compact with no empty padding.
        if isSelected {
          Icon(glyph: .check, size: 26)
        }
      }
    }
    .chatSettingsGlassButton(isSelected: isSelected)
    .buttonBorderShape(.capsule)
    .focused($focus, equals: focusTag)
  }

  /// Full-width disclosure row (Apple-style): title on the left, optional detail
  /// plus a right-facing chevron on the right, used to drill into a sub-page.
  func settingsDisclosureRow(
    title: String,
    detail: String? = nil,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)

        Spacer(minLength: 12)

        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        // No dedicated right-chevron glyph exists, so reuse the left chevron
        // rotated 180°.
        Icon(glyph: .chevronLeft, size: 36)
          .rotationEffect(.degrees(180))
          .opacity(0.7)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .chatSettingsGlassButton()
    .focused($focus, equals: focusTag)
  }

  /// The Back button + title shown at the top of a settings sub-page.
  func subpageHeader(_ title: String) -> some View {
    HStack(spacing: 14) {
      Button {
        closeSubpage()
      } label: {
        Icon(glyph: .chevronLeft, size: 24)
      }
      .chatSettingsGlassButton()
      .buttonBorderShape(.circle)
      .focused($focus, equals: .chatAdvancedBack)

      Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)

      Spacer(minLength: 0)
    }
    .focusSection()
  }

  func settingsStepperRow(_ field: ChatStepperField) -> some View {
    let config = chatStepperConfig(field)
    let canDecrement = config.value > config.range.lowerBound
    let canIncrement = config.value < config.range.upperBound

    return HStack(spacing: 12) {
      Text(config.title)
        .font(.subheadline)
        .foregroundStyle(.white)

      Spacer(minLength: 12)

      stepperButton(
        glyph: .minus,
        enabled: canDecrement,
        focusTag: .chatStepperDec(field)
      ) {
        adjustChatStepper(field, by: -1)
      }

      Text("\(Int(config.value.rounded()))")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(minWidth: 44)
        .monospacedDigit()

      stepperButton(
        glyph: .plus,
        enabled: canIncrement,
        focusTag: .chatStepperInc(field)
      ) {
        adjustChatStepper(field, by: 1)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 8)
    // A recessed "well" rather than a raised fill: this row is a static container
    // holding glass +/- controls, so it must NOT be glass itself (glass-on-glass
    // is what made the controls look flat). A darkened track reads as recessed and
    // lets the brighter native glass steppers sit *in* it, instead of a light fill
    // that paradoxically looked lighter than its own dark buttons.
    .background(
      Capsule(style: .continuous)
        .fill(.black.opacity(0.22))
        .overlay(
          Capsule(style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    )
    .focusSection()
  }

  func stepperButton(
    glyph: Glyph,
    enabled: Bool,
    focusTag: Focusable,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      pinChatFocus(focusTag)
      action()
    } label: {
      Icon(glyph: glyph, size: 22)
        .opacity(enabled ? 1.0 : 0.35)
    }
    .chatSettingsGlassButton()
    .buttonBorderShape(.circle)
    .focused($focus, equals: focusTag)
  }

  /// Briefly "pin" focus to a just-activated settings control. Toggling an
  /// option can resize the panel, and tvOS responds by yanking focus to the
  /// section's first focusable (the back button). For a short window the focus
  /// handler reverts any such unsolicited jump back to the control the user
  /// actually used; the timer is only a safety net since the pin is consumed on
  /// the first reverted move.
  func pinChatFocus(_ tag: Focusable) {
    chatFocusPin = tag
    chatFocusPinTask?.cancel()
    chatFocusPinTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      chatFocusPin = nil
    }
  }

  func chatStepperConfig(
    _ field: ChatStepperField
  ) -> (title: String, range: ClosedRange<CGFloat>, step: CGFloat, value: CGFloat) {
    switch field {
    case .text:
      return ("Text Size", ChatAppearance.textSizeRange, ChatAppearance.textSizeStep, chatTextSize)
    case .emote:
      return (
        "Emote Size", ChatAppearance.emoteSizeRange, ChatAppearance.emoteSizeStep,
        CGFloat(chatEmoteSizeValue)
      )
    case .lineHeight:
      return (
        "Line Height", ChatAppearance.lineHeightRange, ChatAppearance.lineHeightStep, chatLineHeight
      )
    case .letterSpacing:
      return (
        "Letter Spacing", ChatAppearance.letterSpacingRange, ChatAppearance.letterSpacingStep,
        chatLetterSpacing
      )
    case .messageSpacing:
      return (
        "Message Spacing", ChatAppearance.messageSpacingRange, ChatAppearance.messageSpacingStep,
        chatMessageSpacing
      )
    case .width:
      return ("Width", ChatAppearance.widthRange, ChatAppearance.widthStep, chatWidth)
    }
  }

  func adjustChatStepper(_ field: ChatStepperField, by direction: CGFloat) {
    let config = chatStepperConfig(field)
    let next = ChatAppearance.snap(
      config.value + direction * config.step,
      to: config.range,
      step: config.step
    )
    switch field {
    case .text:
      chatTextSizeValue = Double(next)
    case .emote:
      chatEmoteAuto = false
      chatEmoteSizeValue = Double(next)
    case .lineHeight:
      chatLineHeightValue = Double(next)
    case .letterSpacing:
      chatLetterSpacingValue = Double(next)
    case .messageSpacing:
      chatMessageSpacingValue = Double(next)
    case .width:
      chatWidthValue = Double(next)
    }
  }

  func applyChatPreset(_ preset: ChatAppearancePreset) {
    let values = preset.values
    chatTextSizeValue = Double(values.textSize)
    chatLineHeightValue = Double(values.lineHeight)
    chatMessageSpacingValue = Double(values.messageSpacing)
    chatEmoteAuto = true
  }

  func resetChatAppearance() {
    applyChatPreset(.normal)
    chatEmoteSizeValue = Double(ChatAppearance.defaultEmoteSize)
    chatLetterSpacingValue = Double(ChatAppearance.defaultLetterSpacing)
    chatAnimatedEmotes = ChatAppearance.defaultAnimatedEmotes
  }

  func openSubpage(_ page: ChatSettingsPage) {
    chatSettingsPage = page
    let target: Focusable = .chatAdvancedBack
    lastChatSettingsFocus = target
    Task { @MainActor in
      focus = target
    }
  }

  func closeSubpage() {
    let returnFocus: Focusable
    switch chatSettingsPage {
    case .playback: returnFocus = .chatMoreButton
    case .events: returnFocus = .chatEventsButton
    default: returnFocus = .chatAdvancedButton
    }
    chatSettingsPage = .main
    lastChatSettingsFocus = returnFocus
    Task { @MainActor in
      focus = returnFocus
    }
  }

  /// Settings button lives in the control bar, so it must work even when chat is
  /// hidden: open chat first, then reveal the panel.
  func openChatSettingsFromControlBar() {
    if !showChat {
      toggleChatVisibility()
    }
    toggleChatSettings()
  }

  func toggleChatSettings() {
    showChatSettings.toggle()
    if showChatSettings {
      let target = firstChatSettingsFocus
      lastChatSettingsFocus = target
      focus = target
    } else {
      chatSettingsPage = .main
      lastChatSettingsFocus = .chatSettingsButton
      focus = .chatSettingsButton
    }
  }
}
