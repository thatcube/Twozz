import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

extension PlayerView {
  func submitChatMessage() {
    let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isSendingChat else { return }
    // Dismiss the tvOS keyboard overlay before sending.
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    isSendingChat = true
    chatSendError = nil
    Task {
      do {
        try await auth.sendChatMessage(text, toChannel: activeChannel)
        chatDraft = ""
        beginChatSyncSendIndicatorIfNeeded()
      } catch {
        chatSendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      isSendingChat = false
    }
  }

  /// When stream-sync is holding chat, a sent message won't appear until it
  /// reaches the delayed video. Show a short progress countdown so the user
  /// knows it was sent and roughly when it will surface.
  func beginChatSyncSendIndicatorIfNeeded() {
    guard chatSyncToStream, let delay = chatSyncDelaySeconds, delay >= 0.75 else {
      return
    }
    chatSyncSendClearTask?.cancel()
    chatSyncSendDelay = delay
    chatSyncSendDeadline = Date().addingTimeInterval(delay)
    chatSyncSendClearTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        chatSyncSendDeadline = nil
      }
    }
  }

  /// Placeholder/value shown in the highlight-keywords settings field.
  var highlightKeywordsDisplayText: String {
    let trimmed = chatHighlightKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Add keywords (optional)" : trimmed
  }

  /// The effective YouTube merge target shown in the settings input: the manual
  /// entry when present, otherwise the resolved default handle for the channel.
  var youtubeMergeDisplayText: String {    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    return youtubeMergeDefaultTarget.isEmpty
      ? "YouTube handle or channel URL" : youtubeMergeDefaultTarget
  }

  /// The handle the merge falls back to when no manual value is entered. Prefers
  /// the YouTube channel discovered from the Twitch channel's social links /
  /// description, and only guesses `@<twitch-login>` when nothing better exists.
  var youtubeMergeDefaultTarget: String {
    let auto = youtubeAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if !auto.isEmpty { return auto }
    let base = activeChannel.isEmpty ? channel : activeChannel
    return base.isEmpty ? "" : "@\(base)"
  }

  func applyExperimentalYouTubeSettings() {
    let manual = experimentalYouTubeMergeChannelOrURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let resolvedTarget = manual.isEmpty ? youtubeMergeDefaultTarget : manual

    chat.configureExperimentalYouTubeMerge(
      enabled: experimentalYouTubeMergeEnabled,
      channelOrURL: resolvedTarget
    )
  }

  /// Resolves the best YouTube target for the active channel and pushes it to the
  /// chat service. Runs whenever the active channel changes.
  func refreshYouTubeAutoTarget() async {
    let login = activeChannel
    guard !login.isEmpty else { return }
    let resolved = await Self.resolveYouTubeTarget(forTwitchLogin: login)
    guard login == activeChannel else { return }
    youtubeAutoResolvedTarget = resolved
    applyExperimentalYouTubeSettings()
  }

  /// Makes an educated guess at a channel's YouTube live source from its Twitch
  /// profile. Streamers often list several YouTube links (main channel, a VOD
  /// channel, a podcast, …), so we score each one against the streamer's Twitch
  /// identity instead of blindly taking the first. Falls back to a YouTube link
  /// in the bio, then a `@<twitch-login>` guess.
  static func resolveYouTubeTarget(forTwitchLogin login: String) async -> String {
    let fallback = "@\(login)"
    guard let profile = await ChannelProfileService.fetch(login: login) else {
      return fallback
    }

    if let best = bestYouTubeChannelURL(
      among: profile.socialLinks,
      twitchLogin: login,
      displayName: profile.displayName
    ) {
      return best
    }
    if let descLink = firstYouTubeChannelURL(in: profile.description ?? "") {
      return descLink
    }
    return fallback
  }

  /// Picks the YouTube channel link most likely to be the streamer's *primary*
  /// live channel. Returns nil when no candidate looks confident enough, so the
  /// caller can fall back rather than merge with the wrong channel (e.g. a
  /// podcast or clips channel the streamer also links).
  static func bestYouTubeChannelURL(
    among links: [ChannelSocialLink],
    twitchLogin: String,
    displayName: String
  ) -> String? {
    let candidates = links.filter { isYouTubeChannelURL($0.url) }
    guard !candidates.isEmpty else { return nil }

    let loginKey = normalizeIdentity(twitchLogin)
    let nameKey = normalizeIdentity(displayName)
    let secondaryMarkers = [
      "podcast", "vod", "vods", "clip", "clips", "shorts", "archive", "replay",
      "replays", "music", "topic", "highlight", "highlights", "fan", "second",
    ]

    func score(_ link: ChannelSocialLink) -> Int {
      var score = 0
      let handle = normalizeIdentity(youtubeHandle(from: link.url) ?? "")
      let label = link.title.lowercased()
      let haystack = "\(label) \(handle)"

      // Strongest signal: the YouTube handle matches the Twitch identity.
      if !handle.isEmpty {
        if handle == loginKey || (!nameKey.isEmpty && handle == nameKey) {
          score += 100
        } else if !loginKey.isEmpty, handle.contains(loginKey) {
          score += 60
        } else if nameKey.count >= 3, handle.contains(nameKey) {
          score += 50
        }
      }

      // The streamer labelled it as their main YouTube.
      if ["youtube", "youtube channel", "main", "main channel", "live"].contains(label) {
        score += 20
      }

      // Down-rank obvious secondary channels (podcasts, VOD/clip dumps, …).
      if secondaryMarkers.contains(where: { haystack.contains($0) }) {
        score -= 40
      }

      return score
    }

    let scored = candidates.map { ($0.url, score($0)) }
    guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
      return nil
    }
    return best.0
  }

  /// True for URLs that point at a YouTube *channel* (rather than a single video),
  /// e.g. `/@handle`, `/channel/UC…`, `/c/Name`, or `/user/Name`.
  static func isYouTubeChannelURL(_ string: String) -> Bool {
    let lower = string.lowercased()
    guard lower.contains("youtube.com") else { return false }
    return lower.contains("/@")
      || lower.contains("/channel/")
      || lower.contains("/c/")
      || lower.contains("/user/")
  }

  /// Extracts the channel handle / id segment from a YouTube channel URL.
  static func youtubeHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    let parts = comps.path.split(separator: "/").map(String.init)
    if let at = parts.first(where: { $0.hasPrefix("@") }) {
      return String(at.dropFirst())
    }
    if parts.count >= 2, ["channel", "c", "user"].contains(parts[0].lowercased()) {
      return parts[1]
    }
    return parts.first
  }

  /// Lowercases and strips everything but letters/digits for loose comparison.
  static func normalizeIdentity(_ raw: String) -> String {
    String(
      String.UnicodeScalarView(
        raw.lowercased().unicodeScalars.filter {
          CharacterSet.alphanumerics.contains($0)
        }))
  }

  static func firstYouTubeChannelURL(in text: String) -> String? {
    let separators = CharacterSet(charactersIn: " \n\t\r,;|()<>[]\"'")
    for raw in text.components(separatedBy: separators) {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, isYouTubeChannelURL(token) else { continue }
      return token
    }
    return nil
  }

  // MARK: - Experimental Kick merge

  /// Placeholder/value shown in the Kick merge settings input: the manual entry
  /// when present, otherwise the resolved default slug for the channel.
  var kickMergeDisplayText: String {
    let manual = experimentalKickMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    return kickMergeDefaultTarget.isEmpty
      ? "Kick handle or channel URL" : kickMergeDefaultTarget
  }

  /// The slug the merge falls back to when no manual value is entered. Prefers
  /// the Kick channel discovered from the Twitch channel's social links /
  /// description, and only guesses `<twitch-login>` when nothing better exists.
  var kickMergeDefaultTarget: String {
    let auto = kickAutoResolvedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if !auto.isEmpty { return auto }
    let base = activeChannel.isEmpty ? channel : activeChannel
    return base.isEmpty ? "" : base
  }

  func applyExperimentalKickSettings() {
    let manual = experimentalKickMergeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTarget = manual.isEmpty ? kickMergeDefaultTarget : manual

    chat.configureExperimentalKickMerge(
      enabled: experimentalKickMergeEnabled,
      channelOrURL: resolvedTarget
    )
  }

  /// Resolves the best Kick target for the active channel and pushes it to the
  /// chat service. Runs whenever the active channel changes.
  func refreshKickAutoTarget() async {
    let login = activeChannel
    guard !login.isEmpty else { return }
    await kickAliases.refreshIfNeeded()
    let alias = kickAliases.kickSlug(forTwitchLogin: login)
    let resolved = await Self.resolveKickTarget(forTwitchLogin: login, aliasSlug: alias)
    guard login == activeChannel else { return }
    kickAutoResolvedTarget = resolved
    applyExperimentalKickSettings()
  }

  /// Makes an educated guess at a channel's Kick source from its Twitch profile.
  ///
  /// Twitch surfaces YouTube links but routinely strips Kick (competitor) links,
  /// so we can't rely on an explicit Kick link being present. Instead we gather
  /// candidate slugs — an explicit Kick link if any, then the streamer's
  /// *consensus* handle reused across their other socials + display name, then
  /// the Twitch login — and verify each against Kick's channel API, preferring a
  /// channel that actually exists (and is live) over a blind login guess. This
  /// is what lets e.g. Twitch `zackrawrr` resolve to Kick `asmongold`.
  static func resolveKickTarget(forTwitchLogin login: String, aliasSlug: String?) async -> String {
    let fallback = login

    // A curated/CI-validated alias is authoritative for streamers whose Kick
    // name shares nothing with their Twitch identity (e.g. zackrawrr ->
    // asmongold), which profile-based guessing can't derive. Use it whenever the
    // aliased channel still exists.
    if let aliasSlug, !aliasSlug.isEmpty {
      if let info = try? await ChatService.fetchKickChannelInfo(slug: aliasSlug) {
        return info.slug
      }
    }

    guard let profile = await ChannelProfileService.fetch(login: login) else {
      return fallback
    }

    var candidates = kickSlugCandidates(
      login: login,
      displayName: profile.displayName,
      socialLinks: profile.socialLinks,
      description: profile.description
    )

    // Broaden coverage for streamers who neither reuse their name nor link Kick:
    // ask Kick's own search for their display name and login, folding in any
    // matches to be verified below.
    for term in [profile.displayName, login] {
      for slug in await ChatService.searchKickChannels(term: term) where !candidates.contains(slug) {
        candidates.append(slug)
      }
    }

    var firstExisting: String?
    for slug in candidates {
      let info: ChatService.KickChannelInfo?
      do {
        info = try await ChatService.fetchKickChannelInfo(slug: slug)
      } catch {
        continue
      }
      guard let info else { continue }
      if info.isLive { return info.slug }
      if firstExisting == nil { firstExisting = info.slug }
    }
    return firstExisting ?? fallback
  }

  /// Builds an ordered, de-duplicated list of Kick slug guesses for a streamer,
  /// strongest first: an explicit Kick link, then the handle they reuse most
  /// across their other social links and display name, then their Twitch login.
  static func kickSlugCandidates(
    login: String,
    displayName: String,
    socialLinks: [ChannelSocialLink],
    description: String?
  ) -> [String] {
    var ordered: [String] = []
    func add(_ raw: String?) {
      guard let raw else { return }
      let slug = normalizeKickSlug(raw)
      guard slug.count >= 2, !ordered.contains(slug) else { return }
      ordered.append(slug)
    }

    // 1. An explicit Kick link (profile panel or bio) is the strongest signal.
    if let kickURL = bestKickChannelURL(
      among: socialLinks, twitchLogin: login, displayName: displayName)
      ?? firstKickChannelURL(in: description ?? ""),
      let handle = kickHandle(from: kickURL)
    {
      add(handle)
    }

    // 2. Consensus handle: the brand name reused across the streamer's socials.
    var counts: [String: Int] = [:]
    var seen: [String] = []
    func tally(_ raw: String?) {
      guard let raw else { return }
      let key = normalizeKickSlug(raw)
      guard key.count >= 2 else { return }
      if counts[key] == nil { seen.append(key) }
      counts[key, default: 0] += 1
    }
    for link in socialLinks { tally(socialHandle(from: link.url)) }
    tally(displayName)
    for key in seen.sorted(by: { (counts[$0] ?? 0) > (counts[$1] ?? 0) }) { add(key) }

    // 3. The Twitch login as a final fall-back.
    add(login)

    return ordered
  }

  /// Extracts a likely account handle from an arbitrary social URL (X, YouTube,
  /// Instagram, TikTok, …) so it can be compared across platforms.
  static func socialHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    let parts = comps.path.split(separator: "/").map(String.init)
    if let at = parts.first(where: { $0.hasPrefix("@") }) {
      return String(at.dropFirst())
    }
    let skip: Set<String> = ["channel", "c", "user", "invite", "intent", "watch", "playlist"]
    guard let first = parts.first else { return nil }
    if skip.contains(first.lowercased()), parts.count >= 2 { return parts[1] }
    return first
  }

  /// Lowercases and keeps only characters valid in a Kick slug.
  static func normalizeKickSlug(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
    return String(raw.lowercased().filter { allowed.contains($0) })
  }

  /// Picks the Kick channel link most likely to be the streamer's primary live
  /// channel. Returns nil when no candidate looks confident enough, so the
  /// caller can fall back rather than merge with the wrong channel.
  static func bestKickChannelURL(
    among links: [ChannelSocialLink],
    twitchLogin: String,
    displayName: String
  ) -> String? {
    let candidates = links.filter { isKickChannelURL($0.url) }
    guard !candidates.isEmpty else { return nil }

    let loginKey = normalizeIdentity(twitchLogin)
    let nameKey = normalizeIdentity(displayName)
    let secondaryMarkers = [
      "clip", "clips", "vod", "vods", "archive", "replay", "replays",
      "highlight", "highlights", "fan", "second",
    ]

    func score(_ link: ChannelSocialLink) -> Int {
      var score = 0
      let handle = normalizeIdentity(kickHandle(from: link.url) ?? "")
      let label = link.title.lowercased()
      let haystack = "\(label) \(handle)"

      if !handle.isEmpty {
        if handle == loginKey || (!nameKey.isEmpty && handle == nameKey) {
          score += 100
        } else if !loginKey.isEmpty, handle.contains(loginKey) {
          score += 60
        } else if nameKey.count >= 3, handle.contains(nameKey) {
          score += 50
        }
      }

      if ["kick", "kick channel", "main", "main channel", "live"].contains(label) {
        score += 20
      }
      if secondaryMarkers.contains(where: { haystack.contains($0) }) {
        score -= 40
      }

      return score
    }

    let scored = candidates.map { ($0.url, score($0)) }
    guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
      return nil
    }
    return best.0
  }

  /// True for URLs that point at a Kick channel, e.g. `kick.com/<slug>`.
  static func isKickChannelURL(_ string: String) -> Bool {
    let lower = string.lowercased()
    guard lower.contains("kick.com") else { return false }
    let normalized = lower.contains("://") ? lower : "https://\(lower)"
    guard let comps = URLComponents(string: normalized) else { return false }
    return !comps.path.split(separator: "/").isEmpty
  }

  /// Extracts the channel slug from a Kick channel URL.
  static func kickHandle(from urlString: String) -> String? {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let comps = URLComponents(string: normalized) else { return nil }
    return comps.path.split(separator: "/").map(String.init).first
  }

  static func firstKickChannelURL(in text: String) -> String? {
    let separators = CharacterSet(charactersIn: " \n\t\r,;|()<>[]\"'")
    for raw in text.components(separatedBy: separators) {
      let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, isKickChannelURL(token) else { continue }
      return token
    }
    return nil
  }

  /// The delay to hold chat by so it lines up with the on-screen video.
  ///
  /// This must be the *broadcast* (glass-to-glass) latency, i.e. how far behind
  /// real time the picture is — which is exactly what the wall-clock estimate
  /// (`now − EXT-X-PROGRAM-DATE-TIME`) measures. The live-edge value is only the
  /// small in-buffer gap to the playlist edge (a few seconds) and would leave
  /// chat running far ahead, so it's not used for syncing.
  var chatSyncDelaySeconds: Double? {
    wallClockLatencySeconds
  }

  /// Push the current sync preference + measured latency into the chat service.
  /// Called when the toggle changes and on each latency sample.
  func applyChatSyncSettings() {
    chat.configureChatSync(
      enabled: chatSyncToStream,
      delaySeconds: chatSyncDelaySeconds ?? 0
    )
  }
}
