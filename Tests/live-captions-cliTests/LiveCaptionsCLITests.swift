import XCTest
@testable import live_captions_cli

final class LiveCaptionsCLITests: XCTestCase {
    func testMakeNDJSONLineIsParsableAndEndsWithNewline() throws {
        let message: [String: Any] = [
            "v": 1,
            "kind": "error",
            "detail": "quote: \"hello\"\nline2"
        ]

        let line = try XCTUnwrap(makeNDJSONLine(message))
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))

        let jsonData = line.dropLast()
        let decoded = try JSONSerialization.jsonObject(with: Data(jsonData), options: []) as? [String: Any]

        XCTAssertEqual(decoded?["v"] as? Int, 1)
        XCTAssertEqual(decoded?["kind"] as? String, "error")
        XCTAssertEqual(decoded?["detail"] as? String, "quote: \"hello\"\nline2")
    }

    func testFinalDeltaTrackerReturnsFullTextThenOnlySuffix() {
        var tracker = FinalDeltaTracker()

        XCTAssertEqual(tracker.nextDelta(fromFullText: "hello"), "hello")
        XCTAssertEqual(tracker.nextDelta(fromFullText: "hello world"), "world")
        XCTAssertNil(tracker.nextDelta(fromFullText: "hello world"))
    }

    func testFinalDeltaTrackerResetsWhenTranscriptShrinks() {
        var tracker = FinalDeltaTracker()

        XCTAssertEqual(tracker.nextDelta(fromFullText: "one two three"), "one two three")
        XCTAssertEqual(tracker.nextDelta(fromFullText: "one"), "one")
    }
}
