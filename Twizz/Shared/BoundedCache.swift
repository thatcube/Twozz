import Foundation

/// A small, Foundation-only cache with a hard size cap (LRU eviction) and a
/// per-entry time-to-live.
///
/// The per-channel emote / badge / cheermote catalogs were previously plain
/// dictionaries keyed by channel that grew unbounded for the life of the
/// process and were never refreshed. `BoundedCache` gives them an eviction
/// policy without changing their call sites much: look up with
/// `value(forKey:)`, populate with `insert(_:forKey:)`, and drop everything on
/// sign-out with `removeAll()`.
///
/// Not thread-safe on its own — it is intended to live inside an `actor` (the
/// catalog services), whose isolation already serializes access. `mutating`
/// lookups keep the LRU recency order honest.
struct BoundedCache<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var insertedAt: Date
  }

  private var storage: [Key: Entry] = [:]
  /// Keys ordered least-recently-used first, most-recently-used last.
  private var recency: [Key] = []

  /// Maximum number of live entries; inserting beyond this evicts the LRU entry.
  let capacity: Int
  /// How long an entry stays valid after insertion, in seconds.
  let ttl: TimeInterval

  init(capacity: Int, ttl: TimeInterval) {
    self.capacity = max(1, capacity)
    self.ttl = ttl
  }

  /// Returns the cached value for `key` when present and unexpired, refreshing
  /// its LRU recency. Expired entries are dropped and treated as a miss.
  mutating func value(forKey key: Key, now: Date = Date()) -> Value? {
    guard let entry = storage[key] else { return nil }
    guard now.timeIntervalSince(entry.insertedAt) < ttl else {
      remove(key)
      return nil
    }
    touch(key)
    return entry.value
  }

  /// Inserts (or replaces) `value` for `key`, marking it most-recently-used and
  /// evicting the least-recently-used entry if the capacity is exceeded.
  mutating func insert(_ value: Value, forKey key: Key, now: Date = Date()) {
    storage[key] = Entry(value: value, insertedAt: now)
    touch(key)
    while recency.count > capacity, let lru = recency.first {
      remove(lru)
    }
  }

  /// Drops every entry (e.g. on sign-out).
  mutating func removeAll() {
    storage.removeAll()
    recency.removeAll()
  }

  // MARK: - Recency bookkeeping

  private mutating func touch(_ key: Key) {
    if let index = recency.firstIndex(of: key) {
      recency.remove(at: index)
    }
    recency.append(key)
  }

  private mutating func remove(_ key: Key) {
    storage[key] = nil
    if let index = recency.firstIndex(of: key) {
      recency.remove(at: index)
    }
  }
}
