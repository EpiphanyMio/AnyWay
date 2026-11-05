import XCTest
@testable import LocationSimulator

final class RouteTests: XCTestCase {
    func testParserReportsLineAndRejectsOutOfRangeCoordinate() throws {
        XCTAssertThrowsError(try RouteParser.parse("39.9,116.4\n91,116.5")) { error in
            guard case RouteError.invalidLine(2) = error else {
                return XCTFail("Expected invalid line 2, got \(error)")
            }
        }
    }

    func testStepperCrossesSegmentsAndStopsAtLastPoint() throws {
        let a = try Coordinate(latitude: 0, longitude: 0)
        let b = try Coordinate(latitude: 0, longitude: 0.001)
        let c = try Coordinate(latitude: 0, longitude: 0.002)
        var stepper = RouteStepper(points: [a, b, c])
        let halfway = stepper.advance(meters: a.distance(to: c) / 2)
        XCTAssertEqual(halfway.longitude, b.longitude, accuracy: 0.000001)
        XCTAssertFalse(stepper.isFinished)
        XCTAssertEqual(stepper.advance(meters: 1_000), c)
        XCTAssertTrue(stepper.isFinished)
    }

    func testInterpolationAcrossDateLine() throws {
        let a = try Coordinate(latitude: 0, longitude: 179)
        let b = try Coordinate(latitude: 0, longitude: -179)
        XCTAssertEqual(a.interpolated(to: b, fraction: 0.5).longitude, 180)
    }

    func testConfigurationRoundTripAndValidation() throws {
        let a = try Coordinate(latitude: 39.9042, longitude: 116.4074)
        let b = try Coordinate(latitude: 39.9050, longitude: 116.4085)
        let config = try RouteConfiguration(name: "北京步行", point: a, route: [a, b],
                                            speedMetersPerSecond: 1.5, jitterPercent: 12,
                                            passes: 3, pathVariationMeters: 2.5)
        XCTAssertEqual(try ConfigurationCodec.decode(ConfigurationCodec.encode(config)), config)
        XCTAssertThrowsError(try RouteConfiguration(name: "错误", point: a, route: [a, b],
                                                      speedMetersPerSecond: 1.5,
                                                      jitterPercent: 120, passes: 3))
    }

    func testRouteVariesBetweenPassesWithinConfiguredDistance() throws {
        let start = try Coordinate(latitude: 0, longitude: 0)
        let end = try Coordinate(latitude: 0, longitude: 0.004)
        let distance = start.distance(to: end)
        let center = start.interpolated(to: end, fraction: 0.37)
        var first = RouteStepper(points: [start, end], variationMeters: 3, seed: 1)
        var second = RouteStepper(points: [start, end], variationMeters: 3, seed: 2)
        let firstPosition = first.advance(meters: distance * 0.37)
        let secondPosition = second.advance(meters: distance * 0.37)
        XCTAssertLessThanOrEqual(center.distance(to: firstPosition), 3.01)
        XCTAssertLessThanOrEqual(center.distance(to: secondPosition), 3.01)
        XCTAssertGreaterThan(firstPosition.distance(to: secondPosition), 0.01)
        XCTAssertEqual(first.advance(meters: distance), end)
        XCTAssertEqual(second.advance(meters: distance), end)
    }

    func testDriftContinuesAcrossIntermediateWaypoint() throws {
        let start = try Coordinate(latitude: 0, longitude: 0)
        let middle = try Coordinate(latitude: 0, longitude: 0.000045)
        let end = try Coordinate(latitude: 0, longitude: 0.00009)
        let firstLeg = start.distance(to: middle)
        var stepper = RouteStepper(points: [start, middle, end], variationMeters: 2, seed: 1)
        let before = stepper.advance(meters: firstLeg - 0.01)
        let atWaypoint = stepper.advance(meters: 0.01)
        let after = stepper.advance(meters: 0.01)
        XCTAssertGreaterThan(atWaypoint.distance(to: middle), 0.05)
        XCTAssertLessThan(atWaypoint.distance(to: middle), 1.3)
        XCTAssertLessThan(before.distance(to: atWaypoint), 0.1)
        XCTAssertLessThan(atWaypoint.distance(to: after), 0.1)
    }

    func testOldConfigurationDefaultsToTwoMetersVariation() throws {
        let json = """
        {
          "schemaVersion": 1, "name": "旧配置",
          "point": {"latitude": 0, "longitude": 0},
          "route": [{"latitude": 0, "longitude": 0}, {"latitude": 0, "longitude": 0.001}],
          "speedMetersPerSecond": 3, "jitterPercent": 10, "passes": 2
        }
        """
        let config = try ConfigurationCodec.decode(Data(json.utf8))
        XCTAssertEqual(config.pathVariationMeters, 2)
    }

    func testSchoolSearchRecognizesSportsGroundSeparately() {
        XCTAssertTrue(SchoolSearchRules.isSchool(name: "北京大学"))
        XCTAssertTrue(SchoolSearchRules.isSchool(name: "MIT", category: "university"))
        XCTAssertFalse(SchoolSearchRules.isSchool(name: "北京大学附属医院", category: "hospital"))
        XCTAssertFalse(SchoolSearchRules.isSchool(name: "北京大学运动场", category: "school"))
        XCTAssertTrue(SchoolSearchRules.isSportsGround(name: "北京大学运动场"))
        XCTAssertEqual(SchoolSearchRules.sportsQuery(for: "北京大学"), "北京大学 运动场")
    }
}
