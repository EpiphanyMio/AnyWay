import Foundation

struct Coordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    private init(uncheckedLatitude: Double, longitude: Double) {
        self.latitude = uncheckedLatitude
        self.longitude = longitude
    }

    init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude) else {
            throw RouteError.invalidCoordinate
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    var simctlArgument: String {
        String(format: "%.8f,%.8f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    var isValid: Bool {
        latitude.isFinite && (-90...90).contains(latitude)
            && longitude.isFinite && (-180...180).contains(longitude)
    }

    func distance(to other: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }

    func interpolated(to other: Coordinate, fraction: Double) -> Coordinate {
        let t = min(1, max(0, fraction))
        var longitudeDelta = other.longitude - longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        var newLongitude = longitude + longitudeDelta * t
        if newLongitude > 180 { newLongitude -= 360 }
        if newLongitude < -180 { newLongitude += 360 }
        // Valid endpoints and a clamped fraction keep the interpolated values in range.
        return Coordinate(uncheckedLatitude: latitude + (other.latitude - latitude) * t,
                          longitude: newLongitude)
    }
}

enum RouteError: LocalizedError {
    case invalidCoordinate
    case invalidLine(Int)
    case tooFewPoints

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: "纬度须在 -90～90，经度须在 -180～180。"
        case .invalidLine(let line): "第 \(line) 行格式有误。每行输入：纬度,经度"
        case .tooFewPoints: "路径至少需要两个坐标点。"
        }
    }
}

enum RouteParser {
    static func coordinate(latitude: String, longitude: String) throws -> Coordinate {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RouteError.invalidCoordinate
        }
        return try Coordinate(latitude: lat, longitude: lon)
    }

    static func parse(_ text: String) throws -> [Coordinate] {
        var points: [Coordinate] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let pieces = line.split(separator: ",", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let coordinate = try? coordinate(latitude: String(pieces[0]), longitude: String(pieces[1])) else {
                throw RouteError.invalidLine(index + 1)
            }
            points.append(coordinate)
        }
        guard points.count >= 2 else { throw RouteError.tooFewPoints }
        return points
    }
}

struct RouteStepper: Sendable {
    let points: [Coordinate]
    let variationMeters: Double
    let seed: UInt64
    private let totalDistance: Double
    private(set) var segment = 0
    private(set) var distanceIntoSegment = 0.0
    private(set) var distanceTravelled = 0.0

    init(points: [Coordinate], variationMeters: Double = 0, seed: UInt64 = 0) {
        precondition(points.count >= 2)
        precondition(variationMeters.isFinite && variationMeters >= 0)
        self.points = points
        self.variationMeters = variationMeters
        self.seed = seed
        self.totalDistance = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + pair.0.distance(to: pair.1)
        }
    }

    var isFinished: Bool { segment >= points.count - 1 }

    mutating func advance(meters: Double) -> Coordinate {
        var remaining = max(0, meters)
        while !isFinished {
            let length = points[segment].distance(to: points[segment + 1])
            if length < 0.001 {
                segment += 1
                distanceIntoSegment = 0
                continue
            }
            let available = length - distanceIntoSegment
            if remaining < available {
                distanceIntoSegment += remaining
                distanceTravelled += remaining
                let start = points[segment]
                let end = points[segment + 1]
                let progress = distanceIntoSegment / length
                let center = start.interpolated(to: end, fraction: progress)
                guard variationMeters > 0 else { return center }
                let drift = positionDrift(distance: distanceTravelled)
                return center.offset(eastMeters: drift.east, northMeters: drift.north)
            }
            remaining -= available
            distanceTravelled += available
            segment += 1
            distanceIntoSegment = 0
        }
        return points[points.count - 1]
    }

    private func positionDrift(distance: Double) -> (east: Double, north: Double) {
        guard totalDistance > 0 else { return (0, 0) }
        var random = SplitMix64(seed: seed)
        let eastPhase1 = random.unit() * 2 * Double.pi
        let eastPhase2 = random.unit() * 2 * Double.pi
        let northPhase1 = random.unit() * 2 * Double.pi
        let northPhase2 = random.unit() * 2 * Double.pi
        let wavelength1 = 35 + random.unit() * 35
        let wavelength2 = 12 + random.unit() * 18
        let wavelength3 = 35 + random.unit() * 35
        let wavelength4 = 12 + random.unit() * 18
        let east = 0.7 * sin(2 * Double.pi * distance / wavelength1 + eastPhase1)
                 + 0.3 * sin(2 * Double.pi * distance / wavelength2 + eastPhase2)
        let north = 0.7 * sin(2 * Double.pi * distance / wavelength3 + northPhase1)
                  + 0.3 * sin(2 * Double.pi * distance / wavelength4 + northPhase2)
        // The drift is continuous at intermediate points and vanishes at route endpoints.
        let envelope = pow(sin(Double.pi * min(1, distance / totalDistance)), 2)
        let limit = min(variationMeters, totalDistance * 0.12)
        let scale = limit * envelope / max(1, hypot(east, north))
        return (east * scale, north * scale)
    }
}

private extension Coordinate {
    func offset(eastMeters: Double, northMeters: Double) -> Coordinate {
        guard hypot(eastMeters, northMeters) > 0.000001, abs(latitude) < 89.9 else { return self }
        let radius = 6_371_000.0
        let shiftedLatitude = latitude + northMeters / radius * 180 / .pi
        let longitudeScale = radius * cos(shiftedLatitude * .pi / 180)
        guard abs(shiftedLatitude) <= 90, abs(longitudeScale) > 0.001 else { return self }
        var shiftedLongitude = longitude + eastMeters / longitudeScale * 180 / .pi
        if shiftedLongitude > 180 { shiftedLongitude -= 360 }
        if shiftedLongitude < -180 { shiftedLongitude += 360 }
        return Coordinate(uncheckedLatitude: shiftedLatitude, longitude: shiftedLongitude)
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func unit() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }
}

enum RoutePreview {
    static func sample(points: [Coordinate], variationMeters: Double,
                       seed: UInt64, maximumSamples: Int = 4_000) -> [Coordinate] {
        guard points.count >= 2 else { return points }
        let totalDistance = zip(points, points.dropFirst())
            .reduce(0.0) { total, pair in total + pair.0.distance(to: pair.1) }
        let spacing = max(4, totalDistance / Double(max(2, maximumSamples - 1)))
        var stepper = RouteStepper(points: points, variationMeters: variationMeters, seed: seed)
        var sample = [points[0]]
        while !stepper.isFinished && sample.count < maximumSamples {
            sample.append(stepper.advance(meters: spacing))
        }
        if sample.last != points.last { sample.append(points[points.count - 1]) }
        return sample
    }
}
