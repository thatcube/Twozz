import Foundation

/// Foundation-only networking foundation shared across the app's services.
///
/// Historically every service reached for `URLSession.shared` (or hand-rolled a
/// one-off `URLSession(configuration:)`), which meant inconsistent timeouts and
/// no shared place to add cross-cutting resilience. `NetworkClient` centralizes a
/// small set of preconfigured sessions plus a retry helper so call sites can
/// migrate incrementally — each session is a plain `URLSession`, so swapping
/// `URLSession.shared.data(for:)` for `NetworkClient.api.data(for:)` is a
/// drop-in change that preserves request/response semantics.
///
/// Intentionally Foundation-only (no tvOS-only APIs) so the same infrastructure
/// can back a future iOS target.
enum NetworkClient {
  /// JSON/REST/GraphQL traffic (Helix, GQL, 7TV/BTTV/FFZ, YouTube Data API, …).
  /// Tighter timeouts than `URLSession.shared`'s 60s default so a stalled API
  /// call fails fast instead of hanging a refresh loop.
  static let api: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 40
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()

  /// Larger / slower payloads where a longer ceiling is appropriate (playlists,
  /// snapshots, bulk catalogs). More forgiving than `api` but still bounded.
  static let media: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()

  /// General-purpose session for call sites without a strong api/media lean.
  /// Mirrors `URLSession.shared`'s default timeouts so migrating to it is
  /// behavior-preserving.
  static let `default`: URLSession = {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()

  // MARK: - Retry

  /// Run `operation`, retrying transient failures with exponential backoff plus
  /// jitter. Opt-in: only the services that want it call this — the bare
  /// sessions above stay single-shot so migrations don't silently change retry
  /// behavior.
  ///
  /// - Parameters:
  ///   - maxAttempts: total tries including the first (must be ≥ 1).
  ///   - baseDelay: delay before the first retry; doubles each subsequent retry.
  ///   - maxDelay: ceiling for any single backoff delay.
  ///   - shouldRetry: predicate to decide whether a thrown error is worth
  ///     retrying. Defaults to retrying every error.
  ///   - operation: the work to attempt.
  static func retrying<T: Sendable>(
    maxAttempts: Int = 3,
    baseDelay: Double = 0.5,
    maxDelay: Double = 8.0,
    shouldRetry: @Sendable (Error) -> Bool = { _ in true },
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    var attempt = 0
    while true {
      do {
        return try await operation()
      } catch {
        attempt += 1
        if attempt >= maxAttempts || !shouldRetry(error) || Task.isCancelled {
          throw error
        }
        let delay = backoffDelay(attempt: attempt, base: baseDelay, cap: maxDelay)
        try await Task.sleep(for: .seconds(delay))
      }
    }
  }

  /// Exponential backoff with full jitter: a random point in
  /// `0...min(cap, base * 2^(attempt-1))`. The jitter spreads retries so many
  /// callers failing at once don't reconnect in lockstep (thundering herd).
  static func backoffDelay(attempt: Int, base: Double, cap: Double) -> Double {
    let exponential = base * pow(2.0, Double(max(0, attempt - 1)))
    let ceiling = min(cap, exponential)
    return Double.random(in: 0...max(0, ceiling))
  }
}
