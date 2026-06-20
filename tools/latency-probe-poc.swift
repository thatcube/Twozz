#!/usr/bin/env swift
//
//  latency-probe-poc.swift — Lower-latency alt-source spike
//
//  Question being tested: for a streamer who simulcasts to YouTube, can we
//  deliver a *meaningfully lower* live latency than our proxied Twitch path by
//  playing the YouTube HLS manifest in AVPlayer instead — and can we decide
//  which source is lower-latency *cheaply, before playing*, so the app can
//  default to the fastest and still let the user pick?
//
//  How it decides (no playback needed):
//    AVPlayer on plain HLS starts ~3 target-durations behind the live edge
//    (Apple's default HOLD-BACK when the playlist doesn't specify one). So the
//    media-playlist's #EXT-X-TARGETDURATION is a direct, fetch-only readout of
//    the broadcaster's chosen latency mode:
//        ~2s segments  -> Low latency      -> AVPlayer lands ~6s behind
//        ~5s segments  -> Normal latency   -> AVPlayer lands ~15s behind
//        Low-Latency HLS parts (#EXT-X-PART / SERVER-CONTROL) -> AVPlayer rides
//        the edge natively (~2 part-durations) — this is what Amazon IVS (Kick)
//        emits and what would give a near-native experience with no proxy.
//
//  This spike:
//    1. Resolves the Twitch channel's live HLS and probes its media playlist.
//    2. Auto-discovers the channel's YouTube link from Twitch's public GQL
//       social links (the same anonymous query ChannelProfileService uses),
//       OR uses a YouTube handle/URL/videoID passed as the 2nd argument.
//    3. Resolves the YouTube live HLS (watch-page route, same path the chat
//       scraper uses) and probes its media playlist.
//    4. Prints a side-by-side predicted-latency comparison and the recommended
//       default source.
//
//  Usage:
//    swift tools/latency-probe-poc.swift <twitch_login> [youtube_handle|url|videoId]
//
//  Non-commercial, ad-respecting, read-only: it fetches public manifests only,
//  never plays or restreams, and strips nothing.

import Foundation

// MARK: - Shared

let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
let playbackAccessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
let desktopUA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

/// Apple's default live HOLD-BACK is 3 × target duration when the playlist does
/// not specify one. Used to translate a manifest into a predicted AVPlayer edge
/// distance without ever starting playback.
let defaultHoldBackMultiplier = 3.0

struct ProbeResult {
  let source: String          // "Twitch" / "YouTube"
  let label: String           // human description of the channel/video
  let targetDuration: Double  // #EXT-X-TARGETDURATION
  let avgSegment: Double      // mean #EXTINF in the window
  let segmentCount: Int       // segments listed (window depth proxy)
  let hasLLHLSParts: Bool     // #EXT-X-PART / SERVER-CONTROL present (IVS-style)
  let twitchPrefetchCount: Int // #EXT-X-TWITCH-PREFETCH tags (Twitch-only)

  /// The real segment cadence drives how far back AVPlayer starts — NOT the
  /// advertised #EXT-X-TARGETDURATION, which Twitch inflates (it reports 6 while
  /// shipping 2s segments). Falls back to the target only if no #EXTINF parsed.
  var cadence: Double { avgSegment > 0 ? avgSegment : targetDuration }

  /// Predicted distance behind the live edge AVPlayer would START at, in seconds.
  ///   • LL-HLS parts (IVS/Kick): AVPlayer rides ~1 segment from the edge.
  ///   • Twitch prefetch + our proxy: promotion pulls the start to ~1.5 segments.
  ///   • Plain HLS (YouTube): AVPlayer's default hold-back ≈ 3 segment cadences.
  /// This is the *floor* AVPlayer starts at; it does not model our deliberate
  /// deep-buffer stability fallback (which rides 15–20s on unstable encoders).
  var predictedEdgeSeconds: Double {
    if hasLLHLSParts { return max(1.0, cadence) }
    if twitchPrefetchCount > 0 { return cadence * 1.5 }
    return cadence * defaultHoldBackMultiplier
  }

  var windowSeconds: Double { avgSegment * Double(segmentCount) }
}

enum SpikeError: Error, CustomStringConvertible {
  case http(Int, String)
  case offline(String)
  case noManifest(String)
  case parse(String)
  var description: String {
    switch self {
    case .http(let c, let b): return "HTTP \(c): \(b.prefix(200))"
    case .offline(let s): return "offline/unavailable: \(s)"
    case .noManifest(let s): return "no HLS manifest: \(s)"
    case .parse(let s): return "parse error: \(s)"
    }
  }
}

func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
  var req = URLRequest(url: url)
  req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
  for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
  let (data, response) = try await URLSession.shared.data(for: req)
  let http = response as? HTTPURLResponse ?? HTTPURLResponse()
  return (data, http)
}

/// Parses a *media* playlist into the latency-relevant fields.
func parseMediaPlaylist(_ text: String) -> (target: Double, avg: Double, count: Int, parts: Bool, prefetch: Int) {
  var target = 0.0
  var durations: [Double] = []
  var hasParts = false
  var prefetch = 0
  for raw in text.components(separatedBy: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("#EXT-X-TARGETDURATION:") {
      target = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? target
    } else if line.hasPrefix("#EXTINF:") {
      let v = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
      if let d = Double(v) { durations.append(d) }
    } else if line.hasPrefix("#EXT-X-PART:") || line.hasPrefix("#EXT-X-SERVER-CONTROL")
      || line.hasPrefix("#EXT-X-PART-INF") {
      hasParts = true
    } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH") {
      prefetch += 1
    }
  }
  let avg = durations.isEmpty ? target : durations.reduce(0, +) / Double(durations.count)
  return (target, avg, durations.count, hasParts, prefetch)
}

/// Given a *master* playlist body + base URL + request headers, pick a mid/high
/// variant media playlist, fetch it, and probe it.
func probeMaster(
  source: String, label: String, masterBody: String, base: URL, headers: [String: String]
) async throws -> ProbeResult {
  let mediaURLs = masterBody
    .components(separatedBy: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0.hasPrefix("http") }
    .compactMap { URL(string: $0) }
  guard !mediaURLs.isEmpty else { throw SpikeError.parse("no variant URLs in master") }
  // Prefer a non-top, non-bottom variant (skip audio-only / source extremes).
  let pick = mediaURLs[min(mediaURLs.count - 1, max(0, mediaURLs.count / 2))]
  let (data, http) = try await get(pick, headers: headers)
  guard (200...299).contains(http.statusCode) else {
    throw SpikeError.http(http.statusCode, String(decoding: data, as: UTF8.self))
  }
  let p = parseMediaPlaylist(String(decoding: data, as: UTF8.self))
  return ProbeResult(
    source: source, label: label, targetDuration: p.target, avgSegment: p.avg,
    segmentCount: p.count, hasLLHLSParts: p.parts, twitchPrefetchCount: p.prefetch)
}

// MARK: - Twitch

func twitchProbe(login: String) async throws -> ProbeResult {
  // 1. PlaybackAccessToken
  var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
  req.httpMethod = "POST"
  req.setValue(webClientID, forHTTPHeaderField: "Client-ID")
  req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  let body: [String: Any] = [
    "operationName": "PlaybackAccessToken",
    "extensions": ["persistedQuery": ["version": 1, "sha256Hash": playbackAccessTokenHash]],
    "variables": [
      "isLive": true, "login": login, "isVod": false, "vodID": "",
      "playerType": "embed", "platform": "site",
    ],
  ]
  req.httpBody = try JSONSerialization.data(withJSONObject: body)
  let (tData, tResp) = try await URLSession.shared.data(for: req)
  let tStatus = (tResp as? HTTPURLResponse)?.statusCode ?? -1
  guard (200...299).contains(tStatus) else {
    throw SpikeError.http(tStatus, String(decoding: tData, as: UTF8.self))
  }
  guard let json = try JSONSerialization.jsonObject(with: tData) as? [String: Any],
    let dataObj = json["data"] as? [String: Any],
    let tokenObj = dataObj["streamPlaybackAccessToken"] as? [String: Any],
    let value = tokenObj["value"] as? String, let sig = tokenObj["signature"] as? String
  else { throw SpikeError.offline("no streamPlaybackAccessToken for \(login)") }

  // 2. Usher master
  var comps = URLComponents(
    string: "https://usher.ttvnw.net/api/v2/channel/hls/\(login.lowercased()).m3u8")!
  comps.queryItems = [
    .init(name: "platform", value: "web"),
    .init(name: "p", value: String(Int.random(in: 0..<999_999))),
    .init(name: "allow_source", value: "true"),
    .init(name: "allow_audio_only", value: "true"),
    .init(name: "fast_bread", value: "true"),
    .init(name: "supported_codecs", value: "h264"),
    .init(name: "sig", value: sig),
    .init(name: "token", value: value),
  ]
  let twHeaders = [
    "Referer": "https://player.twitch.tv", "Origin": "https://player.twitch.tv",
  ]
  let (mData, mHTTP) = try await get(comps.url!, headers: twHeaders)
  if mHTTP.statusCode == 404 { throw SpikeError.offline("\(login) is offline") }
  guard (200...299).contains(mHTTP.statusCode) else {
    throw SpikeError.http(mHTTP.statusCode, String(decoding: mData, as: UTF8.self))
  }
  return try await probeMaster(
    source: "Twitch", label: login, masterBody: String(decoding: mData, as: UTF8.self),
    base: comps.url!, headers: twHeaders)
}

/// Anonymous GQL: a channel's public social links (same query as the app).
func twitchSocialLinks(login: String) async -> [(name: String, url: String)] {
  let query = """
    query ChannelPage($login: String!) {
      user(login: $login) { channel { socialMedias { name title url } } }
    }
    """
  var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
  req.httpMethod = "POST"
  req.setValue(webClientID, forHTTPHeaderField: "Client-ID")
  req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  req.httpBody = try? JSONSerialization.data(
    withJSONObject: ["query": query, "variables": ["login": login.lowercased()]])
  guard let (data, _) = try? await URLSession.shared.data(for: req),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let d = json["data"] as? [String: Any], let user = d["user"] as? [String: Any],
    let channel = user["channel"] as? [String: Any],
    let medias = channel["socialMedias"] as? [[String: Any]]
  else { return [] }
  return medias.compactMap { m in
    guard let url = m["url"] as? String else { return nil }
    return ((m["name"] as? String) ?? "", url)
  }
}

// MARK: - YouTube

func extractVideoID(from s: String) -> String? {
  if s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return s }
  if let r = s.range(of: "(?<=v=)[A-Za-z0-9_-]{11}", options: .regularExpression) {
    return String(s[r])
  }
  if let r = s.range(of: "(?<=youtu\\.be/)[A-Za-z0-9_-]{11}", options: .regularExpression) {
    return String(s[r])
  }
  return nil
}

/// Resolve a YouTube handle/URL/ID to the *currently live* video ID.
func resolveYouTubeLiveID(_ input: String) async -> String? {
  if let direct = extractVideoID(from: input) { return direct }
  var path = input
  if !path.hasPrefix("http") {
    let handle = path.hasPrefix("@") ? path : "@\(path)"
    path = "https://www.youtube.com/\(handle)/live"
  } else if !path.contains("/live") {
    path += (path.hasSuffix("/") ? "live" : "/live")
  }
  guard let url = URL(string: path) else { return nil }
  guard let (data, http) = try? await get(
    url, headers: ["Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1"]),
    (200...299).contains(http.statusCode)
  else { return nil }
  if let final = http.url?.absoluteString, let id = extractVideoID(from: final) { return id }
  let html = String(decoding: data, as: UTF8.self)
  if let r = html.range(of: "(?<=\"videoId\":\")[A-Za-z0-9_-]{11}", options: .regularExpression) {
    return String(html[r])
  }
  return nil
}

func youtubeProbe(videoID: String) async throws -> ProbeResult {
  let watch = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
  let (data, http) = try await get(
    watch, headers: ["Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1"])
  guard (200...299).contains(http.statusCode) else {
    throw SpikeError.http(http.statusCode, "watch page")
  }
  let html = String(decoding: data, as: UTF8.self)
  guard let r = html.range(of: "(?<=hlsManifestUrl\":\")[^\"]+", options: .regularExpression) else {
    throw SpikeError.noManifest("not live or HLS not exposed for \(videoID)")
  }
  let master = String(html[r]).replacingOccurrences(of: "\\u0026", with: "&")
  guard let masterURL = URL(string: master) else { throw SpikeError.parse("bad manifest URL") }
  let (mData, mHTTP) = try await get(masterURL)
  guard (200...299).contains(mHTTP.statusCode) else {
    throw SpikeError.http(mHTTP.statusCode, "master")
  }
  return try await probeMaster(
    source: "YouTube", label: videoID, masterBody: String(decoding: mData, as: UTF8.self),
    base: masterURL, headers: [:])
}

// MARK: - Report

func report(_ r: ProbeResult) {
  let mode: String
  if r.hasLLHLSParts { mode = "LL-HLS parts (IVS-style, native edge)" }
  else if r.twitchPrefetchCount > 0 { mode = "Twitch prefetch (\(r.twitchPrefetchCount) tags)" }
  else if r.cadence <= 2.5 { mode = "low latency (~2s segments)" }
  else { mode = "normal latency (~\(Int(r.cadence.rounded()))s segments)" }
  print("  \(r.source) — \(r.label)")
  print(String(format: "    target=%.1fs  avgSeg=%.2fs  window=%.0fs  segs=%d",
    r.targetDuration, r.avgSegment, r.windowSeconds, r.segmentCount))
  print("    mode: \(mode)")
  print(String(format: "    ▶ predicted AVPlayer start: ~%.1fs behind live edge",
    r.predictedEdgeSeconds))
}

func run(twitch: String, youtubeArg: String?) async {
  print("=== Twizz — lower-latency alt-source spike ===")
  print("Twitch channel: \(twitch)\n")

  var results: [ProbeResult] = []

  print("[1] Probing Twitch HLS…")
  do { let t = try await twitchProbe(login: twitch); report(t); results.append(t) }
  catch { print("    ❌ \(error)") }
  print("")

  // Resolve which YouTube target to probe.
  var ytTarget = youtubeArg
  if ytTarget == nil {
    print("[2] Auto-discovering YouTube link from Twitch social links…")
    let links = await twitchSocialLinks(login: twitch)
    let yt = links.first { ($0.url.lowercased().contains("youtube.com")
      || $0.url.lowercased().contains("youtu.be")) }
    if let yt { print("    found: \(yt.url)"); ytTarget = yt.url }
    else { print("    (no YouTube social link published by this channel)") }
  }

  if let ytTarget {
    print("[3] Resolving YouTube live video…")
    if let vid = await resolveYouTubeLiveID(ytTarget) {
      print("    live videoId: \(vid)")
      do { let y = try await youtubeProbe(videoID: vid); report(y); results.append(y) }
      catch { print("    ❌ \(error)") }
    } else {
      print("    ❌ could not resolve a live YouTube video (likely not live right now)")
    }
  }
  print("")

  // Recommendation.
  print("=== Recommendation ===")
  guard let best = results.min(by: { $0.predictedEdgeSeconds < $1.predictedEdgeSeconds }) else {
    print("No source could be probed."); return
  }
  if results.count == 1 {
    print("Only \(best.source) was probable; default to it.")
  } else {
    let sorted = results.sorted { $0.predictedEdgeSeconds < $1.predictedEdgeSeconds }
    let win = sorted[1].predictedEdgeSeconds - sorted[0].predictedEdgeSeconds
    print(String(format: "Default → %@ (~%.1fs behind), %.1fs lower than %@.",
      best.source, best.predictedEdgeSeconds, win, sorted[1].source))
    print("Offer the other as a user-selectable source.")
  }
  print("\nNote: predicted edge distance is a fetch-only estimate from segment")
  print("structure; confirm on-device with the Diagnostics latency readout.")
}

let args = CommandLine.arguments
guard args.count > 1 else {
  print("Usage: swift tools/latency-probe-poc.swift <twitch_login> [youtube_handle|url|videoId]")
  exit(2)
}
let sema = DispatchSemaphore(value: 0)
Task {
  await run(twitch: args[1], youtubeArg: args.count > 2 ? args[2] : nil)
  sema.signal()
}
sema.wait()
