import Foundation

struct ReleaseVersion: Comparable {
    let parts: [Int]

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, text.split(separator: ".").count == 3,
              parts.allSatisfy({ $0 >= 0 }) else { return nil }
        self.parts = parts
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    var currentVersion: String {
        if let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           ReleaseVersion(bundled) != nil { return bundled }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"
    }

    var requiresUpdate: Bool {
        guard let latestVersion, let latest = ReleaseVersion(latestVersion),
              let current = ReleaseVersion(currentVersion) else { return false }
        return latest > current
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let url = URL(string: "https://api.github.com/repos/EpiphanyMio/AnyWay/releases/latest")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("AnyWay-update-checker/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard ReleaseVersion(release.tag_name) != nil else {
                throw URLError(.cannotParseResponse)
            }
            latestVersion = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst()) : release.tag_name
            releaseURL = URL(string: "https://github.com/EpiphanyMio/AnyWay/releases/tag/\(release.tag_name)")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct Release: Decodable { let tag_name: String }
}
