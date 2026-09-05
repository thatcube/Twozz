import AVFoundation
import XCTest

@testable import Twozz

@MainActor
final class PlaybackTelemetryTests: XCTestCase {
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func records(in directory: URL) throws -> [PlaybackTelemetryRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
      .flatMap { try Data(contentsOf: $0).split(separator: 0x0A) }
      .map { try decoder.decode(PlaybackTelemetryRecord.self, from: Data($0)) }
      .sorted { $0.sequence < $1.sequence }
  }

  private func waitingSnapshot() -> PlaybackTelemetrySnapshot {
    PlaybackTelemetrySnapshot(
      attributes: ["time_control_status": "waiting", "item_status": "ready", "access_entry": "0"],
      metrics: ["buffer_ahead_seconds": 0, "clock_not_advancing_seconds": 6],
      flags: ["has_started": true, "playback_requested": true, "buffer_empty": true]
    )
  }

  func testClassificationExcludesIntentionalAndStartupWaits() {
    for flag in ["loading", "user_paused", "scrubbing", "seek_pending", "background", "recovering", "offline"] {
      var sample = waitingSnapshot()
      sample.flags[flag] = true
      sample.flags["decode_frozen"] = true
      XCTAssertNil(sample.stallKind, flag)
    }
    var startup = waitingSnapshot()
    startup.flags["has_started"] = false
    XCTAssertEqual(startup.phase, "loading")
    XCTAssertNil(startup.stallKind)
  }

  func testClassificationRequiresClockEvidence() {
    var sample = waitingSnapshot()
    XCTAssertEqual(sample.stallKind, "network_or_buffer")
    sample.metrics["clock_not_advancing_seconds"] = 0
    XCTAssertNil(sample.stallKind, "Waiting alone is not evidence of an interruption")
    sample.metrics["clock_not_advancing_seconds"] = 6
    sample.flags["buffer_empty"] = false
    sample.metrics["buffer_ahead_seconds"] = 8
    XCTAssertEqual(sample.stallKind, "healthy_buffer_wait")
    sample.attributes["time_control_status"] = "playing"
    XCTAssertEqual(sample.stallKind, "playhead_not_advancing")
    sample.flags["decode_frozen"] = true
    XCTAssertEqual(sample.stallKind, "decode_freeze")
  }

  func testSanitizationFiniteMetricsAndSessionLifecycle() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "public-channel", playbackMode: "live")
    recorder.recordEvent(
      "failure",
      attributes: [
        "reason": "twozz-ll://cdn.example/master?token=secret",
        "authorization": "Bearer private-value",
        "detail": #"{"token":"secret-value"} sig=secret-signature oauth:private"#,
        "error": "a raw secret without recognizable formatting",
        "token": "bare-private-value",
        "source_host": "192.0.2.1",
      ],
      metrics: ["buffer": 2, "nan": .nan, "infinity": .infinity]
    )
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(saved.first?.schemaVersion, 1)
    XCTAssertEqual(saved.last?.name, "session_ended")
    XCTAssertEqual(Set(saved.map(\.sessionID)).count, 1)
    let failure = try XCTUnwrap(saved.first { $0.name == "failure" })
    XCTAssertEqual(failure.metrics, ["buffer": 2])
    XCTAssertEqual(failure.attributes["reason"], "<url>")
    XCTAssertNil(failure.attributes["error"])
    XCTAssertNil(failure.attributes["token"])
    XCTAssertEqual(failure.attributes["source_host"], "<address>")
    let strings = failure.attributes.values.joined()
    XCTAssertFalse(strings.contains("secret"))
    XCTAssertFalse(strings.contains("private"))
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: directory.appendingPathComponent("latest-session.json"))) as? [String: Any])
    XCTAssertNotNil(manifest["endedAt"])
  }

  func testErrorAttributesNeverIncludeSDKProseOrServerAddresses() {
    let error = NSError(domain: NSURLErrorDomain, code: -1009,
                        userInfo: [NSLocalizedDescriptionKey: "secret-token https://user:password@host/path"])
    XCTAssertEqual(PlaybackTelemetryRecorder.errorAttributes(error),
                   ["error_domain": NSURLErrorDomain, "error_code": "-1009"])
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://user:password@cdn.example/path?token=secret"), "cdn.example")
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://192.0.2.1/path"), "<address>")
    XCTAssertEqual(PlaybackTelemetryRecorder.host("https://[2001:db8::1]/path"), "<address>")
  }

  func testStallEpisodesAndCounterResets() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "channel", playbackMode: "live")
    let start = ProcessInfo.processInfo.systemUptime
    var sample = waitingSnapshot()
    sample.metrics["playhead_seconds"] = 0
    sample.counters["dropped_video_frames"] = 10
    recorder.recordSnapshot(sample, uptime: start)
    sample.metrics["playhead_seconds"] = 2
    recorder.recordSnapshot(sample, uptime: start + 2)
    recorder.recordSnapshot(sample, uptime: start + 4)
    recorder.recordSnapshot(sample, uptime: start + 6)
    sample.metrics["playhead_seconds"] = 4
    sample.attributes["access_entry"] = "1"
    sample.counters["dropped_video_frames"] = 50
    recorder.recordSnapshot(sample, uptime: start + 8)
    sample.counters["dropped_video_frames"] = 52
    recorder.recordSnapshot(sample, uptime: start + 10)
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    XCTAssertEqual(saved.filter { $0.name == "stall_started" }.count, 1)
    let end = try XCTUnwrap(saved.first { $0.name == "stall_ended" })
    XCTAssertEqual(end.attributes["outcome"], "recovered")
    XCTAssertEqual(end.metrics["duration_seconds"], 2)
    let increases = saved.filter { $0.name == "counter_increased" }
    XCTAssertEqual(increases.count, 1)
    XCTAssertEqual(increases.first?.counters["delta"], 2)
  }

  func testSeekOutcomesAndItemSessionBoundaries() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "one", playbackMode: "live")
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/not-a-video")))
    let first = recorder.beginSeek(target: 5, kind: "test")
    let second = recorder.beginSeek(target: 6, kind: "test")
    XCTAssertFalse(recorder.finishSeek(first, finished: false, actual: 0))
    XCTAssertTrue(recorder.isSeekPending)
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/also-not-a-video")))
    XCTAssertFalse(recorder.isSeekPending)
    XCTAssertFalse(recorder.finishSeek(second, finished: true, actual: 6))
    recorder.beginSession(channel: "two", playbackMode: "vod")
    XCTAssertFalse(recorder.finishSeek(second, finished: true, actual: 6))
    recorder.endSession(reason: "test")
    await recorder.flush()
    let saved = try records(in: directory)
    let seeks = saved.filter { $0.name == "seek_completed" }
    XCTAssertEqual(seeks.count, 2, "A late callback must not enter the next channel session")
    XCTAssertTrue(seeks.allSatisfy { $0.attributes["outcome"] == "superseded" && $0.channel == "one" })
    XCTAssertEqual(Set(saved.filter { $0.channel == "one" }.map(\.sessionID)).count, 1)
    XCTAssertEqual(Set(saved.map(\.sessionID)).count, 2)
  }

  func testSeekDeadlineDoesNotRejectAValidLateLanding() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(directory: directory, mirrorToSystemLog: false))
    recorder.beginSession(channel: "channel", playbackMode: "live")
    recorder.trackItem(AVPlayerItem(url: URL(fileURLWithPath: "/not-a-video")), source: "twitch")
    let seek = recorder.beginSeek(target: 5, kind: "test")
    recorder.recordSnapshot(waitingSnapshot(), uptime: ProcessInfo.processInfo.systemUptime + 16)
    XCTAssertFalse(recorder.isSeekPending)
    XCTAssertTrue(recorder.finishSeek(seek, finished: true, actual: 5))
    XCTAssertFalse(recorder.finishSeek(seek, finished: true, actual: 5))
    recorder.endSession(reason: "test")
    await recorder.flush()
    XCTAssertTrue(try records(in: directory).contains { $0.name == "seek_deadline_exceeded" })
  }

  func testRotationRetentionAndBoundedQueue() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = DispatchQueue(label: "telemetry-test")
    let writer = PlaybackTelemetryWriter(directory: directory, maximumFileBytes: 1_024, maximumFiles: 3,
                                          maximumPending: 2, mirrorToSystemLog: false, queue: queue)
    let recorder = PlaybackTelemetryRecorder(writer: writer)
    queue.suspend()
    recorder.beginSession(channel: "channel", playbackMode: "live")
    recorder.recordEvent("queued")
    recorder.recordEvent("dropped")
    queue.resume()
    await recorder.flush()
    recorder.recordEvent("after_overflow")
    await recorder.flush()
    var saved = try records(in: directory)
    XCTAssertFalse(saved.contains { $0.name == "dropped" })
    XCTAssertEqual(saved.first { $0.name == "after_overflow" }?.counters["telemetry_records_dropped"], 1)
    for _ in 0..<12 {
      recorder.recordEvent("rotate", attributes: ["detail": String(repeating: "x", count: 300)])
      await recorder.flush()
    }
    recorder.endSession(reason: "test")
    await recorder.flush()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
    XCTAssertEqual(files.count, 3)
    for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_024) }
    saved = try records(in: directory)
    XCTAssertEqual(saved.last?.name, "session_ended")
    XCTAssertGreaterThan(try XCTUnwrap(saved.first?.sequence), 1)
    XCTAssertEqual(Set(saved.map(\.sequence)).count, saved.count)
  }
}
