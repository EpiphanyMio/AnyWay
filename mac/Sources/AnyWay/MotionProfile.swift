import Foundation

enum RunningPace {
    static func speed(minutes: Int, seconds: Int) -> Double? {
        guard minutes >= 0, (0...59).contains(seconds),
              minutes <= (Int.max - seconds) / 60,
              minutes > 0 || seconds > 0 else {
            return nil
        }
        return 1_000 / Double(minutes * 60 + seconds)
    }

    static func components(speed: Double) -> (minutes: Int, seconds: Int)? {
        guard speed.isFinite, speed > 0 else { return nil }
        let totalSeconds = 1_000 / speed
        guard totalSeconds.isFinite, totalSeconds < Double(Int.max) else { return nil }
        let rounded = max(1, Int(totalSeconds.rounded()))
        return (rounded / 60, rounded % 60)
    }
}

enum DynamicSpeedMode: String, Codable, CaseIterable {
    case automatic
    case custom

    var title: String { self == .automatic ? "自动配置" : "自定义" }
}

enum DynamicSpeedPreset: String, Codable, CaseIterable {
    case campus
    case easy
    case endurance

    var title: String {
        switch self {
        case .campus: "间歇慢跑"
        case .easy: "轻松跑"
        case .endurance: "耐力跑"
        }
    }

    var description: String {
        switch self {
        case .campus: "每 0.6～1.0 公里慢走 18～35 秒"
        case .easy: "每 0.4～0.7 公里慢走 25～40 秒"
        case .endurance: "每 1.2～1.8 公里慢走 15～25 秒"
        }
    }

    var intervalMeters: ClosedRange<Double> {
        switch self {
        case .campus: 600...1_000
        case .easy: 400...700
        case .endurance: 1_200...1_800
        }
    }

    var recoverySeconds: ClosedRange<Double> {
        switch self {
        case .campus: 18...35
        case .easy: 25...40
        case .endurance: 15...25
        }
    }

    var walkingSpeed: ClosedRange<Double> {
        switch self {
        case .campus: 1.1...1.4
        case .easy: 0.9...1.2
        case .endurance: 1.2...1.5
        }
    }
}

struct DynamicSpeedPlan: Codable, Equatable {
    let mode: DynamicSpeedMode
    let preset: DynamicSpeedPreset
    let intervalKilometers: Double
    let lowPaceSeconds: Int
    let recoverySeconds: Double

    static let standard = DynamicSpeedPlan(mode: .automatic, preset: .campus,
                                            intervalKilometers: 0.8,
                                            lowPaceSeconds: 600, recoverySeconds: 25)

    func isValid(baseSpeed: Double) -> Bool {
        guard baseSpeed.isFinite, baseSpeed > 0 else { return false }
        guard mode == .custom else { return true }
        return intervalKilometers.isFinite && (0.1...20).contains(intervalKilometers)
            && (60...3_600).contains(lowPaceSeconds)
            && Double(lowPaceSeconds) > 1_000 / baseSpeed
            && recoverySeconds.isFinite && (5...300).contains(recoverySeconds)
    }
}

/// Keeps the recovery cycle continuous across lap boundaries.
struct MotionProfile {
    let runningSpeed: Double
    let dynamicSpeed: Bool
    let plan: DynamicSpeedPlan
    private var random: MotionRandom
    private var runningMeters = 0.0
    private var nextRecoveryMeters = 0.0
    private var recoverySeconds = 0.0
    private var recoverySpeed = 0.0

    init(runningSpeed: Double, dynamicSpeed: Bool, seed: UInt64,
         plan: DynamicSpeedPlan = .standard) {
        precondition(runningSpeed.isFinite && runningSpeed > 0)
        precondition(!dynamicSpeed || plan.isValid(baseSpeed: runningSpeed))
        self.runningSpeed = runningSpeed
        self.dynamicSpeed = dynamicSpeed
        self.plan = plan
        self.random = MotionRandom(seed: seed)
        if plan.mode == .custom {
            self.nextRecoveryMeters = plan.intervalKilometers * 1_000
        } else {
            let range = plan.preset.intervalMeters
            self.nextRecoveryMeters = range.lowerBound + random.unit() * (range.upperBound - range.lowerBound)
        }
    }

    var isRecovering: Bool { dynamicSpeed && recoverySeconds > 0 }

    mutating func advance(seconds: Double, speedMultiplier: Double = 1) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let multiplier = speedMultiplier.isFinite ? max(0, speedMultiplier) : 1
        guard dynamicSpeed else { return runningSpeed * multiplier * seconds }

        var remaining = seconds
        var distance = 0.0
        while remaining > 0.000001 {
            if recoverySeconds > 0 {
                let duration = min(remaining, recoverySeconds)
                distance += recoverySpeed * duration
                remaining -= duration
                recoverySeconds -= duration
                if recoverySeconds <= 0 {
                    recoverySeconds = 0
                    runningMeters = 0
                    if plan.mode == .custom {
                        nextRecoveryMeters = plan.intervalKilometers * 1_000
                    } else {
                        let range = plan.preset.intervalMeters
                        nextRecoveryMeters = range.lowerBound
                            + random.unit() * (range.upperBound - range.lowerBound)
                    }
                }
            } else {
                let speed = runningSpeed * multiplier
                guard speed > 0 else { break }
                let duration = min(remaining, (nextRecoveryMeters - runningMeters) / speed)
                distance += speed * duration
                runningMeters += speed * duration
                remaining -= duration
                if runningMeters >= nextRecoveryMeters - 0.000001 {
                    if plan.mode == .custom {
                        recoverySeconds = plan.recoverySeconds
                        recoverySpeed = 1_000 / Double(plan.lowPaceSeconds)
                    } else {
                        let duration = plan.preset.recoverySeconds
                        let speed = plan.preset.walkingSpeed
                        recoverySeconds = duration.lowerBound
                            + random.unit() * (duration.upperBound - duration.lowerBound)
                        recoverySpeed = max(0.25, min(runningSpeed * 0.55,
                            speed.lowerBound + random.unit() * (speed.upperBound - speed.lowerBound)))
                    }
                }
            }
        }
        return distance
    }
}

private struct MotionRandom {
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
