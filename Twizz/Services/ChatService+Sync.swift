import Foundation

/// Deterministic, allocation-free tiebreak between two message UUIDs. The sort
/// tiebreakers below only need a stable, reproducible order for messages that
/// share a timestamp; comparing the raw 16 bytes does that without allocating
/// the two 36-character `uuidString`s the previous `<` comparison built on every
/// tie.
private func uuidPrecedes(_ a: UUID, _ b: UUID) -> Bool {
  withUnsafeBytes(of: a.uuid) { pa in
    withUnsafeBytes(of: b.uuid) { pb in
      for i in 0..<16 where pa[i] != pb[i] { return pa[i] < pb[i] }
      return false
    }
  }
}

/// Stream-sync delay and message-release scheduling for `ChatService`: holds
/// incoming messages so chat lines up with the delayed video, eases the delay in
/// during a warm-up window, trickles large bursts in so they read like live
/// chat, and drains/flushes the pending buffer into the visible message list.
extension ChatService {
  struct PendingChatMessage {
    let message: ChatMessage
    let releaseAt: Date
  }

  /// Sync delay actually applied right now. Eases from 0 up to the full
  /// `chatSyncDelaySeconds` over `chatSyncWarmupSeconds` after a fresh connect,
  /// so live messages from both platforms surface almost immediately at the
  /// start and gradually settle into video-sync.
  private func effectiveSyncDelay(now: Date) -> Double {
    guard chatSyncEnabled else { return 0 }
    let full = chatSyncDelaySeconds
    guard let start = syncWarmupStart, chatSyncWarmupSeconds > 0 else { return full }
    let progress = min(max(now.timeIntervalSince(start) / chatSyncWarmupSeconds, 0), 1)
    return full * progress
  }

  func enqueue(_ incoming: [ChatMessage]) {
    let sorted = incoming.sorted { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return uuidPrecedes(lhs.id, rhs.id)
      }
      return lhs.timestamp < rhs.timestamp
    }

    guard chatSyncEnabled, chatSyncDelaySeconds >= chatSyncMinDelaySeconds else {
      appendVisible(sorted)
      return
    }

    let now = Date()
    let delay = effectiveSyncDelay(now: now)
    // The synced playhead at full delay; anything older is true scrollback.
    let fullPlayhead = now.addingTimeInterval(-chatSyncDelaySeconds)

    var immediate: [ChatMessage] = []
    var backlog: [ChatMessage] = []
    // Never hold a message longer than the (effective) delay: a future clock
    // skew on a server timestamp must not push a genuinely-live message past
    // the playhead. (Past/old timestamps already fall through to immediate.)
    let maxReleaseAt = now.addingTimeInterval(delay)
    for message in sorted {
      let releaseAt = min(message.timestamp.addingTimeInterval(delay), maxReleaseAt)
      if releaseAt > now {
        syncBuffer.append(PendingChatMessage(message: message, releaseAt: releaseAt))
      } else if message.timestamp < fullPlayhead {
        // Behind the synced playhead: old scrollback, subject to the cap.
        backlog.append(message)
      } else {
        // In-window or live but releasable now (e.g. during warm-up): always show.
        immediate.append(message)
      }
    }

    // Cap the scrollback dump to the most recent few so the panel seeds with
    // recent context instead of a wall of history.
    if backlog.count > maxImmediateBacklogMessages {
      backlog.removeFirst(backlog.count - maxImmediateBacklogMessages)
    }

    let visibleNow = (backlog + immediate).sorted { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return uuidPrecedes(lhs.id, rhs.id)
      }
      return lhs.timestamp < rhs.timestamp
    }
    scheduleImmediate(visibleNow, now: now)

    if !syncBuffer.isEmpty {
      // Keep release order correct even when immediate + delayed messages
      // interleave across enqueue calls.
      syncBuffer.sort { lhs, rhs in
        if lhs.releaseAt == rhs.releaseAt {
          if lhs.message.timestamp == rhs.message.timestamp {
            return uuidPrecedes(lhs.message.id, rhs.message.id)
          }
          return lhs.message.timestamp < rhs.message.timestamp
        }
        return lhs.releaseAt < rhs.releaseAt
      }
      pendingSyncMessageCount = syncBuffer.count
      startSyncDrainIfNeeded()
    }
  }

  /// Surfaces a batch that is releasable right now. Small batches appear
  /// instantly; a large fill (typically the connect-time backlog + in-window
  /// burst while the warm-up delay is still ~0) is trickled in over a short
  /// window via the sync buffer so it reads like live chat instead of a wall.
  private func scheduleImmediate(_ messages: [ChatMessage], now: Date) {
    guard !messages.isEmpty else { return }
    if messages.count <= immediateTrickleThreshold {
      appendVisible(messages)
      return
    }
    let perMessage = max(
      immediateTrickleWindowSeconds / Double(messages.count),
      immediateTrickleMinIntervalSeconds
    )
    for (index, message) in messages.enumerated() {
      let releaseAt = now.addingTimeInterval(perMessage * Double(index))
      syncBuffer.append(PendingChatMessage(message: message, releaseAt: releaseAt))
    }
  }

  private func appendVisible(_ sorted: [ChatMessage]) {
    guard !sorted.isEmpty else { return }
    var tokenized = sorted
    for index in tokenized.indices {
      tokenized[index].segments = computeSegments(for: tokenized[index])
    }
    messages.append(contentsOf: tokenized)
    if messages.count > maxBufferedMessages {
      messages.removeFirst(messages.count - maxBufferedMessages)
    }
  }

  private func startSyncDrainIfNeeded() {
    guard syncDrainTask == nil else { return }
    syncDrainTask = Task { [weak self] in
      await self?.drainSyncBuffer()
    }
  }

  /// Releases held messages to the visible buffer as each one's delay elapses,
  /// preserving arrival order.
  private func drainSyncBuffer() async {
    while !Task.isCancelled {
      guard let next = syncBuffer.first else { break }

      let now = Date()
      if next.releaseAt > now {
        try? await Task.sleep(for: .seconds(next.releaseAt.timeIntervalSince(now)))
        if Task.isCancelled { return }
        continue
      }

      var released: [ChatMessage] = []
      while let first = syncBuffer.first, first.releaseAt <= now {
        released.append(first.message)
        syncBuffer.removeFirst()
      }
      appendVisible(released)
      pendingSyncMessageCount = syncBuffer.count
    }
    syncDrainTask = nil
  }

  /// Immediately surfaces every held message (used when sync is turned off or
  /// the connection tears down) so no message is dropped.
  func flushSyncBuffer() {
    syncDrainTask?.cancel()
    syncDrainTask = nil
    guard !syncBuffer.isEmpty else {
      pendingSyncMessageCount = 0
      return
    }
    let pending = syncBuffer.map(\.message)
    syncBuffer.removeAll()
    pendingSyncMessageCount = 0
    appendVisible(pending)
  }
}
