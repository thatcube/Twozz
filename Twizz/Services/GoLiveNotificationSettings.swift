import Foundation
import Observation

/// User-facing preference keys for the in-app "just went live" toast. Kept in a
/// non-isolated enum so SwiftUI `@AppStorage` and other call sites can reference
/// the keys without touching the `@MainActor`-isolated store.
///
/// tvOS has no system notifications, so these alerts are **in-app only** — they
/// surface as the existing `GoLiveToastView` and never as banners, badges, or
/// sounds, and they don't affect Twitch notifications on the viewer's other
/// devices.
enum GoLiveNotificationPreferences {
  /// Master on/off for go-live toasts. Defaults to enabled.
  static let enabledKey = "goLiveNotificationsEnabled"
  /// Lowercased logins the viewer has muted (opt-out model). Stored as `[String]`.
  static let mutedLoginsKey = "goLiveMutedChannelsV1"
}

/// On-device store for which followed channels may surface a go-live toast.
///
/// Model is **opt-out**: by default every followed channel alerts, and the viewer
/// mutes the ones they don't want. The muted set is keyed by lowercased login to
/// match `GoLiveWatcher`'s identity model (`GoLiveEvent.id == login`). A channel
/// rename harmlessly reverts that channel to alerting.
///
/// Everything lives only in this device's `UserDefaults`; nothing is transmitted.
@MainActor
@Observable
final class GoLiveNotificationSettings {
  /// Master switch, mirrored from `UserDefaults` so the Settings `@AppStorage`
  /// toggle and this store always agree. Defaults to on.
  var isEnabled: Bool {
    get {
      UserDefaults.standard.object(forKey: GoLiveNotificationPreferences.enabledKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: GoLiveNotificationPreferences.enabledKey)
    }
  }

  /// Lowercased logins the viewer has muted.
  private(set) var mutedLogins: Set<String> = []

  init() {
    load()
  }

  /// Whether a go-live toast for `login` should be shown right now: the master
  /// switch is on **and** the channel isn't muted.
  func isAlerting(login: String) -> Bool {
    isEnabled && !mutedLogins.contains(login.lowercased())
  }

  /// Whether `login` is individually muted (independent of the master switch).
  func isMuted(login: String) -> Bool {
    mutedLogins.contains(login.lowercased())
  }

  /// Turn per-channel alerts on/off for `login` and persist.
  func setAlerting(_ on: Bool, login: String) {
    let key = login.lowercased()
    guard !key.isEmpty else { return }
    if on {
      guard mutedLogins.contains(key) else { return }
      mutedLogins.remove(key)
    } else {
      guard !mutedLogins.contains(key) else { return }
      mutedLogins.insert(key)
    }
    persist()
  }

  private func load() {
    let stored = UserDefaults.standard.stringArray(forKey: GoLiveNotificationPreferences.mutedLoginsKey) ?? []
    mutedLogins = Set(stored.map { $0.lowercased() })
  }

  private func persist() {
    UserDefaults.standard.set(
      Array(mutedLogins).sorted(), forKey: GoLiveNotificationPreferences.mutedLoginsKey)
  }
}
