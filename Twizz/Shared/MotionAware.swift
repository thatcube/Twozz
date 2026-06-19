import SwiftUI

extension AnyTransition {
  /// Returns `full` normally, or a plain cross-fade when Reduce Motion is on, so
  /// attention banners and toasts fade in/out instead of sliding for users who
  /// have asked the system to minimize motion.
  static func motionAware(_ full: AnyTransition, reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : full
  }
}

extension Animation {
  /// Returns `animation` normally, or `nil` when Reduce Motion is on, so the
  /// associated state change applies instantly instead of sliding/easing.
  static func motionAware(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }
}
