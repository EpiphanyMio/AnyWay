import Foundation

enum AndroidBridge {
    private static let component = "com.anyway.mac.mock/.LocationReceiver"

    private static var adbURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sdk = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                   home + "/Library/Android/sdk"].compactMap { $0 }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
            + sdk.map { $0 + "/platform-tools" }
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("adb") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ arguments: [String]) throws -> String {
        guard let adbURL else {
            throw SimctlError.failed("未找到 adb。请安装 Android SDK Platform-Tools。")
        }
        let task = Process()
        task.executableURL = adbURL
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.terminationStatus == 0 else {
            throw SimctlError.failed(output.isEmpty ? "adb 执行失败。" : output)
        }
        return output
    }

    static func connectedDevices() throws -> [LocationDevice] {
        guard adbURL != nil else { return [] }
        let output = try run(["devices", "-l"])
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            let serial = String(fields[0])
            let model = fields.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
                ?? serial
            return LocationDevice(name: "\(model) · Android", udid: serial, kind: .android)
        }
    }

    static func set(_ coordinate: Coordinate, serial: String) throws {
        try broadcast(["--es", "action", "set", "--es", "latitude",
                       String(coordinate.latitude), "--es", "longitude",
                       String(coordinate.longitude)], serial: serial)
    }

    static func clear(serial: String) throws {
        try broadcast(["--es", "action", "clear"], serial: serial)
    }

    private static func broadcast(_ extras: [String], serial: String) throws {
        let output = try run(["-s", serial, "shell", "am", "broadcast",
                              "--receiver-foreground", "-n", component] + extras)
        guard output.range(of: #"result=1(?:,|$)"#, options: .regularExpression) != nil else {
            let detail = output.components(separatedBy: "data=\"").dropFirst().first?
                .components(separatedBy: "\"").first
            throw SimctlError.failed(detail ??
                "Android 定位失败。请安装配套 App，并在开发者选项中将它设为模拟位置信息应用。\n\(output)")
        }
    }
}
