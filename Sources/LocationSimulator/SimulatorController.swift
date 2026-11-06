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

struct LocationDevice: Identifiable, Sendable {
    enum Kind: Sendable { case simulator, iphone, android }
    let name: String
    let udid: String
    let kind: Kind
    var id: String {
        let prefix: String
        switch kind {
        case .simulator: prefix = "sim"
        case .iphone: prefix = "iphone"
        case .android: prefix = "android"
        }
        return "\(prefix):\(udid)"
    }
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

enum DeviceBackend {
    static func availableDevices() throws -> [LocationDevice] {
        let simulators = ((try? Simctl.bootedDevices()) ?? []).map {
            LocationDevice(name: "\($0.name) · 模拟器", udid: $0.udid, kind: .simulator)
        }
        let iphones = Result { try PhoneBridge.connectedDevices() }
        let androids = Result { try AndroidBridge.connectedDevices() }
        let found = simulators + ((try? iphones.get()) ?? [])
            + ((try? androids.get()) ?? [])
        if found.isEmpty {
            if case .failure(let error) = iphones { throw error }
            if case .failure(let error) = androids { throw error }
        }
        return found
    }

    static func set(_ coordinate: Coordinate, device: LocationDevice) throws {
        switch device.kind {
        case .simulator: try Simctl.set(coordinate, device: device.udid)
        case .iphone: try PhoneBridge.shared.set(coordinate, udid: device.udid)
        case .android: try AndroidBridge.set(coordinate, serial: device.udid)
        }
    }

    static func clear(device: LocationDevice) throws {
        switch device.kind {
        case .simulator: try Simctl.clear(device: device.udid)
        case .iphone: try PhoneBridge.shared.clear(udid: device.udid)
        case .android: try AndroidBridge.clear(serial: device.udid)
        }
    }
}

@MainActor
final class SimulatorController: ObservableObject {
    @Published var devices: [LocationDevice] = []
    @Published private(set) var selectedDeviceIDs: Set<String> = []
    @Published var status = "请连接设备，然后刷新。"
    @Published private(set) var isRunning = false
    @Published private(set) var isApplying = false
    @Published private(set) var previewRoute: [Coordinate] = []
    @Published private(set) var previewSeed: UInt64 = 42

    private var runningTask: Task<Void, Never>?
    private let tickSeconds = 0.5

    var selectedDevices: [LocationDevice] {
        devices.filter { selectedDeviceIDs.contains($0.id) }
    }

    var hasSelectedDevices: Bool { !selectedDevices.isEmpty }
    var hasIPhones: Bool { devices.contains { $0.kind == .iphone } }
    var isBusy: Bool { isRunning || isApplying }

    func setSelected(_ id: String, isSelected: Bool) {
        guard !isBusy else { return }
        if isSelected { selectedDeviceIDs.insert(id) }
        else { selectedDeviceIDs.remove(id) }
    }

    func selectAllIPhones() {
        guard !isBusy else { return }
        selectedDeviceIDs.formUnion(devices.filter { $0.kind == .iphone }.map(\.id))
    }

    func refresh() {
        Task {
            do {
                let found = try await Task.detached { try DeviceBackend.availableDevices() }.value
                devices = found
                selectedDeviceIDs.formIntersection(Set(found.map(\.id)))
                if selectedDeviceIDs.isEmpty, let first = found.first {
                    selectedDeviceIDs.insert(first.id)
                }
                status = found.isEmpty ? "未找到设备。请启动 iOS 模拟器，或连接 iPhone / 已开启 USB 调试的 Android。" : "找到 \(found.count) 台可用设备。"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func setPoint(_ coordinate: Coordinate) {
        guard !isBusy, hasSelectedDevices else { return }
        let targets = selectedDevices
        isApplying = true
        status = "正在向 \(targets.count) 台设备设置定位…"
        Task {
            defer { isApplying = false }
            let failures = await apply(to: targets) { try DeviceBackend.set(coordinate, device: $0) }
            status = resultStatus(action: "设置定位", count: targets.count, failures: failures)
        }
    }

    func clear() {
        guard !isBusy, hasSelectedDevices else { return }
        let targets = selectedDevices
        isApplying = true
        status = "正在清除 \(targets.count) 台设备的模拟定位…"
        Task {
            defer { isApplying = false }
            let failures = await apply(to: targets) { try DeviceBackend.clear(device: $0) }
            status = resultStatus(action: "清除定位", count: targets.count, failures: failures)
        }
    }

    func start(points: [Coordinate], speed: Double, jitter: Double,
               loops: Int, variationMeters: Double, dynamicSpeed: Bool,
               dynamicSpeedPlan: DynamicSpeedPlan) {
        guard hasSelectedDevices, !isBusy,
              points.count >= 2, speed.isFinite, speed > 0,
              jitter.isFinite, (0...100).contains(jitter), loops >= 1,
              variationMeters.isFinite, (0...20).contains(variationMeters),
              !dynamicSpeed || dynamicSpeedPlan.isValid(baseSpeed: speed) else { return }
        let targets = selectedDevices
        isRunning = true
        status = "开始向 \(targets.count) 台设备同步路径模拟。"
        runningTask = Task {
            var speedOffset = 0.0
            let runSeed = UInt64.random(in: UInt64.min...UInt64.max)
            var motion = MotionProfile(runningSpeed: speed, dynamicSpeed: dynamicSpeed,
                                       seed: runSeed, plan: dynamicSpeedPlan)
            let loopPoints = RouteLoop.closed(points)
            do {
                try await send(loopPoints[0], to: targets)
                for pass in 0..<loops {
                    try Task.checkCancellation()
                    let seed = runSeed &+ UInt64(pass)
                    previewRoute = loopPoints
                    previewSeed = seed
                    var stepper = RouteStepper(points: loopPoints,
                                               variationMeters: variationMeters, seed: seed)
                    status = "正在运行第 \(pass + 1)/\(loops) 圈。"
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
                        let distance = motion.advance(seconds: elapsed,
                                                      speedMultiplier: 1 + speedOffset)
                        let next = stepper.advance(meters: distance)
                        try await send(next, to: targets)
                        if dynamicSpeed {
                            let segment = motion.isRecovering
                                ? (dynamicSpeedPlan.mode == .custom ? " · 低速段" : " · 慢走休息") : ""
                            status = "正在运行第 \(pass + 1)/\(loops) 圈\(segment)。"
                        }
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

    private func send(_ coordinate: Coordinate, to targets: [LocationDevice]) async throws {
        try Task.checkCancellation()
        let failures = await apply(to: targets) { try DeviceBackend.set(coordinate, device: $0) }
        try Task.checkCancellation()
        if !failures.isEmpty {
            throw SimctlError.failed(resultStatus(action: "路径模拟", count: targets.count,
                                                  failures: failures))
        }
    }

    private func apply(to targets: [LocationDevice],
                       operation: @escaping @Sendable (LocationDevice) throws -> Void) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for device in targets {
                group.addTask {
                    do {
                        try operation(device)
                        return nil
                    } catch {
                        return "\(device.name)：\(error.localizedDescription)"
                    }
                }
            }
            var failures: [String] = []
            for await failure in group {
                if let failure { failures.append(failure) }
            }
            return failures.sorted()
        }
    }

    private func resultStatus(action: String, count: Int, failures: [String]) -> String {
        let completed = count - failures.count
        if failures.isEmpty { return "已为 \(count) 台设备\(action)。" }
        return "\(action)：\(completed)/\(count) 台成功。\(failures.joined(separator: "；"))"
    }
}

