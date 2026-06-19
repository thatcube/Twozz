import XCTest

@testable import Twizz

final class PlaybackServiceParseMasterTests: XCTestCase {
  private let master = [
    "#EXTM3U",
    "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"chunked\",NAME=\"1080p60\",DEFAULT=YES",
    "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,VIDEO=\"chunked\",STABLE-VARIANT-ID=\"chunked\",IVS-NAME=\"1080p60\",IVS-VARIANT-SOURCE=\"source\"",
    "https://video.example/chunked.m3u8",
    "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"720p60\",NAME=\"720p60\",DEFAULT=NO",
    "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,VIDEO=\"720p60\",STABLE-VARIANT-ID=\"720p60\",IVS-NAME=\"720p60\"",
    "https://video.example/720p60.m3u8",
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio_only\",NAME=\"audio_only\",DEFAULT=NO",
    "#EXT-X-STREAM-INF:BANDWIDTH=160000,VIDEO=\"audio_only\",STABLE-VARIANT-ID=\"audio_only\",IVS-NAME=\"audio_only\"",
    "https://video.example/audio.m3u8",
  ].joined(separator: "\n")

  func testParsesAllVariants() {
    XCTAssertEqual(PlaybackService.parseMaster(master).count, 3)
  }

  func testOrdersVideoByBitrateThenAudioLast() {
    let qualities = PlaybackService.parseMaster(master)
    XCTAssertEqual(qualities.map(\.name), ["1080p60 (Source)", "720p60", "Audio Only"])
    XCTAssertEqual(qualities.first?.isAudioOnly, false)
    XCTAssertEqual(qualities.last?.isAudioOnly, true)
  }

  func testSourceVariantGetsSourceSuffixAndBitrate() {
    let source = PlaybackService.parseMaster(master).first
    XCTAssertEqual(source?.name, "1080p60 (Source)")
    XCTAssertEqual(source?.bitrate, 6_000_000)
    XCTAssertEqual(source?.url, URL(string: "https://video.example/chunked.m3u8"))
  }

  func testVariantWithoutResolutionIsAudioOnly() {
    let audio = PlaybackService.parseMaster(master).first { $0.isAudioOnly }
    XCTAssertEqual(audio?.name, "Audio Only")
    XCTAssertEqual(audio?.url, URL(string: "https://video.example/audio.m3u8"))
  }

  func testEmptyPlaylistYieldsNoVariants() {
    XCTAssertTrue(PlaybackService.parseMaster("#EXTM3U\n").isEmpty)
  }
}
