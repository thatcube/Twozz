import Foundation

actor BadgeCatalogService {
  static let shared = BadgeCatalogService()

  private let clientID = TwitchConfig.webPublicClientID
  private let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  private var cache = BoundedCache<String, [String: URL]>(capacity: 48, ttl: 1800)

  func catalog(for channel: String) async -> [String: URL] {
    let key = channel.lowercased()
    if let cached = cache.value(forKey: key) { return cached }

    let userID = await twitchUserID(for: key)

    async let global = fetchGlobalBadges()
    async let channelBadges = fetchChannelBadges(twitchUserID: userID)

    let merged = (await global).merging(await channelBadges) { _, new in new }
    cache.insert(merged, forKey: key)
    return merged
  }

  /// Drops all cached catalogs (e.g. on sign-out).
  func clear() {
    cache.removeAll()
  }

  private func fetchGlobalBadges() async -> [String: URL] {
    guard let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/global") else { return [:] }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func fetchChannelBadges(twitchUserID: String?) async -> [String: URL] {
    guard let twitchUserID,
      let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/channel?id=\(twitchUserID)")
    else {
      return [:]
    }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func parseBadgeJSON(_ json: Any) -> [String: URL] {
    if let dict = json as? [String: Any] {
      return parseLegacyBadgeDisplayJSON(dict)
    }
    if let array = json as? [[String: Any]] {
      return parseIVRBadgeArray(array)
    }
    return [:]
  }

  private func parseLegacyBadgeDisplayJSON(_ json: [String: Any]) -> [String: URL] {
    guard let sets = json["badge_sets"] as? [String: Any] else { return [:] }
    var out: [String: URL] = [:]

    for (setName, setValue) in sets {
      guard let set = setValue as? [String: Any],
        let versions = set["versions"] as? [String: Any]
      else { continue }

      for (version, versionValue) in versions {
        guard let meta = versionValue as? [String: Any] else { continue }
        let urlString =
          (meta["image_url_2x"] as? String)
          ?? (meta["image_url_4x"] as? String)
          ?? (meta["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setName)/\(version)"] = url
      }
    }

    return out
  }

  private func parseIVRBadgeArray(_ sets: [[String: Any]]) -> [String: URL] {
    var out: [String: URL] = [:]

    for set in sets {
      guard let setID = set["set_id"] as? String,
        let versions = set["versions"] as? [[String: Any]]
      else { continue }

      for version in versions {
        guard let versionID = version["id"] as? String else { continue }
        let urlString =
          (version["image_url_2x"] as? String)
          ?? (version["image_url_4x"] as? String)
          ?? (version["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setID)/\(versionID)"] = url
      }
    }

    return out
  }

  private func twitchUserID(for login: String) async -> String? {
    if let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let ivrURL = URL(string: "https://api.ivr.fi/v2/twitch/user?login=\(encoded)"),
      let payload = await fetchJSON(url: ivrURL) as? [[String: Any]],
      let id = payload.first?["id"] as? String,
      !id.isEmpty
    {
      return id
    }

    var req = TwitchAPIClient.graphQLRequest(
      clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)

    let query = "query UserID($login: String!) { user(login: $login) { id } }"
    req.httpBody = try? JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["login": login]))

    guard let json = await fetchJSON(request: req) as? [String: Any] else { return nil }
    guard let data = json["data"] as? [String: Any] else { return nil }
    guard let user = data["user"] as? [String: Any] else { return nil }
    return user["id"] as? String
  }

  private func fetchJSON(url: URL) async -> Any? {
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await NetworkClient.api.data(for: req) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private func fetchJSON(request: URLRequest) async -> Any? {
    guard let (data, response) = try? await NetworkClient.api.data(for: request) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
