import XCTest
@testable import AnyWay

final class RecentIPConnectionTests: XCTestCase {
    @MainActor
    func testLegacyAddressAndNamesSurviveRelaunchAndTransportChanges() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["address": "192.0.2.1", "udid": "A"], forKey: "directIPhone")
        let controller = SimulatorController(defaults: defaults)
        let legacy = controller.recentIPs[0]
        controller.renameConnection(legacy, to: " 校园网 ")
        let usb = LocationDevice(name: "USB", udid: "A", kind: .iphone, isUSB: true)
        XCTAssertEqual(legacy.deviceID, usb.id)
        controller.renameDevice(id: legacy.deviceID, to: " 我的手机 ")
        let relaunched = SimulatorController(defaults: defaults)
        let wifi = LocationDevice(name: "Wi-Fi", udid: "A", kind: .iphone, address: legacy.address)
        XCTAssertEqual(relaunched.deviceNames[wifi.id], "我的手机")
        XCTAssertEqual(relaunched.recentIPs.first?.name, "校园网")
        var entries = RecentIPConnection.recording(address: "192.0.2.2", udid: "A", in: relaunched.recentIPs)
        entries = RecentIPConnection.recording(address: legacy.address, udid: "B", in: entries)
        entries = RecentIPConnection.recording(address: legacy.address, udid: "A", in: entries)
        XCTAssertEqual(entries.map(\.name), ["校园网", "", ""])
        XCTAssertEqual(entries.map(\.udid), ["A", "B", "A"])
        RecentIPConnection.save(entries, to: defaults)
        XCTAssertEqual(RecentIPConnection.load(from: defaults), entries)
        relaunched.renameDevice(id: wifi.id, to: " ")
        XCTAssertNil(SimulatorController(defaults: defaults).deviceNames[usb.id])
    }
}
