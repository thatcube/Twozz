import Foundation

/// IRC-over-WebSocket transport and line parsing for `ChatService`: the receive
/// loop, command sending, and tokenizing raw IRC frames (PRIVMSG, USERNOTICE,
/// CAP/JOIN handshake, PING/PONG, raid notices) into `ChatMessage`s.
extension ChatService {
  /// The anonymous (`justinfan`) login handshake. Sent on every fresh socket —
  /// the first connect, an auto-reconnect after a receive error, and the rebuild
  /// after the app returns from the background.
  func sendIRCHandshake() {
    send("PASS SCHMOOPIIE")
    send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
    send("CAP REQ :twitch.tv/tags twitch.tv/commands")
  }

  func sendJoinIfNeeded() {
    guard !hasSentJoin, let channel else { return }
    send("JOIN #\(channel)")
    hasSentJoin = true
  }

  func send(_ command: String) {
    connection.send(.string(command + "\r\n"))
  }

  func receiveLoop() async {
    while !Task.isCancelled {
      guard let currentSocket = connection.currentTask else { break }
      do {
        let frame = try await currentSocket.receive()
        connection.resetBackoff()
        switch frame {
        case .string(let text): await handle(text)
        case .data(let data): await handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        guard !Task.isCancelled else { break }
        isConnected = false

        // Reconnect with exponential backoff (3s, 6s, 12s… capped at 30s),
        // preserving the message buffer.
        guard let channelToRejoin = channel else { break }
        let delay = connection.nextBackoffDelay()
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, channel == channelToRejoin else { break }

        connection.connect(to: endpoint)
        hasSentJoin = false
        hasCapAck = false
        sendIRCHandshake()
        // Loop continues — next iteration receives on the new socket.
      }
    }
  }

  func handle(_ raw: String) async {
    // A single frame can batch multiple IRC lines. Control lines (PING/PONG,
    // CAP/JOIN handshake, end-of-NAMES, raids) touch connection state and stay on
    // the main actor — they're cheap and rare. The expensive PRIVMSG/USERNOTICE
    // lines are handed to the serial background pipeline, which parses them into
    // `ChatMessage`s and computes their `segments` off the main actor before we
    // enqueue the finished batch.
    var messagePieces: [String] = []
    for piece in raw.components(separatedBy: "\r\n") where !piece.isEmpty {
      if piece.hasPrefix("PING") {
        send("PONG :tmi.twitch.tv")
        continue
      }
      if piece.contains(" CAP ") && piece.contains(" ACK ") && piece.contains("twitch.tv/tags") {
        hasCapAck = true
        sendJoinIfNeeded()
        continue
      }
      if piece.contains(" 366 ") {  // end-of-NAMES => join confirmed
        isConnected = true
        continue
      }
      if let raid = parseRaidEvent(from: piece) {
        pendingRaid = raid
        continue
      }
      messagePieces.append(piece)
    }

    guard !messagePieces.isEmpty else { return }
    let parsedMessages = await ingestPipeline.parseAndTokenize(messagePieces)
    guard !parsedMessages.isEmpty else { return }
    enqueue(parsedMessages)
  }

  /// Parse a Twitch USERNOTICE line for `msg-id=raid` and return a `RaidEvent`.
  private func parseRaidEvent(from line: String) -> RaidEvent? {
    // Line format:
    //   @tags :tmi.twitch.tv USERNOTICE #channel [:message]
    guard line.contains(" USERNOTICE ") else { return nil }

    // Extract tags section.
    var tags: [String: String] = [:]
    if line.first == "@", let spaceIdx = line.firstIndex(of: " ") {
      let tagString = line[line.index(after: line.startIndex)..<spaceIdx]
      for pair in tagString.split(separator: ";") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if kv.count == 2 { tags[String(kv[0])] = String(kv[1]) }
        else if kv.count == 1 { tags[String(kv[0])] = "" }
      }
    }

    guard tags["msg-id"] == "raid" else { return nil }

    let login = tags["msg-param-login"] ?? ""
    let displayName = tags["msg-param-displayName"] ?? login
    let viewerCount = Int(tags["msg-param-viewerCount"] ?? "0") ?? 0
    guard !login.isEmpty else { return nil }

    return RaidEvent(login: login, displayName: displayName, viewerCount: viewerCount)
  }
}
