import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let old = UserDefaults(suiteName: "local.LocationSimulator") else { return }
        let current = UserDefaults.standard
        for key in ["restoreLastRoute", "autoRefreshDevices", "appearanceMode",
                    "hasAcknowledgedResearchNotice", "lastRouteDraft.v1", "placeSearchHistory.v1"] {
            if current.object(forKey: key) == nil, let value = old.object(forKey: key) {
                current.set(value, forKey: key)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables need a regular application policy to receive keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AnyWayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some Scene {
        WindowGroup("AnyWay") {
            ContentView()
                .frame(minWidth: 980, minHeight: 690)
                .preferredColorScheme(appearanceMode == "dark" ? .dark : appearanceMode == "light" ? .light : nil)
        }
    }
}

