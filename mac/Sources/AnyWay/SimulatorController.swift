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
    let isUSB: Bool
    let address: String?
    let needsDeveloperMode: Bool

    init(name: String, udid: String, kind: Kind, needsDeveloperMode: Bool = false, address: String? = nil, isUSB: Bool = false) {
        self.isUSB = isUSB
        self.address = address
        self.name = name
        self.udid = udid
        self.kind = kind
        self.needsDeveloperMode = needsDeveloperMode
    }
    var id: String { Self.identifier(kind: kind, udid: udid) }

    static func identifier(kind: Kind, udid: String) -> String {
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
        case .iphone: try PhoneBridge.shared.set(coordinate, udid: device.udid, address: device.address)
        case .android: try AndroidBridge.set(coordinate, serial: device.udid)
        }
    }

    static func setKeepAwake(_ enabled: Bool, device: LocationDevice) throws {
        switch device.kind {
        case .simulator: break
        case .iphone: try PhoneBridge.shared.setKeepAwake(enabled, udid: device.udid)
        case .android: try AndroidBridge.setKeepAwake(enabled, serial: device.udid)
        }
    }

    static func clear(device: LocationDevice) throws {
        switch device.kind {
        case .simulator: try Simctl.clear(device: device.udid)
        case .iphone: try PhoneBridge.shared.clear(udid: device.udid, address: device.address)
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
    @Published private(set) var previews: [String: [Coordinate]] = [:]
    @Published private(set) var isRefreshing = false
    @Published var ipConnectionError: String?
    @Published var developerModeGuideDevice: LocationDevice?
    @Published private(set) var wirelessPreparationCount = 0

    @Published private(set) var recentIPs: [RecentIPConnection]
    @Published private(set) var deviceNames: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentIPs = RecentIPConnection.load(from: defaults)
        deviceNames = defaults.dictionary(forKey: "deviceAliases") as? [String: String] ?? [:]
    }

    private var runningTask: Task<Void, Never>?
    private var liveConfigurations: [String: RouteConfiguration] = [:]
    private let tickSeconds = 0.5

    var selectedDevices: [LocationDevice] {
        devices.filter { selectedDeviceIDs.contains($0.id) }
    }

    var hasSelectedDevices: Bool { !selectedDevices.isEmpty }
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

    func prepareWirelessIPhones() {
        let targets = selectedDevices.filter { $0.kind == .iphone && $0.isUSB }
        guard !isBusy, !targets.isEmpty else { return }
        isApplying = true
        status = "正在为 iPhone 开启无线连接…"
        Task {
            defer { isApplying = false }
            let failures = await Task.detached {
                targets.compactMap { device -> String? in
                    do {
                        try PhoneBridge.prepareWireless(udid: device.udid)
                        return nil
                    } catch {
                        return "\(device.name)：\(error.localizedDescription)"
                    }
                }
            }.value
            status = failures.isEmpty
                ? "无线连接已准备好。拔掉数据线后，保持同一网络并点击刷新。"
                : failures.joined(separator: "；")
            if failures.isEmpty { wirelessPreparationCount += 1 }
        }
    }

    func renameConnection(_ entry: RecentIPConnection, to name: String) {
        guard let index = recentIPs.firstIndex(where: { $0.id == entry.id }) else { return }
        recentIPs[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        RecentIPConnection.save(recentIPs, to: defaults)
    }

    func renameDevice(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceNames[id] = trimmed.isEmpty ? nil : trimmed
        defaults.set(deviceNames, forKey: "deviceAliases")
    }

    func connectIP(_ input: String, expectedUDID: String? = nil) {
        guard !isBusy else { return }
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplying = true
        status = "正在验证 iPhone 配对和定位服务…"
        Task {
            defer { isApplying = false }
            do {
                let device = try await Task.detached { try PhoneBridge.checkIP(address, expectedUDID: expectedUDID) }.value
                recentIPs = RecentIPConnection.recording(address: address, udid: device.udid, in: recentIPs)
                RecentIPConnection.save(recentIPs, to: defaults)
                devices.removeAll { $0.id == device.id }
                devices.append(device)
                selectedDeviceIDs.insert(device.id)
                status = "已连接 \(address)，定位服务可用。"
            } catch {
                status = error.localizedDescription
                ipConnectionError = status
            }
        }
    }

    func refresh() {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                var found = try await Task.detached { try DeviceBackend.availableDevices() }.value
                guard !isBusy else { return }
                // Keep IP devices selected by the user unless they are now connected by USB.
                let direct = devices.filter { device in
                    device.address != nil && !found.contains { $0.id == device.id && $0.isUSB }
                }
                found.removeAll { item in direct.contains { $0.id == item.id } }
                found += direct
                devices = found
                selectedDeviceIDs.formIntersection(Set(found.map(\.id)))
                if selectedDeviceIDs.isEmpty, let first = found.first {
                    selectedDeviceIDs.insert(first.id)
                }
                var guided = Set(defaults.stringArray(forKey: "developerModeGuideShownUDIDs") ?? [])
                if let device = found.first(where: { $0.needsDeveloperMode && !guided.contains($0.udid) }) {
                    guided.insert(device.udid)
                    defaults.set(Array(guided).sorted(), forKey: "developerModeGuideShownUDIDs")
                    developerModeGuideDevice = device
                }
                if found.contains(where: { $0.needsDeveloperMode }) {
                    status = "已尝试显示 iPhone 开发者模式开关。请在手机的设置 → 隐私与安全性 → 开发者模式中开启，并按提示重启确认。"
                } else {
                    status = found.isEmpty ? "未找到设备。请启动 iOS 模拟器，或连接 iPhone / 已开启 USB 调试的 Android。" : "找到 \(found.count) 台可用设备。"
                }
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

    func updateRun(deviceID: String, configuration: RouteConfiguration) {
        guard liveConfigurations[deviceID] != nil,
              RouteLoop.closed(configuration.route).hasLength else { return }
        liveConfigurations[deviceID] = configuration
    }

    func start(configurations: [String: RouteConfiguration]) {
        let targets = selectedDevices
        guard !isBusy, !targets.isEmpty, targets.allSatisfy({
            configurations[$0.id].map { RouteLoop.closed($0.route).hasLength } ?? false
        }) else {
            status = "每台设备的路线至少需要两个不同的路径点。"
            return
        }
        liveConfigurations = configurations
        isRunning = true
        status = "正在为 \(targets.count) 台设备启动路径模拟…"
        let seed = UInt64.random(in: 0...UInt64.max)
        runningTask = Task {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "AnyWay route simulation")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let failures = await withTaskGroup(of: String?.self) { group in
                for (index, device) in targets.enumerated() {
                    group.addTask {
                        let failure: String?
                        do {
                            try await self.run(device, seed: seed &+ UInt64(index) &* 0x9E3779B97F4A7C15,
                                               index: index, count: targets.count)
                            failure = nil
                        } catch is CancellationError {
                            failure = nil
                        } catch {
                            failure = "\(device.name)：\(error.localizedDescription)"
                        }
                        _ = await Self.setKeepAwake(false, device: device)
                        return failure
                    }
                }
                var failures: [String] = []
                for await error in group {
                    if let error { failures.append(error) }
                }
                return failures
            }
            if Task.isCancelled {
                status = "路径模拟已停止。定位停留在当前点。"
            } else if failures.isEmpty {
                status = "路径模拟完成。定位停留在最后一个点。"
            } else {
                status = resultStatus(action: "路径模拟", count: targets.count, failures: failures)
            }
            previews.removeAll()
            liveConfigurations.removeAll()
            isRunning = false
            runningTask = nil
        }
    }

    private func run(_ device: LocationDevice, seed: UInt64, index: Int, count: Int) async throws {
        guard let initial = liveConfigurations[device.id] else { return }
        var route = LiveRoute(configuration: initial, seed: seed, index: index, count: count)
        try await setRoutePoint(route.point, on: device)
        try Task.checkCancellation()
        let supportsWake = await Self.setKeepAwake(true, device: device)
        var wakeAvailable = supportsWake
        var nextWakeRenewal = ProcessInfo.processInfo.systemUptime + 15
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        var previousStatus = ""
        defer { previews.removeValue(forKey: device.id) }
        while !route.finished {
            try Task.checkCancellation()
            if let latest = liveConfigurations[device.id] { route.update(latest) }
            if route.finished { break }
            if route.previewChanged {
                previews[device.id] = route.preview()
            }
            let name = deviceNames[device.id] ?? device.name
            let recovery = route.isRecovering ? " · 低速段" : ""
            let wakeStatus = wakeAvailable ? "" : " · 设备端防休眠不可用"
            let progress = "\(name) · 第 \(route.lap + 1)/\(route.configuration.passes) 圈\(recovery)\(wakeStatus)"
            if progress != previousStatus {
                status = progress
                previousStatus = progress
            }
            let wait = max(0, tickSeconds - (ProcessInfo.processInfo.systemUptime - lastUpdate))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            try Task.checkCancellation()
            if supportsWake && device.kind != .simulator && ProcessInfo.processInfo.systemUptime >= nextWakeRenewal {
                wakeAvailable = await Self.setKeepAwake(true, device: device)
                nextWakeRenewal = ProcessInfo.processInfo.systemUptime + (wakeAvailable ? 15 : 4)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let latest = liveConfigurations[device.id] { route.update(latest) }
            if route.finished { break }
            try await setRoutePoint(route.advance(seconds: now - lastUpdate), on: device)
            lastUpdate = now
        }
    }

    private static func setKeepAwake(_ enabled: Bool, device: LocationDevice) async -> Bool {
        if device.kind == .simulator { return true }
        return await Task.detached {
            do {
                try DeviceBackend.setKeepAwake(enabled, device: device)
                return true
            } catch {
                return false
            }
        }.value
    }

    private func setRoutePoint(_ point: Coordinate, on device: LocationDevice) async throws {
        try Task.checkCancellation()
        try await Task.detached { try DeviceBackend.set(point, device: device) }.value
    }

    func stop() {
        guard isRunning else { return }
        status = "正在停止…"
        runningTask?.cancel()
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

