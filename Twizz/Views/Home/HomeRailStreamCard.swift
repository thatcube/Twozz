import SwiftUI

/// One focusable stream card on a Home rail. Extracted verbatim from the three
/// near-identical card-render blocks (Following, Recommended for you, Top
/// streams) so the focus / scale / z-index treatment lives in exactly one place.
/// The focus binding is threaded down from `HomeView`'s `@FocusState`, so focus
/// behavior is unchanged.
struct HomeRailStreamCard: View {
  let channel: FollowedChannel
  let itemID: String
  let layout: StreamChannelCard.Layout
  var showsGameName: Bool = true
  var onWatch: ((FollowedChannel) -> Void)? = nil
  var onGoToChannel: ((FollowedChannel) -> Void)? = nil
  var onNotInterested: ((FollowedChannel) -> Void)? = nil
  let onTap: () -> Void
  @FocusState.Binding var focusedItemID: String?

  private var isFocused: Bool { focusedItemID == itemID }

  var body: some View {
    StreamChannelCard(
      channel: channel,
      isFocused: isFocused,
      layout: layout,
      showsGameName: showsGameName,
      onWatch: onWatch,
      onGoToChannel: onGoToChannel,
      onNotInterested: onNotInterested
    )
    .contentShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius))
    .focusable(true)
    .focused($focusedItemID, equals: itemID)
    .focusEffectDisabled()
    .onTapGesture {
      onTap()
    }
    .accessibilityAddTraits(.isButton)
    .scaleEffect(isFocused ? AppLayout.focusedCardScale : 1)
    .animation(AppLayout.focusScaleAnimation, value: isFocused)
    .zIndex(isFocused ? 2 : 0)
  }
}
