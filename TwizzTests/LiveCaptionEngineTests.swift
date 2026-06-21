import XCTest

@testable import Twizz

/// Covers the master→media playlist resolution the caption engine uses so it can
/// pull audio from a master playlist (e.g. the YouTube simulcast hands us a
/// master, not a media, playlist) instead of silently finding no segments.
@available(tvOS 26.0, *)
final class LiveCaptionEngineTests: XCTestCase {
  private let base = URL(string: "https://manifest.example/hls/index.m3u8")!

  func testPrefersAudioRendition() {
    let master = [
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"audio\",DEFAULT=YES,URI=\"audio/playlist.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO=\"audio\"",
      "video/720.m3u8",
    ].joined(separator: "\n")
    XCTAssertEqual(
      LiveCaptionEngine.selectMediaPlaylist(fromMaster: master, relativeTo: base)?.absoluteString,
      "https://manifest.example/hls/audio/playlist.m3u8")
  }

  func testPicksLowestBandwidthVariantWhenNoAudioRendition() {
    let master = [
      "#EXTM3U",
      "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720",
      "720.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=256x144",
      "144.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=640x360",
      "360.m3u8",
    ].joined(separator: "\n")
    XCTAssertEqual(
      LiveCaptionEngine.selectMediaPlaylist(fromMaster: master, relativeTo: base)?.absoluteString,
      "https://manifest.example/hls/144.m3u8")
  }

  func testReturnsNilForMediaPlaylist() {
    let media = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:2",
      "#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:00.000Z",
      "#EXTINF:2.000,",
      "seg0.ts",
      "#EXTINF:2.000,",
      "seg1.ts",
    ].joined(separator: "\n")
    XCTAssertNil(LiveCaptionEngine.selectMediaPlaylist(fromMaster: media, relativeTo: base))
  }
}
