import Foundation

extension Array where Element == Coordinate {
    var hasLength: Bool {
        guard let first else { return false }
        return contains { first.distance(to: $0) >= 0.001 }
    }
}

struct LiveRoute {
    private(set) var configuration: RouteConfiguration
    private(set) var lap = 0
    private(set) var previewChanged = true
    private(set) var point: Coordinate
    var finished: Bool { lap >= configuration.passes }
    var isRecovering: Bool { motion.isRecovering }

    private var stepper: RouteStepper
    private var motion: MotionProfile
    private let seed: UInt64
    private let angle: Double
    private let separated: Bool
    private let intervalMultiplier: Double
    private var speedOffset = 0.0

    init(configuration: RouteConfiguration, seed: UInt64, index: Int, count: Int) {
        self.configuration = configuration
        self.seed = seed
        separated = count > 1
        angle = 2 * .pi * Double(index) / Double(count)
        intervalMultiplier = count > 1 ? 0.96 + 0.08 * Double(index) / Double(count - 1) : 1
        motion = MotionProfile(runningSpeed: configuration.speedMetersPerSecond,
                               dynamicSpeed: configuration.dynamicSpeed, seed: seed,
                               plan: configuration.dynamicSpeedPlan, intervalMultiplier: intervalMultiplier)
        stepper = Self.makeStepper(configuration, seed: seed, angle: angle, separated: separated)
        point = stepper.advance(meters: 0)
    }

    mutating func update(_ config: RouteConfiguration) {
        guard config != configuration else { return }
        if config.dynamicSpeed != configuration.dynamicSpeed || config.dynamicSpeedPlan != configuration.dynamicSpeedPlan {
            motion = MotionProfile(runningSpeed: config.speedMetersPerSecond,
                                   dynamicSpeed: config.dynamicSpeed, seed: seed &+ UInt64(lap),
                                   plan: config.dynamicSpeedPlan, intervalMultiplier: intervalMultiplier)
        }
        motion.runningSpeed = config.speedMetersPerSecond
        if config.route != configuration.route || config.pathVariationMeters != configuration.pathVariationMeters {
            let progress = min(1, stepper.distanceTravelled / max(0.001, stepper.totalDistance))
            stepper = Self.makeStepper(config, seed: seed &+ UInt64(lap), angle: angle, separated: separated)
            point = stepper.advance(meters: progress * stepper.totalDistance)
            previewChanged = true
        }
        configuration = config
    }

    mutating func preview() -> [Coordinate] {
        previewChanged = false
        return stepper.preview()
    }

    mutating func advance(seconds: Double) -> Coordinate {
        guard !finished else { return point }
        let jitter = max(separated ? 0.02 : 0, configuration.jitterPercent / 100)
        speedOffset = 0.8 * speedOffset + 0.2 * Double.random(in: -jitter...jitter)
        point = stepper.advance(meters: motion.advance(seconds: seconds, speedMultiplier: 1 + speedOffset))
        if stepper.isFinished {
            lap += 1
            if !finished {
                stepper = Self.makeStepper(configuration, seed: seed &+ UInt64(lap), angle: angle, separated: separated)
                previewChanged = true
            }
        }
        return point
    }

    private static func makeStepper(_ config: RouteConfiguration, seed: UInt64,
                                    angle: Double, separated: Bool) -> RouteStepper {
        let route = RouteLoop.closed(config.route)
        let length = zip(route, route.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let limit = min(config.pathVariationMeters == 0 ? 0.5 : config.pathVariationMeters, length * 0.12)
        let offset = separated ? limit * 0.4 : 0
        return RouteStepper(points: route, variationMeters: limit - offset, seed: seed,
                            eastOffset: offset * cos(angle), northOffset: offset * sin(angle))
    }
}
