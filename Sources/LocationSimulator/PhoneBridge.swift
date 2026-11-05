import Foundation

final class PhoneBridge: @unchecked Sendable {
    static let shared = PhoneBridge()

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var activeUDID: String?

    private static var projectDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var supportDirectory: URL {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            projectDirectory.appendingPathComponent(".build"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build")
        ].compactMap { $0 }
        if let installed = candidates.first(where: {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("iphone-venv/bin/python").path
            )
        }) {
            return installed
        }
        return projectDirectory.appendingPathComponent(".build")
    }

    private static var pythonURL: URL {
        supportDirectory.appendingPathComponent("iphone-venv/bin/python")
    }

    private static var bridgeURL: URL {
        let candidates = [
            Bundle.main.url(forResource: "iphone_location_bridge", withExtension: "py"),
            projectDirectory.appendingPathComponent("scripts/iphone_location_bridge.py"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/iphone_location_bridge.py")
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? projectDirectory.appendingPathComponent("scripts/iphone_location_bridge.py")
    }

    static func connectedDevices() throws -> [LocationDevice] {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { return [] }
        let task = Process()
        task.executableURL = pythonURL
        task.arguments = ["-m", "pymobiledevice3", "usbmux", "list", "--simple"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw SimctlError.failed("无法读取 iPhone。请检查连接和信任状态。")
        }
        let udids = try JSONDecoder().decode([String].self, from: data)
        return udids.map {
            LocationDevice(name: "iOS 设备 · \(String($0.suffix(8)))", udid: $0, kind: .iphone)
        }
    }

    func set(_ coordinate: Coordinate, udid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try connect(udid: udid)
            try send(["action": "set", "latitude": coordinate.latitude,
                      "longitude": coordinate.longitude])
        } catch {
            disconnect()
            throw error
        }
    }

    func clear(udid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        defer { disconnect() }
        try connect(udid: udid)
        try send(["action": "clear"])
    }

    private func connect(udid: String) throws {
        if process?.isRunning == true, activeUDID == udid { return }
        if process?.isRunning == true {
            try? send(["action": "clear"])
        }
        disconnect()
        guard FileManager.default.isExecutableFile(atPath: Self.pythonURL.path) else {
            throw SimctlError.failed("缺少 iPhone Python 支持组件。请运行 scripts/install-iphone-support.sh 后重新打开应用。")
        }
        guard FileManager.default.fileExists(atPath: Self.bridgeURL.path) else {
            throw SimctlError.failed("缺少 iPhone 桥接脚本。请重新构建应用。")
        }
        let task = Process()
        task.executableURL = Self.pythonURL
        task.arguments = [Self.bridgeURL.path, udid]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        activeUDID = udid
        let response: [String: Any]
        do {
            response = try readResponse()
        } catch {
            disconnect()
            throw error
        }
        guard response["ready"] as? Bool == true else {
            let detail = response["error"] as? String ?? "连接失败"
            disconnect()
            throw SimctlError.failed("无法连接 iPhone 开发者定位服务：\(detail)。请确认已信任 Mac、开启开发者模式并在 Xcode 中完成设备准备。")
        }
    }

    private func send(_ request: [String: Any]) throws {
        guard process?.isRunning == true, let input else {
            throw SimctlError.failed("iPhone 定位会话已断开。")
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        try input.write(contentsOf: data + Data([0x0A]))
        let response = try readResponse()
        guard response["ok"] as? Bool == true else {
            throw SimctlError.failed(response["error"] as? String ?? "iPhone 定位操作失败。")
        }
    }

    private func readResponse() throws -> [String: Any] {
        guard let output else { throw SimctlError.failed("iPhone 定位会话已断开。") }
        var data = Data()
        while true {
            let byte = output.readData(ofLength: 1)
            guard !byte.isEmpty else { throw SimctlError.failed("iPhone 定位服务意外退出。") }
            if byte[0] == 0x0A { break }
            data.append(byte)
        }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimctlError.failed("iPhone 定位服务返回无效数据。")
        }
        return response
    }

    private func disconnect() {
        input?.closeFile()
        output?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        activeUDID = nil
    }
}
