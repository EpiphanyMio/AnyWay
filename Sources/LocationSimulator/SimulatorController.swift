import Combine
import Foundation

struct SimulatorDevice: Decodable, Identifiable, Sendable {
    let name: String
    let udid: String
    let state: String

    var id: String { udid }
}

private struct DeviceList: Decodable {
    let devices: [String: [SimulatorDevice]]
}

enum SimctlError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

enum Simctl {
    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw SimctlError.failed("无法启动 xcrun。请先安装 Xcode 并打开一次 Xcode。\n\(error.localizedDescription)")
        }
        process.waitUntilExit()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimctlError.failed(message.flatMap { $0.isEmpty ? nil : $0 }
                                    ?? "simctl 执行失败（退出码 \(process.terminationStatus)）。")
        }
        return outputData
    }

    static func bootedDevices() throws -> [SimulatorDevice] {
        let data = try run(["list", "devices", "booted", "-j"])
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        return list.devices.values.flatMap { $0 }.filter { $0.state == "Booted" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func set(_ coordinate: Coordinate, device: String) throws {
        _ = try run(["location", device, "set", coordinate.simctlArgument])
    }

    static func clear(device: String) throws {
        _ = try run(["location", device, "clear"])
    }
}

@MainActor
final class SimulatorController: ObservableObject {
    @Published var devices: [SimulatorDevice] = []
    @Published var selectedDevice = ""
    @Published var status = "请先启动 iOS 模拟器，然后刷新设备。"
    @Published private(set) var isRunning = false
    @Published private(set) var previewRoute: [Coordinate] = []
    @Published private(set) var previewSeed: UInt64 = 42

    private var runningTask: Task<Void, Never>?
    private let tickSeconds = 0.5

    func refresh() {
        Task {
            do {
                let found = try await Task.detached { try Simctl.bootedDevices() }.value
                devices = found
                if !found.contains(where: { $0.udid == selectedDevice }) {
                    selectedDevice = found.first?.udid ?? ""
                }
                status = found.isEmpty ? "没有已启动的模拟器。请在 Xcode 中启动一个 iOS 模拟器。" : "找到 \(found.count) 台已启动的模拟器。"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func setPoint(_ coordinate: Coordinate) {
        guard !selectedDevice.isEmpty, !isRunning else { return }
        let device = selectedDevice
        Task {
            do {
                try await Task.detached { try Simctl.set(coordinate, device: device) }.value
                status = "已设置定位：\(coordinate.simctlArgument)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func clear() {
        guard !selectedDevice.isEmpty, !isRunning else { return }
        let device = selectedDevice
        Task {
            do {
                try await Task.detached { try Simctl.clear(device: device) }.value
                status = "已清除模拟定位。"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func start(points: [Coordinate], speed: Double, jitter: Double,
               loops: Int, variationMeters: Double) {
        guard !selectedDevice.isEmpty, !isRunning,
              points.count >= 2, speed.isFinite, speed > 0,
              jitter.isFinite, (0...100).contains(jitter), loops >= 1,
              variationMeters.isFinite, (0...20).contains(variationMeters) else { return }
        let device = selectedDevice
        isRunning = true
        status = "开始路径模拟。"
        runningTask = Task {
            var speedOffset = 0.0
            let runSeed = UInt64.random(in: UInt64.min...UInt64.max)
            do {
                for pass in 0..<loops {
                    try Task.checkCancellation()
                    let passPoints = pass.isMultiple(of: 2) ? points : Array(points.reversed())
                    let seed = runSeed &+ UInt64(pass)
                    previewRoute = passPoints
                    previewSeed = seed
                    var stepper = RouteStepper(points: passPoints,
                                               variationMeters: variationMeters, seed: seed)
                    try await send(passPoints[0], to: device)
                    status = "正在运行第 \(pass + 1)/\(loops) 趟。"
                    var lastUpdate = ProcessInfo.processInfo.systemUptime
                    while !stepper.isFinished {
                        let wait = max(0, tickSeconds - (ProcessInfo.processInfo.systemUptime - lastUpdate))
                        if wait > 0 {
                            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        let elapsed = max(0.001, now - lastUpdate)
                        lastUpdate = now
                        let target = Double.random(in: -jitter / 100...jitter / 100)
                        speedOffset = 0.8 * speedOffset + 0.2 * target
                        let next = stepper.advance(meters: speed * (1 + speedOffset) * elapsed)
                        try await send(next, to: device)
                    }
                }
                status = "路径模拟完成。定位停留在最后一个点；可点击“清除定位”。"
            } catch is CancellationError {
                status = "路径模拟已停止。定位停留在当前点。"
            } catch {
                status = error.localizedDescription
            }
            previewRoute = []
            isRunning = false
            runningTask = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        status = "正在停止…"
        runningTask?.cancel()
    }

    private func send(_ coordinate: Coordinate, to device: String) async throws {
        try Task.checkCancellation()
        try await Task.detached { try Simctl.set(coordinate, device: device) }.value
        try Task.checkCancellation()
    }
}
