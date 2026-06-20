import Foundation

actor EmoteCatalogService {
    static let shared = EmoteCatalogService()

    private let clientID = TwitchConfig.webPublicClientID
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    private var cache: [String: [String: URL]] = [:]

    func catalog(for channel: String) async -> [String: URL] {
        let key = channel.lowercased()
        if let cached = cache[key] { return cached }

        let userID = await twitchUserID(for: key)

        async let twitchGlobal = fetchTwitchGlobal()
        async let sevenTVGlobal = fetch7TVGlobal()
        async let bttvGlobal = fetchBTTVGlobal()
        async let ffzGlobal = fetchFFZGlobal()

        async let twitchChannel = fetchTwitchChannel(login: key)
        async let sevenTVChannel = fetch7TVChannel(twitchUserID: userID)
        async let bttvChannel = fetchBTTVChannel(twitchUserID: userID)
        async let ffzChannel = fetchFFZChannel(channel: key)

        // Accumulate into a single dictionary so we don't allocate a fresh
        // intermediate copy per provider the way a `.merging(…).merging(…)`
        // chain does. Later sources win on key conflicts (channel over global).
        var merged = await twitchGlobal
        merged.merge(await sevenTVGlobal) { _, new in new }
        merged.merge(await bttvGlobal) { _, new in new }
        merged.merge(await ffzGlobal) { _, new in new }
        merged.merge(await twitchChannel) { _, new in new }
        merged.merge(await sevenTVChannel) { _, new in new }
        merged.merge(await bttvChannel) { _, new in new }
        merged.merge(await ffzChannel) { _, new in new }

        cache[key] = merged
        return merged
    }

    /// Fetches only the provider-global emote sets (7TV, BTTV, FFZ) with no
    /// channel context. Useful outside of a channel, e.g. the sign-in screen.
    func globalCatalog() async -> [String: URL] {
        let key = "__global__"
        if let cached = cache[key] { return cached }

        async let twitchGlobal = fetchTwitchGlobal()
        async let sevenTVGlobal = fetch7TVGlobal()
        async let bttvGlobal = fetchBTTVGlobal()
        async let ffzGlobal = fetchFFZGlobal()

        var merged = await twitchGlobal
        merged.merge(await sevenTVGlobal) { _, new in new }
        merged.merge(await bttvGlobal) { _, new in new }
        merged.merge(await ffzGlobal) { _, new in new }

        cache[key] = merged
        return merged
    }

    private func twitchUserID(for login: String) async -> String? {
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

    /// Twitch's first-party global emotes (Kappa, LUL, PogChamp, …) via the
    /// public web GQL endpoint. Emote set "0" is the global set.
    private func fetchTwitchGlobal() async -> [String: URL] {
        let query = "query { emoteSet(id: \"0\") { emotes { id token } } }"
        guard let json = await fetchTwitchGQL(query: query) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let emoteSet = data["emoteSet"] as? [String: Any],
              let emotes = emoteSet["emotes"] as? [[String: Any]] else { return [:] }
        return parseTwitchEmotes(emotes)
    }

    /// A channel's first-party subscriber/bit emotes (e.g. `alveusCheer`). These
    /// only resolve on Twitch via the IRC `emotes` tag, so fetching them by name
    /// lets them render when typed on YouTube too.
    private func fetchTwitchChannel(login: String) async -> [String: URL] {
        let query = "query ChannelEmotes($login: String!) { user(login: $login) { subscriptionProducts { emotes { id token } } } }"
        guard let json = await fetchTwitchGQL(query: query, variables: ["login": login]) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let products = user["subscriptionProducts"] as? [[String: Any]] else { return [:] }

        var map: [String: URL] = [:]
        for product in products {
            guard let emotes = product["emotes"] as? [[String: Any]] else { continue }
            map.merge(parseTwitchEmotes(emotes)) { _, new in new }
        }
        return map
    }

    private func parseTwitchEmotes(_ list: [[String: Any]]) -> [String: URL] {
        var map: [String: URL] = [:]
        for emote in list {
            guard let token = emote["token"] as? String,
                  let id = emote["id"] as? String,
                  let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0") else { continue }
            map[token] = url
        }
        return map
    }

    private func fetchTwitchGQL(query: String, variables: [String: Any]? = nil) async -> Any? {
        var req = TwitchAPIClient.graphQLRequest(
            clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

        return await fetchJSON(request: req)
    }

    private func fetch7TVGlobal() async -> [String: URL] {
        guard let url = URL(string: "https://7tv.io/v3/emote-sets/global") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [String: Any] else { return [:] }
        return parse7TVEmoteSet(json)
    }

    private func fetch7TVChannel(twitchUserID: String?) async -> [String: URL] {
        guard let twitchUserID,
              let url = URL(string: "https://7tv.io/v3/users/twitch/\(twitchUserID)") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [String: Any] else { return [:] }
        guard let emoteSet = json["emote_set"] as? [String: Any] else { return [:] }
        return parse7TVEmoteSet(emoteSet)
    }

    private func parse7TVEmoteSet(_ json: [String: Any]) -> [String: URL] {
        guard let emotes = json["emotes"] as? [[String: Any]] else { return [:] }
        var map: [String: URL] = [:]
        for emote in emotes {
            guard let name = emote["name"] as? String else { continue }
            let id = (emote["id"] as? String)
                ?? ((emote["data"] as? [String: Any])?["id"] as? String)
            guard let id, let url = URL(string: "https://cdn.7tv.app/emote/\(id)/2x.webp") else { continue }
            map[name] = url
        }
        return map
    }

    private func fetchBTTVGlobal() async -> [String: URL] {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [[String: Any]] else { return [:] }
        return parseBTTVEmotes(json)
    }

    private func fetchBTTVChannel(twitchUserID: String?) async -> [String: URL] {
        guard let twitchUserID,
              let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(twitchUserID)") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [String: Any] else { return [:] }
        let channel = parseBTTVEmotes(json["channelEmotes"] as? [[String: Any]] ?? [])
        let shared = parseBTTVEmotes(json["sharedEmotes"] as? [[String: Any]] ?? [])
        return channel.merging(shared) { _, new in new }
    }

    private func parseBTTVEmotes(_ list: [[String: Any]]) -> [String: URL] {
        var map: [String: URL] = [:]
        for emote in list {
            guard let name = emote["code"] as? String,
                  let id = emote["id"] as? String,
                  let url = URL(string: "https://cdn.betterttv.net/emote/\(id)/2x") else { continue }
            map[name] = url
        }
        return map
    }

    private func fetchFFZGlobal() async -> [String: URL] {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/set/global") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [String: Any] else { return [:] }
        return parseFFZSets(json)
    }

    private func fetchFFZChannel(channel: String) async -> [String: URL] {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/room/\(channel)") else { return [:] }
        guard let json = await fetchJSON(url: url) as? [String: Any] else { return [:] }
        return parseFFZSets(json)
    }

    private func parseFFZSets(_ json: [String: Any]) -> [String: URL] {
        guard let sets = json["sets"] as? [String: Any] else { return [:] }
        var map: [String: URL] = [:]

        for value in sets.values {
            guard let set = value as? [String: Any],
                  let emotes = set["emoticons"] as? [[String: Any]] else { continue }

            for emote in emotes {
                guard let name = emote["name"] as? String,
                      let urls = emote["urls"] as? [String: String] else { continue }
                let chosen = urls["4"] ?? urls["2"] ?? urls["1"]
                guard let chosen else { continue }
                let full = chosen.hasPrefix("//") ? "https:\(chosen)" : chosen
                guard let url = URL(string: full) else { continue }
                map[name] = url
            }
        }

        return map
    }

    private func fetchJSON(url: URL) async -> Any? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func fetchJSON(request: URLRequest) async -> Any? {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
