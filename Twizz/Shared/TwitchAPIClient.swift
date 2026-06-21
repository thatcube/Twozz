import Foundation

/// Single source of truth for constructing Twitch HTTP requests.
///
/// Roughly a dozen services used to hand-roll the same `URLRequest` boilerplate:
/// setting `Client-Id`/`Authorization`/`User-Agent`/`Accept`/`Content-Type`
/// headers, POSTing GraphQL bodies, and repeating the
/// `(200...299).contains(status)` status-range check. These helpers centralize
/// that construction so the wire format stays identical while the call sites
/// shrink to the parts that actually differ (endpoint, query, decoding).
///
/// The helpers deliberately build the request and leave body serialization and
/// response decoding to the caller where those vary (persisted-query payloads,
/// `try` vs `try?` semantics, bespoke error mapping), so behavior is preserved
/// byte-for-byte.
enum TwitchAPIClient {
  /// Twitch's private web GraphQL endpoint (used signed-out for public data).
  static let graphQLEndpoint = URL(string: "https://gql.twitch.tv/gql")!

  /// Base URL for Twitch's official Helix REST API.
  static let helixBaseURL = URL(string: "https://api.twitch.tv/helix")!

  // MARK: - Status

  /// `true` when the response carries a 2xx HTTP status. Mirrors the
  /// `(200...299).contains((response as? HTTPURLResponse)?.statusCode ?? -1)`
  /// check every service previously inlined.
  static func isSuccess(_ response: URLResponse?) -> Bool {
    (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? -1)
  }

  /// Returns `data` when the response is 2xx, otherwise throws
  /// `URLError(.badServerResponse)` — the throwing status-range guard shared by
  /// the GraphQL transports that hand decoded data back to their caller.
  @discardableResult
  static func validatedData(_ data: Data, _ response: URLResponse) throws -> Data {
    guard isSuccess(response) else { throw URLError(.badServerResponse) }
    return data
  }

  /// Decodes `T` from a successful (2xx) response, throwing
  /// `URLError(.badServerResponse)` on a non-2xx status — the
  /// status-check-then-`JSONDecoder` pattern used across the Helix/GraphQL
  /// services.
  static func decode<T: Decodable>(
    _ type: T.Type, from data: Data, response: URLResponse
  ) throws -> T {
    try validatedData(data, response)
    return try sharedDecoder.decode(T.self, from: data)
  }

  /// Decodes `T` from already-validated response data using the shared decoder.
  /// Behaves exactly like `try JSONDecoder().decode(T.self, from: data)` (default
  /// decoder configuration) but reuses one decoder instead of allocating a fresh
  /// `JSONDecoder()` per call. Intended for the many services that check the HTTP
  /// status themselves (with their own bespoke error mapping) and then decode the
  /// body: the status guard stays where it is and only the redundant decoder is
  /// shared.
  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try sharedDecoder.decode(T.self, from: data)
  }

  /// A single reused decoder for every `decode(_:from:response:)` call. A fresh
  /// `JSONDecoder()` per response is wasteful across the dozen services that
  /// route through here; the decoder holds only immutable configuration and is
  /// safe to read concurrently while decoding value types.
  private nonisolated(unsafe) static let sharedDecoder = JSONDecoder()

  // MARK: - GraphQL

  /// Builds a POST request to the web GraphQL endpoint with the standard
  /// scraping headers. Body serialization is left to the caller so persisted
  /// queries and plain `{query, variables}` payloads (and their `try`/`try?`
  /// serialization) keep their exact semantics.
  ///
  /// - Parameters:
  ///   - clientID: `Client-Id` value (defaults to the public web client id).
  ///   - clientIDField: exact header field name; callers vary between
  ///     `Client-Id` and `Client-ID`, both preserved verbatim.
  ///   - userAgent: optional `User-Agent`; omitted when `nil`.
  static func graphQLRequest(
    clientID: String = TwitchConfig.webPublicClientID,
    clientIDField: String = "Client-Id",
    userAgent: String? = nil
  ) -> URLRequest {
    var req = URLRequest(url: graphQLEndpoint)
    req.httpMethod = "POST"
    req.setValue(clientID, forHTTPHeaderField: clientIDField)
    if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return req
  }

  /// Builds a `{ "query": ..., "variables": ... }` GraphQL body dictionary.
  /// `variables` is omitted entirely when `nil`, matching the hand-rolled
  /// bodies so the serialized JSON is identical.
  static func graphQLBody(query: String, variables: [String: Any]? = nil) -> [String: Any] {
    var body: [String: Any] = ["query": query]
    if let variables { body["variables"] = variables }
    return body
  }

  // MARK: - Helix

  /// Builds an authenticated Helix request with the standard
  /// `Authorization: Bearer` + `Client-Id` headers. `Accept`, `Content-Type`,
  /// and `User-Agent` are attached only when supplied so each endpoint keeps
  /// the exact header set it sent before.
  static func helixRequest(
    url: URL,
    method: String = "GET",
    accessToken: String,
    clientID: String,
    accept: String? = nil,
    contentType: String? = nil,
    userAgent: String? = nil
  ) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(clientID, forHTTPHeaderField: "Client-Id")
    if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
    return req
  }
}
