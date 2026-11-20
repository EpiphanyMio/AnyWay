import Foundation

struct RecentIPConnection: Identifiable, Equatable, Sendable {
    let address: String
    let udid: String
    var name: String
    var id: String { "\(udid)@\(address)" }

    static func load(from defaults: UserDefaults = .standard) -> [Self] {
        let legacy = defaults.dictionary(forKey: "directIPhone") as? [String: String]
        let rows = defaults.array(forKey: "recentIPConnections") as? [[String: String]]
            ?? legacy.map { [$0] } ?? []
        return rows.compactMap { row in
            guard let address = row["address"], !address.isEmpty,
                  let udid = row["udid"], !udid.isEmpty else { return nil }
            return Self(address: address, udid: udid, name: row["name"] ?? "")
        }
    }

    static func save(_ entries: [Self], to defaults: UserDefaults = .standard) {
        defaults.set(entries.map { ["address": $0.address, "udid": $0.udid, "name": $0.name] },
                     forKey: "recentIPConnections")
    }

    static func recording(address: String, udid: String, in entries: [Self]) -> [Self] {
        let entry = entries.first { $0.address == address && $0.udid == udid }
            ?? Self(address: address, udid: udid, name: "")
        return [entry] + entries.filter { $0.id != entry.id }
    }
}
