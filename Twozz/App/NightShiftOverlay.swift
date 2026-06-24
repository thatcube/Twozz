import SwiftUI
import UIKit

/// Installs Night Shift's warm wash so it floats above *everything* — including
/// the player and other `fullScreenCover`s — without ever stealing focus.
///
/// Why a separate `UIWindow` rather than a SwiftUI `.overlay`: the player, chat,
/// multiview, and sign-in screens are all presented as full-screen covers, which
/// sit in their own presentation context above `HomeView`'s view tree. An overlay
/// attached inside `HomeView` would be covered by them (and wouldn't tint the
/// video at all). A dedicated passthrough window at a high window level is the one
/// place that reliably sits on top of the whole app, mirroring how the system's
/// own Night Shift covers the entire screen.

// MARK: - Passthrough window

/// A window that never intercepts touches or focus — it only paints. Returning
/// `nil` from `hitTest` keeps the tvOS focus engine from ever routing to it, so
/// it's purely cosmetic.
private final class NightShiftOverlayWindow: UIWindow {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

// MARK: - Tint view

/// The SwiftUI content the overlay window hosts: a black **dimming** layer (true
/// brightness reduction — keeps blacks black) with a translucent **warm** layer
/// on top for the color cast. Splitting them lets Dimness and Warmth be adjusted
/// independently. `allowsHitTesting(false)` is belt-and-braces alongside the
/// window's `hitTest` override.
private struct NightShiftTintView: View {
  var manager: NightShiftManager

  var body: some View {
    ZStack {
      manager.currentWarmTint
        .opacity(manager.currentWarmOpacity)
      Color.black
        .opacity(manager.currentDimOpacity)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.6), value: manager.currentDimOpacity)
    .animation(.easeInOut(duration: 0.6), value: manager.currentWarmOpacity)
    .animation(.easeInOut(duration: 0.6), value: manager.warmth)
  }
}

// MARK: - Installer

/// Creates the overlay window once a window scene is available and keeps it alive
/// for the app's lifetime. It lives as a hidden representable inside the root view
/// purely so SwiftUI gives it a lifecycle hook; the actual window is attached to
/// the active `UIWindowScene`, retrying until the scene has connected (the scene
/// is often not ready on the very first layout pass).
private struct NightShiftOverlayInstaller: UIViewRepresentable {
  var manager: NightShiftManager

  func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

  func makeUIView(context: Context) -> UIView {
    let probe = UIView(frame: .zero)
    probe.isHidden = true
    context.coordinator.installIfNeeded()
    return probe
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    context.coordinator.installIfNeeded()
  }

  @MainActor
  final class Coordinator {
    private let manager: NightShiftManager
    private var overlayWindow: UIWindow?
    private var attempts = 0

    init(manager: NightShiftManager) {
      self.manager = manager
    }

    func installIfNeeded() {
      guard overlayWindow == nil else { return }

      guard let scene = Self.activeWindowScene() else {
        // The scene can lag the first few layout passes — retry briefly.
        attempts += 1
        guard attempts < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          self?.installIfNeeded()
        }
        return
      }

      let window = NightShiftOverlayWindow(windowScene: scene)
      window.frame = UIScreen.main.bounds
      window.backgroundColor = .clear
      window.isUserInteractionEnabled = false
      // Above alerts and full-screen covers so the wash covers the whole app.
      window.windowLevel = .alert + 1

      let host = UIHostingController(rootView: NightShiftTintView(manager: manager))
      host.view.backgroundColor = .clear
      host.view.isUserInteractionEnabled = false
      window.rootViewController = host
      window.isHidden = false

      overlayWindow = window
    }

    private static func activeWindowScene() -> UIWindowScene? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
  }
}

extension View {
  /// Attaches the global Night Shift warm-wash overlay window.
  func installNightShiftOverlay(_ manager: NightShiftManager) -> some View {
    background(NightShiftOverlayInstaller(manager: manager))
  }
}
