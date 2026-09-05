import XCTest

@testable import Twozz

final class AltSourceServiceTests: XCTestCase {
  func testNativeClientUsesSameIdentityForAPIAndMedia() throws {
    let request = try AltSourceService.nativePlayerRequest(forVideoID: "abcdefghijk", visitor: "private-visitor")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let context = try XCTUnwrap(body["context"] as? [String: Any])
    let client = try XCTUnwrap(context["client"] as? [String: Any])
    XCTAssertEqual(client["clientName"] as? String, "VISIONOS")
    XCTAssertEqual(client["clientVersion"] as? String, "1.02")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "101")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.02")
    XCTAssertEqual(client["userAgent"] as? String, AltSourceService.mediaHTTPHeaders["User-Agent"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), AltSourceService.mediaHTTPHeaders["User-Agent"])
    XCTAssertEqual(body["videoId"] as? String, "abcdefghijk")
    XCTAssertEqual(client["visitorData"] as? String, "private-visitor")
    XCTAssertNil(client["androidSdkVersion"])
    XCTAssertFalse(AltSourceService.resolverAttributes.values.joined().contains("private"))
  }

  func testNativeClientCanBuildRequestWithoutVisitorContext() throws {
    let request = try AltSourceService.nativePlayerRequest(forVideoID: "abcdefghijk", visitor: nil)
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
  }

  func testNativeHLSIsReturnedUnmodified() throws {
    let data = Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"hlsManifestUrl":"https://manifest.googlevideo.com/master.m3u8?a=1&b=2"}}"#.utf8)
    XCTAssertEqual(
      try AltSourceService.nativeHLSMaster(in: data).absoluteString,
      "https://manifest.googlevideo.com/master.m3u8?a=1&b=2"
    )
  }

  func testDeniedResponseCannotUseAnIncludedManifest() {
    let data = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED"},"streamingData":{"hlsManifestUrl":"https://example.com/master.m3u8"}}"#.utf8)
    XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data)) { error in
      XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "not_playable")
      XCTAssertEqual(AltSourceService.errorAttributes(error)["playability_status"], "LOGIN_REQUIRED")
    }
  }

  func testSABROrProgressiveResponseDoesNotPretendToBeNativeHLS() {
    let data = Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"serverAbrStreamingUrl":"https://example.com/sabr","formats":[]}}"#.utf8)
    XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data)) { error in
      XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "no_native_hls")
    }
  }

  func testInvalidManifestIsRejected() {
    for manifest in ["relative.m3u8", "file:///private/video", "http://example.com/video"] {
      let data = Data("""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"hlsManifestUrl":"\(manifest)"}}
        """.utf8)
      XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data))
    }
  }

  func testDiagnosticsDoNotExposeUntrustedResponseProse() {
    let error = AltSourceService.ResolutionError.notPlayable("private-token https://example.com/signed")
    XCTAssertEqual(AltSourceService.errorAttributes(error)["playability_status"], "unknown")
    XCTAssertEqual(
      AltSourceService.errorAttributes(AltSourceService.ResolutionError.httpStatus(403))["http_status"], "403"
    )
    let network = NSError(domain: NSURLErrorDomain, code: -1009,
                          userInfo: [NSLocalizedDescriptionKey: "private-token https://example.com/signed"])
    let attributes = AltSourceService.errorAttributes(network)
    XCTAssertEqual(attributes["error_code"], "-1009")
    XCTAssertFalse(attributes.values.joined().contains("private-token"))
    XCTAssertFalse(attributes.values.joined().contains("https://"))
  }
}
