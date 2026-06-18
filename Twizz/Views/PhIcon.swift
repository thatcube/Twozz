import SwiftUI

/// Phosphor icons we use, vendored as template SVGs in `Assets.xcassets/Phosphor`.
///
/// Only the icons actually referenced in the UI are bundled (rather than the
/// full ~9,000-image Phosphor package) so the asset catalog stays tiny and
/// clean builds stay fast. Each icon ships its `regular` (unfilled) outline and,
/// where we toggle state, a matching `fill` variant.
///
/// To add an icon: drop `<name>.svg` (and optionally `<name>-fill.svg`) from
/// phosphor-icons into `Assets.xcassets/Phosphor` as `ph-<name>` template
/// imagesets, then add a case here whose raw value is `<name>`.
enum Ph: String {
  case play
  case userCircle = "user-circle"
  case userCirclePlus = "user-circle-plus"
  case cards
  case check
  case caretLeft = "caret-left"
  case checkCircle = "check-circle"
  case faders
  case heart
  case sidebarSimple = "sidebar-simple"
  case chatCircle = "chat-circle"
  case x
  case paperPlaneTilt = "paper-plane-tilt"
  case clockCountdown = "clock-countdown"
}

/// Renders a vendored Phosphor icon as a template image so it tints with the
/// current `foregroundStyle` and adapts to tvOS focus exactly like an SF Symbol.
///
/// Toggle `filled` to switch between the outline and solid variants for state
/// changes (e.g. an outline heart when not following, a solid heart when
/// following). Only icons whose `-fill` asset is bundled may set `filled: true`.
struct PhIcon: View {
  let icon: Ph
  var filled: Bool = false
  var size: CGFloat

  private var assetName: String {
    "ph-\(icon.rawValue)\(filled ? "-fill" : "")"
  }

  var body: some View {
    Image(assetName)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}
