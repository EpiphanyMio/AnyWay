import XCTest
@testable import AnyWay

final class LiveRouteTests: XCTestCase {
    func testEditsUseNewSpeedAndGeometryWithoutRestartingLap() throws {
        let origin = try Coordinate(latitude: 30, longitude: 120)
        let end = try Coordinate(latitude: 30.002, longitude: 120)
        let moved = try Coordinate(latitude: 30.004, longitude: 120)
        let initial = try config([origin, end], runs: 2)
        var runner = LiveRoute(configuration: initial, seed: 12, index: 0, count: 1)
        let before = runner.advance(seconds: 10)
        let updated = try config([origin, moved], speed: 10, runs: 3)
        runner.update(updated)
        XCTAssertEqual(runner.lap, 0)
        XCTAssertEqual(runner.configuration.passes, 3)
        XCTAssertTrue(runner.previewChanged)
        XCTAssertEqual(origin.distance(to: runner.point), 2 * origin.distance(to: before), accuracy: 1)
        let rejoined = runner.point
        XCTAssertEqual(rejoined.distance(to: runner.advance(seconds: 1)), 10, accuracy: 1)
    }

    func testSharedRouteHasDifferentStartsAndBoundedPerLapDrift() throws {
        let origin = try Coordinate(latitude: 30, longitude: 120)
        let end = try Coordinate(latitude: 30.001, longitude: 120)
        let shared = try config([origin, end], runs: 2)
        var first = LiveRoute(configuration: shared, seed: 12, index: 0, count: 2)
        var second = LiveRoute(configuration: shared, seed: 31, index: 1, count: 2)
        XCTAssertGreaterThan(first.point.distance(to: second.point), 1)
        let firstLap = first.preview()
        XCTAssertNotEqual(firstLap, second.preview())
        XCTAssertLessThanOrEqual(firstLap.map { abs($0.longitude - origin.longitude) * 96_300 }.max()!, 2.01)
        _ = first.advance(seconds: 100)
        XCTAssertEqual(first.lap, 1)
        XCTAssertNotEqual(first.preview(), firstLap)
    }

    private func config(_ path: [Coordinate], speed: Double = 5, runs: Int) throws -> RouteConfiguration {
        try RouteConfiguration(name: "路线", point: path[0], route: path, speedMetersPerSecond: speed,
                               jitterPercent: 0, passes: runs)
    }
}
