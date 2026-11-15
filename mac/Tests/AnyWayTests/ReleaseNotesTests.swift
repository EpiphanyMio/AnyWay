import XCTest
@testable import AnyWay

final class ReleaseNotesTests: XCTestCase {
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
