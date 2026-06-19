#!/usr/bin/env swift
//
//  hermes-events-poc.swift — read-only spike
//
//  Verifies that we can passively RECEIVE live poll / prediction / hype-train /
//  goal events for an ARBITRARY channel (one we do not own), using only on-device
//  HTTP + WebSocket calls — the same private surface PlaybackService already uses
//  for playback. No voting, no writes.
//
//  Transport: Twitch "Hermes" WebSocket (wss://hermes.twitch.tv/v1), the gateway
//  the twitch.tv web client uses for real-time channel events now that the public
//  PubSub topics are gone. We connect with the anonymous web Client-ID, then
//  `subscribe` to the channel-public pubsub topics. A `subscribeResponse` of
//  `ok` proves the read path works; any `notification` frame is a captured live
//  event.
//
//  Usage:  swift tools/hermes-events-poc.swift <channel_login> [seconds]
//          (default listen window: 120s)
//
//  Optional: set TWITCH_OAUTH_TOKEN to authenticate the Hermes session. Not
//  required for these channel-public topics, but included so we can A/B whether
//  auth changes delivery.
//

import Foundation

let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
let userAgent =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

/// Channel-public topics the web client subscribes a viewer to. `%@` is the
/// numeric broadcaster id.
let topicTemplates: [(label: String, topic: String)] = [
  ("poll", "polls.%@"),
  ("prediction", "predictions-channel-v1.%@"),
  ("hype-train", "hype-train-events-v2.%@"),
  ("goal", "creator-goals-events-v1.%@"),
]

enum POCError: Error, CustomStringConvertible {
  case http(Int, String)
  case badResponse(String)
  case noSuchUser(String)

  var description: String {
    switch self {
    case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
    case .badResponse(let s): return "Unexpected response: \(s.prefix(300))"
    case .noSuchUser(let login): return "No such channel/login: \(login)"
    }
  }
}

// MARK: - Resolve broadcaster id (private GQL, anon client id)

func resolveBroadcasterID(login: String) async throws -> (id: String, display: String) {
  var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
  req.httpMethod = "POST"
  req.setValue(webClientID, forHTTPHeaderField: "Client-ID")
  req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")

  let query = "query($login:String!){user(login:$login){id login displayName}}"
  let body: [String: Any] = ["query": query, "variables": ["login": login.lowercased()]]
  req.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: req)
  let status = (response as? HTTPURLResponse)?.statusCode ?? -1
  let text = String(data: data, encoding: .utf8) ?? ""
  guard (200...299).contains(status) else { throw POCError.http(status, text) }

  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let dataObj = json["data"] as? [String: Any]
  else { throw POCError.badResponse(text) }
  guard let user = dataObj["user"] as? [String: Any], let id = user["id"] as? String else {
    throw POCError.noSuchUser(login)
  }
  let display = (user["displayName"] as? String) ?? login
  return (id, display)
}

// MARK: - Hermes WebSocket

func isoTimestamp() -> String {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.string(from: Date())
}

func randomID(_ length: Int = 22) -> String {
  let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
  return String((0..<length).map { _ in chars.randomElement()! })
}

func subscribeFrame(topic: String) -> String {
  let message: [String: Any] = [
    "type": "subscribe",
    "id": "twizz-parent-\(randomID())",
    "subscribe": [
      "id": "twizz-\(randomID())",
      "type": "pubsub",
      "pubsub": ["topic": topic],
    ],
    "timestamp": isoTimestamp(),
  ]
  let data = try! JSONSerialization.data(withJSONObject: message)
  return String(data: data, encoding: .utf8)!
}

func authenticateFrame(token: String) -> String {
  let message: [String: Any] = [
    "type": "authenticate",
    "id": "twizz-auth-\(randomID())",
    "authenticate": ["token": token],
    "timestamp": isoTimestamp(),
  ]
  let data = try! JSONSerialization.data(withJSONObject: message)
  return String(data: data, encoding: .utf8)!
}

func pretty(_ raw: String) -> String {
  guard let d = raw.data(using: .utf8),
    let obj = try? JSONSerialization.jsonObject(with: d),
    let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
    let s = String(data: out, encoding: .utf8)
  else { return raw }
  return s
}

final class HermesRunner: @unchecked Sendable {
  let socket: URLSessionWebSocketTask
  let broadcasterID: String
  private let lock = NSLock()
  private var _subscribeResults: [String: String] = [:]  // topic -> result
  private var _notificationCount = 0

  var subscribeResults: [String: String] { lock.lock(); defer { lock.unlock() }; return _subscribeResults }
  var notificationCount: Int { lock.lock(); defer { lock.unlock() }; return _notificationCount }

  init(broadcasterID: String) {
    let url = URL(string: "wss://hermes.twitch.tv/v1?clientId=\(webClientID)")!
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
    self.socket = URLSession(configuration: .default).webSocketTask(with: req)
    self.broadcasterID = broadcasterID
  }

  func start(token: String?) {
    socket.resume()
    if let token, !token.isEmpty {
      send(authenticateFrame(token: token), note: "authenticate")
    }
    for t in topicTemplates {
      let topic = t.topic.replacingOccurrences(of: "%@", with: broadcasterID)
      send(subscribeFrame(topic: topic), note: "subscribe \(t.label) → \(topic)")
    }
  }

  func send(_ text: String, note: String) {
    socket.send(.string(text)) { error in
      if let error { print("   ⚠️  send failed (\(note)): \(error)") }
    }
  }

  func receiveLoop() {
    socket.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        print("\n❌ socket closed: \(error)")
        return
      case .success(let frame):
        switch frame {
        case .string(let text): self.handle(text)
        case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
        self.receiveLoop()
      }
    }
  }

  func handle(_ raw: String) {
    guard let d = raw.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
      let type = obj["type"] as? String
    else {
      print("   ?? non-JSON frame: \(raw.prefix(160))")
      return
    }

    switch type {
    case "welcome":
      print("   ✅ welcome — Hermes session open")
    case "authenticateResponse":
      print("   ✅ authenticateResponse: \(obj["authenticateResponse"] ?? "—")")
    case "subscribeResponse":
      let result =
        (obj["subscribeResponse"] as? [String: Any])?["result"] as? String ?? "unknown"
      let sub = obj["subscribeResponse"] as? [String: Any]
      let topic =
        ((sub?["subscription"] as? [String: Any])?["pubsub"] as? [String: Any])?["topic"]
        as? String ?? "?"
      let ok = result.lowercased() == "ok"
      print("   \(ok ? "✅" : "❌") subscribeResponse [\(topic)] → \(result)")
      lock.lock(); _subscribeResults["\(_subscribeResults.count)|\(topic)"] = result; lock.unlock()
    case "keepalive":
      break
    case "reconnect":
      print("   ↻ reconnect requested by Hermes")
    case "notification":
      lock.lock(); _notificationCount += 1; let n = _notificationCount; lock.unlock()
      let inner = (obj["notification"] as? [String: Any])?["pubsub"] as? String ?? "{}"
      print("\n🔔 NOTIFICATION #\(n):")
      print(pretty(inner))
      print("")
    default:
      print("   · \(type): \(raw.prefix(200))")
    }
  }
}

// MARK: - Run

func run(channel: String, seconds: Double) async {
  print("=== Twizz spike — Hermes live events POC ===")
  print("Channel: \(channel)   Listen: \(Int(seconds))s\n")

  let id: String
  let display: String
  do {
    print("[1/3] Resolving broadcaster id (private GQL, anon client-id)…")
    (id, display) = try await resolveBroadcasterID(login: channel)
    print("      ✅ \(display) → id=\(id)\n")
  } catch {
    print("      ❌ \(error)")
    return
  }

  let token = ProcessInfo.processInfo.environment["TWITCH_OAUTH_TOKEN"]
  print("[2/3] Opening Hermes WebSocket\(token != nil ? " (authenticated)" : " (anonymous)")…")
  let runner = HermesRunner(broadcasterID: id)
  runner.receiveLoop()
  runner.start(token: token)

  print(
    "      Subscribing to: \(topicTemplates.map { $0.label }.joined(separator: ", "))\n")
  print("[3/3] Listening for live events (\(Int(seconds))s)…")
  print("      A `subscribeResponse → ok` proves the read path works even before")
  print("      an event fires. Trigger a poll/prediction on the channel to capture one.\n")

  try? await Task.sleep(for: .seconds(seconds))

  let oks = runner.subscribeResults.filter { $0.value.lowercased() == "ok" }.count
  let total = runner.subscribeResults.count
  let notifs = runner.notificationCount
  runner.socket.cancel(with: .goingAway, reason: nil)

  print("\n=== Result ===")
  print("Topic subscriptions accepted: \(oks)/\(total) returned ok")
  print("Live notifications captured:  \(notifs)")
  if oks > 0 {
    print(
      "\n🎉 READ PATH WORKS — Hermes accepts viewer subscriptions to this channel's")
    print("   poll/prediction/hype-train/goal topics. Notifications stream in live.")
    if notifs == 0 {
      print(
        "   (No event fired during the window — that's expected if nothing was live.)")
    }
  } else {
    print("\n❌ No subscriptions were accepted — investigate topic names / auth.")
  }
}

let args = CommandLine.arguments
let channel = args.count > 1 ? args[1] : "twitch"
let seconds = args.count > 2 ? (Double(args[2]) ?? 120) : 120
let sema = DispatchSemaphore(value: 0)
Task {
  await run(channel: channel, seconds: seconds)
  sema.signal()
}
sema.wait()
