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

  /// Attach segments off the main actor (via the ingest pipeline), then enqueue.
  /// Used by the YouTube/Kick merge paths, whose `ChatMessage`s are built from
  /// JSON without precomputed segments, so their tokenization stays off the
  /// scroll thread like the Twitch IRC path.
  func enqueueTokenized(_ incoming: [ChatMessage]) async {
    guard !incoming.isEmpty else { return }
    let tokenized = await ingestPipeline.tokenize(incoming)
    enqueue(tokenized)
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

  /// Funnels a releasable batch into the observable list through the adaptive
  /// coalescer. Segments are already attached upstream (the background pipeline);
  /// the rare message that arrives without them (e.g. a producer that bypassed
  /// the pipeline) is tokenized here as a safety net so it never renders wrong.
  private func appendVisible(_ sorted: [ChatMessage]) {
    guard !sorted.isEmpty else { return }
    var batch = sorted
    for index in batch.indices where batch[index].segments == nil {
      batch[index].segments = computeSegments(for: batch[index])
    }
    pendingAppends.append(contentsOf: batch)
    scheduleAppendFlush()
  }

  /// Flushes pending appends immediately when the previous flush is already older
  /// than one display tick (low traffic → zero added latency), otherwise schedules
  /// a single coalesced flush for the remainder of the tick so a burst collapses
  /// into one array mutation.
  private func scheduleAppendFlush() {
    guard !appendFlushScheduled else { return }
    let interval = adaptiveCoalesceInterval
    let elapsed = Date().timeIntervalSince(lastAppendFlushAt)
    if elapsed >= interval {
      flushPendingAppends()
      return
    }
    appendFlushScheduled = true
    let delay = interval - elapsed
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.appendFlushScheduled = false
      self.flushPendingAppends()
    }
  }

  /// Folds the accumulated batch into `messages` as a single mutation: add + the
  /// 500-cap trim happen together so the `ForEach` diffs once. Updates the
  /// smoothed inbound rate and, only above the extreme-rate threshold, sheds the
  /// oldest messages within the just-arrived burst.
  private func flushPendingAppends() {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastAppendFlushAt)
    lastAppendFlushAt = now

    guard !pendingAppends.isEmpty else { return }
    var batch = pendingAppends
    pendingAppends.removeAll(keepingCapacity: true)

    // Estimate the inbound rate from this tick (messages / elapsed) and smooth it
    // so a single bursty frame doesn't trip shedding. `elapsed` is the real time
    // since the last flush, so an isolated message after a quiet gap reads as a
    // low rate and never sheds.
    if elapsed > 0, elapsed.isFinite {
      let instantaneous = Double(batch.count) / elapsed
      smoothedMessageRate = smoothedMessageRate * 0.6 + instantaneous * 0.4
    }

    // Graceful shedding ONLY at extreme sustained rates: cap how many lines a
    // single flush appends, dropping the oldest within the burst (they'd be
    // trimmed off the 500 cap within ~1s of a raid anyway). Below the threshold
    // every message renders — normal/small streams are never touched.
    if smoothedMessageRate > extremeMessageRateThreshold,
      batch.count > maxMessagesPerFlushUnderLoad {
      batch.removeFirst(batch.count - maxMessagesPerFlushUnderLoad)
    }

    messages.append(contentsOf: batch)
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

      // syncBuffer is kept sorted by releaseAt, so the releasable messages are a
      // contiguous prefix. Count them and drop them in one shot — repeatedly
      // calling removeFirst() shifts the whole array each time (O(n²) when a big
      // burst drains at once).
      var releaseCount = 0
      while releaseCount < syncBuffer.count, syncBuffer[releaseCount].releaseAt <= now {
        releaseCount += 1
      }
      let released = syncBuffer.prefix(releaseCount).map(\.message)
      syncBuffer.removeFirst(releaseCount)
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
