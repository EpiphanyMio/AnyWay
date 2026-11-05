import Foundation

struct SearchHistory: Equatable {
    private(set) var entries: [String]
    static let limit = 12

    init(entries: [String] = []) {
        self.entries = []
        for entry in entries.reversed() { record(entry) }
    }

    mutating func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
}

struct RouteDraft: Codable, Equatable {
    let name: String
    let latitude: String
    let longitude: String
    let points: [Coordinate]
    let routeText: String
    let textPending: Bool
    let speed: String
    let jitter: String
    let passes: String
    let pathVariation: String
    let dynamicSpeed: Bool
    let dynamicSpeedDraft: DynamicSpeedDraft?
    let editorMode: Int

    var isValid: Bool {
        points.count <= 10_000 && points.allSatisfy(\.isValid)
            && routeText.utf8.count <= 1_000_000 && (0...1).contains(editorMode)
    }
}

struct DynamicSpeedDraft: Codable, Equatable {
    let mode: DynamicSpeedMode
    let preset: DynamicSpeedPreset
    let intervalKilometers: String
    let lowPaceMinutes: String
    let lowPaceSeconds: String
    let recoverySeconds: String
}

struct RouteDraftStore {
    private static let key = "lastRouteDraft.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func save(_ draft: RouteDraft) -> Bool {
        guard draft.isValid, let data = try? JSONEncoder().encode(draft) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    func load() -> RouteDraft? {
        guard let data = defaults.data(forKey: Self.key),
              let draft = try? JSONDecoder().decode(RouteDraft.self, from: data),
              draft.isValid else { return nil }
        return draft
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    var hasSavedDraft: Bool { load() != nil }
}
