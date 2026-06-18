import SwiftUI

/// Tabler icons (MIT) we use, vendored as template SVGs in
/// `Assets.xcassets/Tabler`.
///
/// Only the icons actually referenced in the UI are bundled (rather than
/// pulling Tabler's full library) so the asset catalog stays tiny and clean
/// builds stay fast. Filled variants are distinct glyphs (e.g. `.heartFilled`)
/// rather than a flag, mirroring how Tabler ships outline and filled sets.
///
/// To add an icon: drop the SVG from tabler-icons into `Assets.xcassets/Tabler`
/// as a `tb-<name>` template imageset, then add a case here whose raw value is
/// `<name>`.
enum Glyph: String {
  case chevronLeft = "chevron-left"
  case adjustmentsHorizontal = "adjustments-horizontal"
  case x
  case check
  case heart
  case heartFilled = "heart-filled"
  case userCircle = "user-circle"
  case userPlus = "user-plus"
  case cards
  case clock
  case send
  case sidebarRightExpand = "layout-sidebar-right-expand"
  case sidebarRightCollapse = "layout-sidebar-right-collapse"
  case circleCheckFilled = "circle-check-filled"
  case playerPlayFilled = "player-play-filled"
}

/// Renders a vendored Tabler icon as a template image so it tints with the
/// current `foregroundStyle` and adapts to tvOS focus exactly like an SF Symbol.
struct Icon: View {
  /// Shared size for the player's overlay control buttons so every button reads
  /// at a consistent weight and footprint.
  static let controlButtonSize: CGFloat = 40

  let glyph: Glyph
  var size: CGFloat = Icon.controlButtonSize

  var body: some View {
    Image("tb-\(glyph.rawValue)")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}
