import Foundation
import SwiftUI

/// A single bits tier of a cheermote (e.g. the 100-bit purple tier of `Cheer`).
struct CheermoteTier: Hashable {
    /// Minimum bits this tier covers (1, 100, 1000, 5000, 10000, …).
    let minBits: Int
    /// `#RRGGBB` color Twitch renders the bit amount in for this tier. Kept as a
    /// string (alongside the resolved `Color`) so the SwiftUI-free chat
    /// tokenizer can carry it onto precomputed segments.
    let colorHex: String
    /// Color Twitch renders the bit amount in for this tier.
    let color: Color
    /// Animated tier image URL (jtvnw cloudfront).
    let imageURL: URL
}

/// One cheermote prefix (e.g. `Cheer`, `exemCheer`) and its bits tiers.
struct Cheermote: Hashable {
    /// Original-case prefix as Twitch reports it (e.g. `exemCheer`).
    let prefix: String
    /// Lowercased prefix, for case-insensitive token matching.
    let prefixLower: String
    /// Tiers sorted ascending by `minBits`.
    let tiers: [CheermoteTier]

    /// The highest tier whose `minBits` is ≤ the cheered `bits` amount.
    func tier(forBits bits: Int) -> CheermoteTier? {
        var match: CheermoteTier?
        for tier in tiers where tier.minBits <= bits {
            if match == nil || tier.minBits > match!.minBits { match = tier }
        }
        return match ?? tiers.first
    }
}

/// Fetches Twitch cheermote (bits) catalogs so cheers typed in chat like
/// `exemCheer100` render as the animated tier image + the bit amount, the way
/// they appear on twitch.tv. Mirrors `EmoteCatalogService`: anonymous web GQL,
/// cached per channel.
///
/// Both the global cheermotes and a channel's custom (partner) cheermotes are
/// merged. Image URLs are built from each group's `templateURL` (the channel
/// `partner-actions/…` template differs from the global `actions/…` one, so we
/// substitute the named placeholders rather than assuming a fixed layout). The
/// GQL `color` field comes back empty, so we apply the standard Twitch tier
/// colors by bits threshold.
actor CheermoteCatalogService {
    static let shared = CheermoteCatalogService()

    private let clientID = TwitchConfig.webPublicClientID
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    private var cache: [String: [Cheermote]] = [:]

    func catalog(for channel: String) async -> [Cheermote] {
        let key = channel.lowercased()
        if let cached = cache[key] { return cached }

        async let global = fetchGlobal()
        async let channelCustom = fetchChannel(login: key)

        // Channel customs override globals of the same prefix.
        var merged: [String: Cheermote] = [:]
        for cheer in await global { merged[cheer.prefixLower] = cheer }
        for cheer in await channelCustom { merged[cheer.prefixLower] = cheer }

        let result = Array(merged.values)
        cache[key] = result
        return result
    }

    private func fetchGlobal() async -> [Cheermote] {
        let query = "query { cheerConfig { groups { templateURL nodes { prefix tiers { bits } } } } }"
        guard let json = await fetchGQL(query: query) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let cheerConfig = data["cheerConfig"] as? [String: Any],
              let groups = cheerConfig["groups"] as? [[String: Any]] else { return [] }
        return parseGroups(groups)
    }

    private func fetchChannel(login: String) async -> [Cheermote] {
        let query = "query ChannelCheer($login: String!) { user(login: $login) { cheer { cheerGroups { templateURL nodes { prefix tiers { bits } } } } } }"
        guard let json = await fetchGQL(query: query, variables: ["login": login]) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let cheer = user["cheer"] as? [String: Any],
              let groups = cheer["cheerGroups"] as? [[String: Any]] else { return [] }
        return parseGroups(groups)
    }

    private func parseGroups(_ groups: [[String: Any]]) -> [Cheermote] {
        var out: [Cheermote] = []
        for group in groups {
            guard let template = group["templateURL"] as? String,
                  let nodes = group["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let prefix = node["prefix"] as? String,
                      let tierNodes = node["tiers"] as? [[String: Any]] else { continue }

                var tiers: [CheermoteTier] = []
                for tierNode in tierNodes {
                    guard let bits = tierNode["bits"] as? Int,
                          let url = Self.imageURL(template: template, prefix: prefix, bits: bits)
                    else { continue }
                    let hex = Self.tierColorHex(forMinBits: bits)
                    tiers.append(CheermoteTier(minBits: bits, colorHex: hex, color: Color(twitchHex: hex) ?? .gray, imageURL: url))
                }
                guard !tiers.isEmpty else { continue }
                tiers.sort { $0.minBits < $1.minBits }
                out.append(Cheermote(prefix: prefix, prefixLower: prefix.lowercased(), tiers: tiers))
            }
        }
        return out
    }

    /// Build a tier image URL by substituting the named placeholders in the
    /// group's `templateURL`. Global groups carry a `PREFIX` placeholder (which
    /// must be lowercased in the path); channel `partner-actions` groups embed
    /// the channel id + a uuid and have no `PREFIX` token, so that substitution
    /// is simply a no-op for them.
    private static func imageURL(template: String, prefix: String, bits: Int) -> URL? {
        var s = template
        s = s.replacingOccurrences(of: "PREFIX", with: prefix.lowercased())
        s = s.replacingOccurrences(of: "BACKGROUND", with: "dark")
        s = s.replacingOccurrences(of: "ANIMATION", with: "animated")
        s = s.replacingOccurrences(of: "TIER", with: String(bits))
        s = s.replacingOccurrences(of: "SCALE", with: "2")
        s = s.replacingOccurrences(of: "EXTENSION", with: "gif")
        return URL(string: s)
    }

    /// Standard Twitch bit-tier colors. The GQL `color` field is empty for the
    /// anonymous web client, so we bucket by the tier's bits threshold.
    private static func tierColorHex(forMinBits bits: Int) -> String {
        switch bits {
        case ..<100: return "#979797"     // gray
        case ..<1000: return "#9C3EE8"    // purple
        case ..<5000: return "#1DB2A5"    // green/teal
        case ..<10000: return "#0099FE"   // blue
        default: return "#F43021"         // red
        }
    }

    private func fetchGQL(query: String, variables: [String: Any]? = nil) async -> Any? {
        var req = TwitchAPIClient.graphQLRequest(
            clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        guard TwitchAPIClient.isSuccess(response) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
