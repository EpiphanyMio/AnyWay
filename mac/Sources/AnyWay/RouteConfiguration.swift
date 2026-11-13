import Foundation

struct RouteConfiguration: Codable, Equatable {
    let schemaVersion: Int
    let name: String
    let point: Coordinate
    let route: [Coordinate]
    let speedMetersPerSecond: Double
    let jitterPercent: Double
    let passes: Int
    let pathVariationMeters: Double
    let dynamicSpeed: Bool
    let dynamicSpeedPlan: DynamicSpeedPlan

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, point, route, speedMetersPerSecond
        case jitterPercent, passes, pathVariationMeters, dynamicSpeed, dynamicSpeedPlan
    }

    init(name: String, point: Coordinate, route: [Coordinate],
         speedMetersPerSecond: Double, jitterPercent: Double, passes: Int,
         pathVariationMeters: Double = 2, dynamicSpeed: Bool = false,
         dynamicSpeedPlan: DynamicSpeedPlan = .standard) throws {
        self.schemaVersion = 1
        self.name = name
        self.point = point
        self.route = route
        self.speedMetersPerSecond = speedMetersPerSecond
        self.jitterPercent = jitterPercent
        self.passes = passes
        self.pathVariationMeters = pathVariationMeters
        self.dynamicSpeed = dynamicSpeed
        self.dynamicSpeedPlan = dynamicSpeedPlan
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        name = try container.decode(String.self, forKey: .name)
        point = try container.decode(Coordinate.self, forKey: .point)
        route = try container.decode([Coordinate].self, forKey: .route)
        speedMetersPerSecond = try container.decode(Double.self, forKey: .speedMetersPerSecond)
        jitterPercent = try container.decode(Double.self, forKey: .jitterPercent)
        passes = try container.decode(Int.self, forKey: .passes)
        // Configurations created before path variation existed use a subtle 2 m drift.
        pathVariationMeters = try container.decodeIfPresent(Double.self, forKey: .pathVariationMeters) ?? 2
        dynamicSpeed = try container.decodeIfPresent(Bool.self, forKey: .dynamicSpeed) ?? false
        dynamicSpeedPlan = try container.decodeIfPresent(DynamicSpeedPlan.self,
                                                         forKey: .dynamicSpeedPlan) ?? .standard
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ConfigurationError.unsupportedVersion }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidName
        }
        guard point.isValid, route.count <= 10_000, route.allSatisfy(\.isValid) else {
            throw ConfigurationError.invalidRoute
        }
        guard speedMetersPerSecond.isFinite, speedMetersPerSecond > 0,
              jitterPercent.isFinite, (0...100).contains(jitterPercent),
              (1...1000).contains(passes),
              pathVariationMeters.isFinite, (0...20).contains(pathVariationMeters) else {
            throw ConfigurationError.invalidSettings
        }
        guard !dynamicSpeed || dynamicSpeedPlan.isValid(baseSpeed: speedMetersPerSecond) else {
            throw ConfigurationError.invalidDynamicSpeed
        }
    }
}

enum ConfigurationError: LocalizedError {
    case unsupportedVersion
    case invalidName
    case invalidRoute
    case invalidSettings
    case invalidDynamicSpeed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "不支持此配置文件版本。"
        case .invalidName: "请填写配置名称。"
        case .invalidRoute: "配置路径最多支持 10000 个有效坐标点。"
        case .invalidSettings: "速度须大于 0，配速秒数须为 0～59，抖动须为 0～100%，圈数须为 1～1000，路线偏移须为 0～20 米。"
        case .invalidDynamicSpeed: "自定义动态速度需每隔 0.1～20 公里切换；低速配速须慢于跑步配速，持续时间须为 5～300 秒。"
        }
    }
}

enum ConfigurationCodec {
    static func encode(_ configuration: RouteConfiguration) throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    static func decode(_ data: Data) throws -> RouteConfiguration {
        let configuration = try JSONDecoder().decode(RouteConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }
}
