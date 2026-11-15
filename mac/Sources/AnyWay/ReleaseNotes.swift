import Foundation

struct ReleaseNotes: Decodable {
    let version: String
    let highlights: [String]
    let fixes: [String]

    static func load(currentVersion: String) -> ReleaseNotes? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = Bundle.main.url(forResource: "RELEASE_NOTES", withExtension: "json")
            ?? root.appendingPathComponent("RELEASE_NOTES.json")
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode(ReleaseNotes.self, from: data),
              notes.version == currentVersion,
              !notes.highlights.isEmpty, !notes.fixes.isEmpty else { return nil }
        return notes
    }
}
