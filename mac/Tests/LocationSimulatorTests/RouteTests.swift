import AppKit
import MapKit
import XCTest
@testable import LocationSimulator

final class RouteTests: XCTestCase {
    func testReleaseVersionOrdersNumericComponents() {
        XCTAssertTrue(ReleaseVersion("v0.1.10")! > ReleaseVersion("0.1.9")!)
        XCTAssertNil(ReleaseVersion("v0.1.1-beta"))
        XCTAssertNil(ReleaseVersion("0.1"))
    }

    func testRoutePointMovesThroughMouseDownDragAndUp() throws {
        let start = try Coordinate(latitude: 39.9, longitude: 116.4)
        let end = try Coordinate(latitude: 39.901, longitude: 116.401)
        var moved: (Int, Coordinate)?
        var clicks = 0
        let route = RouteMapView(points: [start, end], previewRoute: [], variationMeters: 0,
                                 previewSeed: 1, fitRevision: 0, searchCoordinate: nil,
                                 searchTitle: "", focusRevision: 0, singlePoint: nil,
                                 editable: true, onPointMoved: { moved = ($0, $1) },
                                 onMapClick: { _ in clicks += 1 })
        let coordinator = RouteMapView.Coordinator(route)
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
                                         span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
                      animated: false)
        coordinator.mapView = map
        let annotation = RoutePointAnnotation()
        annotation.index = 0
        annotation.coordinate = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        map.addAnnotation(annotation)

        let origin = map.convert(annotation.coordinate, toPointTo: map)
        let destination = NSPoint(x: origin.x + 80, y: origin.y + 30)
        XCTAssertTrue(coordinator.handleMouseInteraction(.leftMouseDown, at: origin, on: map))
        XCTAssertTrue(coordinator.handleMouseInteraction(.leftMouseUp, at: origin, on: map))
        XCTAssertNil(moved)

        XCTAssertTrue(coordinator.handleMouseInteraction(.leftMouseDown, at: origin, on: map))
        XCTAssertTrue(coordinator.handleMouseInteraction(.leftMouseDragged, at: destination, on: map))
        XCTAssertTrue(coordinator.handleMouseInteraction(.leftMouseUp, at: destination, on: map))
        let expected = map.convert(destination, toCoordinateFrom: map)
        let result = try XCTUnwrap(moved)
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1.latitude, expected.latitude, accuracy: 0.000001)
        XCTAssertEqual(result.1.longitude, expected.longitude, accuracy: 0.000001)
        XCTAssertEqual(clicks, 0)
    }

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
                                            passes: 3, pathVariationMeters: 2.5,
                                            dynamicSpeed: true,
                                            dynamicSpeedPlan: DynamicSpeedPlan(
                                                mode: .custom, preset: .campus,
                                                intervalKilometers: 1.2,
                                                lowPaceSeconds: 900,
                                                recoverySeconds: 30))
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

    func testLoopClosesOnceAndAdjacentLapsMeetAtStart() throws {
        let a = try Coordinate(latitude: 0, longitude: 0)
        let b = try Coordinate(latitude: 0, longitude: 0.001)
        let c = try Coordinate(latitude: 0.001, longitude: 0.001)
        let loop = RouteLoop.closed([a, b, c])
        XCTAssertEqual(loop, [a, b, c, a])
        XCTAssertEqual(RouteLoop.closed(loop), loop)
        var first = RouteStepper(points: loop, variationMeters: 2, seed: 1)
        var second = RouteStepper(points: loop, variationMeters: 2, seed: 2)
        XCTAssertEqual(first.advance(meters: 1_000), a)
        XCTAssertEqual(second.advance(meters: 0), a)
        let firstPosition = RoutePreview.sample(points: loop, variationMeters: 2, seed: 1)[20]
        let secondPosition = RoutePreview.sample(points: loop, variationMeters: 2, seed: 2)[20]
        XCTAssertGreaterThan(firstPosition.distance(to: secondPosition), 0.01)
    }

    func testPaceConversionAndDynamicRecovery() {
        XCTAssertEqual(RunningPace.speed(minutes: 5, seconds: 0)!, 1_000 / 300.0)
        XCTAssertEqual(RunningPace.components(speed: 5)?.minutes, 3)
        XCTAssertEqual(RunningPace.components(speed: 5)?.seconds, 20)
        XCTAssertNil(RunningPace.speed(minutes: 0, seconds: 0))
        XCTAssertNil(RunningPace.speed(minutes: 4, seconds: 60))

        var steady = MotionProfile(runningSpeed: 4, dynamicSpeed: false, seed: 1)
        XCTAssertEqual(steady.advance(seconds: 10), 40)
        var dynamic = MotionProfile(runningSpeed: 4, dynamicSpeed: true, seed: 1)
        var distance = 0.0
        while !dynamic.isRecovering && distance < 1_100 {
            distance += dynamic.advance(seconds: 1)
        }
        XCTAssertGreaterThanOrEqual(distance, 600)
        XCTAssertLessThanOrEqual(distance, 1_000.5)
        let walkingDistance = dynamic.advance(seconds: 1)
        XCTAssertGreaterThan(walkingDistance, 0)
        XCTAssertLessThanOrEqual(walkingDistance, 1.4)
        _ = dynamic.advance(seconds: 40)
        XCTAssertFalse(dynamic.isRecovering)

        let customPlan = DynamicSpeedPlan(mode: .custom, preset: .campus,
                                          intervalKilometers: 1.5,
                                          lowPaceSeconds: 600, recoverySeconds: 20)
        XCTAssertTrue(customPlan.isValid(baseSpeed: 4))
        var custom = MotionProfile(runningSpeed: 4, dynamicSpeed: true, seed: 1,
                                   plan: customPlan)
        XCTAssertEqual(custom.advance(seconds: 374), 1_496, accuracy: 0.001)
        XCTAssertFalse(custom.isRecovering)
        XCTAssertEqual(custom.advance(seconds: 1), 4, accuracy: 0.001)
        XCTAssertTrue(custom.isRecovering)
        XCTAssertEqual(custom.advance(seconds: 1), 1_000.0 / 600.0, accuracy: 0.001)
        XCTAssertFalse(DynamicSpeedPlan(mode: .custom, preset: .campus,
                                        intervalKilometers: 0.05,
                                        lowPaceSeconds: 600, recoverySeconds: 20)
                        .isValid(baseSpeed: 4))
    }

    func testFourHundredMeterTrackFromStraightEndpoints() throws {
        let start = try Coordinate(latitude: 39.9, longitude: 116.4)
        let end = try Coordinate(latitude: 39.9, longitude: 116.401)
        let left = try TrackTemplate.generate(from: start, to: end, side: .left)
        let right = try TrackTemplate.generate(from: start, to: end, side: .right)
        XCTAssertEqual(left.points.first, start)
        XCTAssertEqual(left.points[1], end)
        XCTAssertEqual(left.points.last, start)
        XCTAssertEqual(left.points.count, 99)
        XCTAssertEqual(left.lengthMeters, 400, accuracy: 0.05)
        XCTAssertEqual(right.lengthMeters, 400, accuracy: 0.05)
        XCTAssertGreaterThan(left.points[50].latitude, start.latitude)
        XCTAssertLessThan(right.points[50].latitude, start.latitude)
        XCTAssertThrowsError(try TrackTemplate.generate(from: start, to: start,
                                                        side: .left))
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
        XCTAssertFalse(config.dynamicSpeed)
        XCTAssertEqual(config.dynamicSpeedPlan, .standard)
        let withDynamicSpeed = json.replacingOccurrences(of: "\"passes\": 2",
                                                          with: "\"passes\": 2, \"dynamicSpeed\": true")
        XCTAssertEqual(try ConfigurationCodec.decode(Data(withDynamicSpeed.utf8))
            .dynamicSpeedPlan, .standard)
    }

    func testSchoolSearchRecognizesSportsGroundSeparately() {
        XCTAssertTrue(SchoolSearchRules.isSchool(name: "北京大学"))
        XCTAssertTrue(SchoolSearchRules.isSchool(name: "MIT", category: "university"))
        XCTAssertTrue(SchoolSearchRules.isSchool(name: "Sports University", category: "school"))
        XCTAssertFalse(SchoolSearchRules.isSchool(name: "北京大学附属医院", category: "hospital"))
        XCTAssertFalse(SchoolSearchRules.isSchool(name: "北京大学运动场", category: "school"))
        XCTAssertTrue(SchoolSearchRules.isSportsGround(name: "北京大学运动场"))
        XCTAssertTrue(SchoolSearchRules.isSportsGround(name: "北京大学篮球场"))
        XCTAssertTrue(SchoolSearchRules.isSportsGround(name: "校园操场"))
        XCTAssertTrue(SchoolSearchRules.isSportsGround(name: "Unnamed", category: "basketballCourt"))
        XCTAssertFalse(SchoolSearchRules.isSchool(name: "北京大学篮球场", category: "school"))
        XCTAssertEqual(SchoolSearchRules.sportsQuery(for: "北京大学"), "北京大学 运动场")
        XCTAssertEqual(SchoolSearchRules.expandedQuery("浙大"), "浙江大学")
        XCTAssertEqual(SchoolSearchRules.expandedQuery("北邮沙河校区"), "北京邮电大学沙河校区")
        XCTAssertEqual(SchoolSearchRules.expandedQuery("上海大学"), "上海大学")
        XCTAssertTrue(SchoolSearchRules.isCampus("北京邮电大学（沙河校区）", of: "北京邮电大学"))
        XCTAssertTrue(SchoolSearchRules.isCampus("北京大学昌平分校", of: "北京大学"))
        XCTAssertFalse(SchoolSearchRules.isCampus("北京大学", of: "北京大学"))
        XCTAssertFalse(SchoolSearchRules.isCampus("清华大学沙河校区", of: "北京大学"))
        let campus = PlaceResult.knownCampus(matching: "北京邮电大学沙河校区")
        XCTAssertEqual(campus?.name, "北京邮电大学（沙河校区）")
        XCTAssertEqual(campus?.coordinate.latitude, 40.15608)
        XCTAssertNotNil(PlaceResult.knownCampus(matching: "北邮沙河校区"))
        XCTAssertNil(PlaceResult.knownCampus(matching: "北京邮电大学"))
    }

    func testSearchHistoryDeduplicatesAndKeepsRecentTwelve() {
        var history = SearchHistory()
        history.record("  北京大学  ")
        history.record("beijing")
        history.record("BEIJING")
        XCTAssertEqual(history.entries, ["BEIJING", "北京大学"])
        for index in 0..<15 { history.record("地点\(index)") }
        XCTAssertEqual(history.entries.count, 12)
        XCTAssertEqual(history.entries.first, "地点14")
        XCTAssertEqual(history.entries.last, "地点3")
        history.record("  ")
        XCTAssertEqual(history.entries.count, 12)
    }

    func testRouteDraftPersistsUnappliedTextAndCanBeCleared() throws {
        let suite = "LocationSimulatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let point = try Coordinate(latitude: 39.9, longitude: 116.4)
        let draft = RouteDraft(name: "操场", latitude: "39.9", longitude: "116.4",
                               points: [point], routeText: "39.9,116.4\n待修改",
                               textPending: true, speed: "3.5", jitter: "10", passes: "5",
                               pathVariation: "2", dynamicSpeed: true,
                               dynamicSpeedDraft: DynamicSpeedDraft(
                                mode: .custom, preset: .easy,
                                intervalKilometers: "1.2", lowPaceMinutes: "10",
                                lowPaceSeconds: "0", recoverySeconds: "25"),
                               editorMode: 1)
        let store = RouteDraftStore(defaults: defaults)
        XCTAssertTrue(store.save(draft))
        XCTAssertEqual(store.load(), draft)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
            as? [String: Any])
        legacy.removeValue(forKey: "dynamicSpeedDraft")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(RouteDraft.self, from: legacyData).dynamicSpeedDraft)
        store.clear()
        XCTAssertNil(store.load())
    }
}
