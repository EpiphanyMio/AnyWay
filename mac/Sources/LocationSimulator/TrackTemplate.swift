import Foundation

enum TrackSide: String, CaseIterable, Identifiable {
    case left
    case right

    var id: Self { self }
    var title: String { self == .left ? "左侧" : "右侧" }
}

enum TrackTemplateError: LocalizedError {
    case invalidStraight
    case invalidLocation

    var errorDescription: String? {
        switch self {
        case .invalidStraight: "两个端点应标出同一条长直边，相距 20～199 米。"
        case .invalidLocation: "此位置无法生成跑道，请在远离极点的位置选择端点。"
        }
    }
}

struct GeneratedTrack {
    let points: [Coordinate]
    let lengthMeters: Double
    let widthMeters: Double
}

enum TrackTemplate {
    static let targetMeters = 400.0
    private static let arcSegments = 48

    static func generate(from start: Coordinate, to end: Coordinate,
                         side: TrackSide) throws -> GeneratedTrack {
        let midpoint = start.interpolated(to: end, fraction: 0.5)
        guard abs(midpoint.latitude) < 85 else { throw TrackTemplateError.invalidLocation }
        let latitudeScale = 6_371_000.0 * .pi / 180
        let longitudeScale = latitudeScale * cos(midpoint.latitude * .pi / 180)
        var longitudeDelta = end.longitude - start.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        let east = longitudeDelta * longitudeScale
        let north = (end.latitude - start.latitude) * latitudeScale
        let straight = hypot(east, north)
        guard straight >= 20, straight < 200, start.distance(to: end) < 200 else {
            throw TrackTemplateError.invalidStraight
        }
        let alongEast = east / straight
        let alongNorth = north / straight
        let acrossEast = side == .left ? -alongNorth : alongNorth
        let acrossNorth = side == .left ? alongEast : -alongEast

        func coordinate(along: Double, across: Double) throws -> Coordinate {
            let latitude = start.latitude + (along * alongNorth + across * acrossNorth) / latitudeScale
            var longitude = start.longitude
                + (along * alongEast + across * acrossEast) / longitudeScale
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            guard let point = try? Coordinate(latitude: latitude, longitude: longitude) else {
                throw TrackTemplateError.invalidLocation
            }
            return point
        }

        func path(radius: Double) throws -> [Coordinate] {
            var points = [start, end]
            for index in 1...arcSegments {
                let angle = -.pi / 2 + .pi * Double(index) / Double(arcSegments)
                points.append(try coordinate(along: straight + radius * cos(angle),
                                             across: radius + radius * sin(angle)))
            }
            points.append(try coordinate(along: 0, across: 2 * radius))
            for index in 1..<arcSegments {
                let angle = .pi / 2 + .pi * Double(index) / Double(arcSegments)
                points.append(try coordinate(along: radius * cos(angle),
                                             across: radius + radius * sin(angle)))
            }
            points.append(start)
            return points
        }

        func length(_ points: [Coordinate]) -> Double {
            zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }

        var lower = 0.0
        var upper = 500.0
        for _ in 0..<30 {
            let radius = (lower + upper) / 2
            if length(try path(radius: radius)) < targetMeters {
                lower = radius
            } else {
                upper = radius
            }
        }
        let radius = (lower + upper) / 2
        let points = try path(radius: radius)
        return GeneratedTrack(points: points, lengthMeters: length(points), widthMeters: 2 * radius)
    }
}
