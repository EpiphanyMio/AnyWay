import XCTest
@testable import AnyWay

final class ReleaseNotesTests: XCTestCase {
    @MainActor
    func testNewerReleasePromptsAfterIgnoredVersion() {
        XCTAssertTrue(UpdateChecker.shouldPrompt(current: "0.2.0", latest: "0.2.9", ignoredThrough: ""))
        XCTAssertFalse(UpdateChecker.shouldPrompt(current: "0.2.0", latest: "0.2.9", ignoredThrough: "0.2.9"))
        XCTAssertFalse(UpdateChecker.shouldPrompt(current: "0.2.0", latest: "0.2.8", ignoredThrough: "0.2.9"))
        XCTAssertTrue(UpdateChecker.shouldPrompt(current: "0.2.0", latest: "0.2.10", ignoredThrough: "0.2.9"))
    }

    func testReleaseNotesMatchProductVersion() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let version = try! String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = ReleaseNotes.load(currentVersion: version)
        XCTAssertNotNil(notes)
        XCTAssertFalse(notes?.highlights.isEmpty ?? true)
        XCTAssertFalse(notes?.fixes.isEmpty ?? true)
        XCTAssertNil(ReleaseNotes.load(currentVersion: "0.0.0"))
    }
}
