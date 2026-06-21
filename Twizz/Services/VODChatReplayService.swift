import Foundation
import Observation

/// Drives a Twitch-style **VOD chat replay**: as a past broadcast plays back,
/// it surfaces the chat messages that were posted at (or before) the current
/// playback offset, exactly like the chat column on a Twitch VOD page.
///
/// Comments are read anonymously from Twitch's public GraphQL endpoint using the
/// same web client-id the rest of the app uses for playback. We page purely by
/// `contentOffsetSeconds` because Twitch's cursor (`after:`) pagination is
/// integrity-gated for anonymous clients, whereas the offset form is not.
@MainActor
@Observable
final class VODChatReplayService {
  /// Messages currently visible for the playhead (oldest first), capped to a
  /// rolling window so the list stays light on tvOS.
  private(set) var messages: [ChatMessage] = []
  /// Channel emote catalog (Twitch + 7TV/BTTV/FFZ), keyed by emote token.
  private(set) var emoteURLs: [String: URL] = [:]
  /// Channel + global badge catalog, keyed by `setID/version`.
  private(set) var badgeURLs: [String: URL] = [:]
  /// Channel + global cheermotes, so cheers in VOD comments render like Twitch.
  private(set) var cheermotes: [Cheermote] = []
  /// True once the first page of comments has resolved (success or empty), so
  /// the UI can drop its "loading replay" state.
  private(set) var isReady = false

  private struct Entry {
    let offset: Double
    let key: String
    let message: ChatMessage
  }

  private var buffer: [Entry] = []
  private var seenKeys: Set<String> = []

  private var vodID = ""
  private var fetchTask: Task<Void, Never>?
  private var catalogTask: Task<Void, Never>?

  /// Lowest / highest comment offset (seconds) currently held — the contiguous
  /// region we've fetched. Used to detect seeks that land outside it.
  private var coverageStart: Double = 0
  private var coverageEnd: Double = 0
  /// Next `contentOffsetSeconds` to request when paging forward.
  private var nextFetchOffset = 0
  private var hasMore = true
  private var currentOffset: Double = 0

  private let maxVisible = 120
  private let maxBuffer = 4000
  /// Start fetching the next page once the playhead gets this close to the
  /// frontier of what we've loaded.
  private let prefetchAheadSeconds: Double = 25
  /// A forward jump beyond the loaded frontier by more than this rebuilds the
  /// window at the new offset rather than paging through the gap.
  private let forwardSeekResetGap: Double = 90

  private let clientID = TwitchConfig.webPublicClientID
  private let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

  /// Begin a replay session for a VOD. Loads the emote/badge catalogs for the
  /// owning channel and fetches the first page of comments from offset 0.
  func start(vodID: String, channelLogin: String?) {
    guard self.vodID != vodID else { return }
    stop()

    self.vodID = vodID
    isReady = false
    buffer = []
    seenKeys = []
    messages = []
    emoteURLs = [:]
    badgeURLs = [:]
    cheermotes = []
    coverageStart = 0
    coverageEnd = 0
    nextFetchOffset = 0
    hasMore = true
    currentOffset = 0

    if let login = channelLogin?.lowercased(), !login.isEmpty {
      catalogTask = Task { [weak self] in
        async let emotes = EmoteCatalogService.shared.catalog(for: login)
        async let badges = BadgeCatalogService.shared.catalog(for: login)
        async let cheers = CheermoteCatalogService.shared.catalog(for: login)
        let (resolvedEmotes, resolvedBadges, resolvedCheers) = await (emotes, badges, cheers)
        guard let self, !Task.isCancelled, self.vodID == vodID else { return }
        self.emoteURLs = resolvedEmotes
        self.badgeURLs = resolvedBadges
        self.cheermotes = resolvedCheers
      }
    }

    fetchMore(from: 0)
  }

  func stop() {
    fetchTask?.cancel()
    catalogTask?.cancel()
    fetchTask = nil
    catalogTask = nil
    vodID = ""
  }

  /// Advance the replay to the player's current playback offset (seconds).
  func update(toOffset offset: Double) {
    guard !vodID.isEmpty else { return }
    currentOffset = max(0, offset)

    if currentOffset < coverageStart - 1 || currentOffset > coverageEnd + forwardSeekResetGap {
      resetWindow(at: currentOffset)
    } else if hasMore, fetchTask == nil, currentOffset > coverageEnd - prefetchAheadSeconds {
      fetchMore(from: nextFetchOffset)
    }

    recomputeVisible()
  }

  private func resetWindow(at offset: Double) {
    fetchTask?.cancel()
    fetchTask = nil
    buffer = []
    seenKeys = []
    let start = max(0, Int(offset) - 2)
    coverageStart = Double(start)
    coverageEnd = Double(start)
    nextFetchOffset = start
    hasMore = true
    fetchMore(from: start)
  }

  private func recomputeVisible() {
    let visible = buffer.filter { $0.offset <= currentOffset }
    if visible.count > maxVisible {
      messages = visible.suffix(maxVisible).map(\.message)
    } else {
      messages = visible.map(\.message)
    }
  }

  private func fetchMore(from offset: Int) {
    guard fetchTask == nil, !vodID.isEmpty else { return }
    let id = vodID
    let client = clientID
    let agent = userAgent
    fetchTask = Task { [weak self] in
      let page = await Self.fetchComments(
        vodID: id, offset: offset, clientID: client, userAgent: agent)
      guard let self, !Task.isCancelled, self.vodID == id else { return }
      self.fetchTask = nil
      self.ingest(page, requestedOffset: offset)
    }
  }

  private func ingest(_ page: CommentPage?, requestedOffset: Int) {
    isReady = true

    guard let page else {
      // Network/parse failure: leave the frontier where it is. A later
      // `update` near the edge will retry the same offset.
      return
    }

    var newCount = 0
    for comment in page.comments {
      let key = "\(Int(comment.offset))|\(comment.login)|\(comment.text)"
      if seenKeys.contains(key) { continue }
      seenKeys.insert(key)
      buffer.append(Entry(offset: comment.offset, key: key, message: comment.message))
      newCount += 1
    }

    if newCount > 0 {
      buffer.sort { $0.offset < $1.offset }
      coverageStart = buffer.first?.offset ?? coverageStart
      coverageEnd = buffer.last?.offset ?? coverageEnd
      nextFetchOffset = Int(coverageEnd)
    } else if page.hasNextPage {
      // The page was entirely comments we already had (a single second busier
      // than one page). Step forward so we don't spin on the same offset.
      nextFetchOffset = requestedOffset + 2
    }

    hasMore = page.hasNextPage

    if buffer.count > maxBuffer {
      buffer.removeFirst(buffer.count - maxBuffer)
      seenKeys = Set(buffer.map(\.key))
      coverageStart = buffer.first?.offset ?? coverageStart
    }

    recomputeVisible()

    // Still buffering toward a playhead that's ahead of the loaded frontier
    // (e.g. right after a seek): keep paging until we catch up.
    if hasMore, fetchTask == nil, coverageEnd < currentOffset - 1 {
      fetchMore(from: nextFetchOffset)
    }
  }

  // MARK: - Networking

  private struct ParsedComment {
    let offset: Double
    let login: String
    let text: String
    let message: ChatMessage
  }

  private struct CommentPage {
    let comments: [ParsedComment]
    let hasNextPage: Bool
  }

  private nonisolated static func fetchComments(
    vodID: String, offset: Int, clientID: String, userAgent: String
  ) async -> CommentPage? {
    var request = TwitchAPIClient.graphQLRequest(
      clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)

    let query = """
      query($id: ID!, $o: Int) { video(id: $id) { comments(contentOffsetSeconds: $o) { \
      edges { node { contentOffsetSeconds commenter { displayName login } \
      message { userColor userBadges { setID version } fragments { text emote { emoteID } } } } } \
      pageInfo { hasNextPage } } } }
      """
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(
        query: query, variables: ["id": vodID, "o": offset]))

    guard let (data, response) = try? await NetworkClient.api.data(for: request) else { return nil }
    guard TwitchAPIClient.isSuccess(response) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dataObj = json["data"] as? [String: Any],
      let video = dataObj["video"] as? [String: Any],
      let comments = video["comments"] as? [String: Any]
    else { return nil }

    let edges = comments["edges"] as? [[String: Any]] ?? []
    let pageInfo = comments["pageInfo"] as? [String: Any]
    let hasNextPage = pageInfo?["hasNextPage"] as? Bool ?? false

    var parsed: [ParsedComment] = []
    parsed.reserveCapacity(edges.count)
    for edge in edges {
      guard let node = edge["node"] as? [String: Any],
        let comment = parseComment(node)
      else { continue }
      parsed.append(comment)
    }

    return CommentPage(comments: parsed, hasNextPage: hasNextPage)
  }

  private nonisolated static func parseComment(_ node: [String: Any]) -> ParsedComment? {
    let offset: Double
    if let intValue = node["contentOffsetSeconds"] as? Int {
      offset = Double(intValue)
    } else if let doubleValue = node["contentOffsetSeconds"] as? Double {
      offset = doubleValue
    } else {
      return nil
    }

    let commenter = node["commenter"] as? [String: Any]
    let login = (commenter?["login"] as? String) ?? ""
    let display = (commenter?["displayName"] as? String)
      .flatMap { $0.isEmpty ? nil : $0 } ?? login
    guard !display.isEmpty else { return nil }

    let messageObj = node["message"] as? [String: Any]

    let color = (messageObj?["userColor"] as? String).flatMap { $0.isEmpty ? nil : $0 }

    var badgeKeys: [String] = []
    if let badges = messageObj?["userBadges"] as? [[String: Any]] {
      for badge in badges {
        guard let setID = badge["setID"] as? String, !setID.isEmpty else { continue }
        let version = (badge["version"] as? String) ?? "1"
        badgeKeys.append("\(setID)/\(version)")
      }
    }

    var text = ""
    var emoteURLs: [String: URL] = [:]
    if let fragments = messageObj?["fragments"] as? [[String: Any]] {
      for fragment in fragments {
        let fragmentText = (fragment["text"] as? String) ?? ""
        text += fragmentText
        if let emote = fragment["emote"] as? [String: Any],
          let emoteID = emote["emoteID"] as? String,
          !fragmentText.isEmpty,
          let url = URL(
            string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteID)/default/dark/2.0")
        {
          emoteURLs[fragmentText] = url
        }
      }
    }

    guard !text.isEmpty else { return nil }

    let message = ChatMessage(
      username: display,
      colorHex: color,
      badgeKeys: badgeKeys,
      text: text,
      twitchEmoteURLs: emoteURLs,
      youtubeEmoteURLs: [:],
      isAction: false,
      source: .twitch,
      timestamp: Date()
    )

    return ParsedComment(offset: offset, login: login, text: text, message: message)
  }
}
