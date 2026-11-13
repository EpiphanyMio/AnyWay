import Combine
import Foundation
import MapKit

enum SchoolSearchRules {
    private static let schoolTerms = ["学校", "大学", "学院", "中学", "小学", "幼儿园", "校园",
                                      "school", "university", "college", "campus"]
    private static let groundTerms = ["运动场", "操场", "体育场", "田径场", "体育中心", "体育馆", "跑道",
                                      "篮球场", "足球场", "网球场", "羽毛球场", "排球场", "乒乓球场",
                                      "球场", "球馆", "游泳馆", "游泳池", "游泳", "健身房", "健身中心",
                                      "健身", "滑冰场", "体育公园",
                                      "stadium", "athletic", "sports field", "sports center",
                                      "sports hall", "playground", "running track",
                                      "basketball", "soccer", "football field", "tennis", "badminton",
                                      "volleyball", "swimming", "fitness", "gym"]

    static func isSportsGround(name: String, category: String? = nil) -> Bool {
        let lowercased = name.lowercased()
        return groundTerms.contains { lowercased.contains($0) }
            || category.map { value in
                let category = value.lowercased()
                return category.contains("sports") || groundTerms.contains { category.contains($0) }
            } == true
    }

    static func isSchool(name: String, category: String? = nil) -> Bool {
        if isSportsGround(name: name, category: category) { return false }
        if let category {
            let lowercasedCategory = category.lowercased()
            if lowercasedCategory.contains("school") || lowercasedCategory.contains("university") {
                return true
            }
            let unrelated = ["hospital", "restaurant", "store", "hotel", "transit",
                             "parking", "stadium", "fitness", "cafe", "bank", "museum"]
            if unrelated.contains(where: { lowercasedCategory.contains($0) }) { return false }
        }
        let lowercased = name.lowercased()
        return schoolTerms.contains { lowercased.contains($0) }
    }

    static func sportsQuery(for schoolName: String) -> String {
        "\(schoolName) 运动场"
    }

    static func expandedQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for (abbreviation, fullName) in [("浙大", "浙江大学"), ("北邮", "北京邮电大学")] {
            if trimmed.hasPrefix(abbreviation) {
                return fullName + trimmed.dropFirst(abbreviation.count)
            }
        }
        return trimmed
    }

    static func normalizedName(_ name: String) -> String {
        name.filter { !$0.isWhitespace && !"（）()·-".contains($0) }.lowercased()
    }

    static func isCampus(_ name: String, of schoolName: String) -> Bool {
        let root = normalizedName(schoolName)
        let candidate = normalizedName(name)
        guard candidate.hasPrefix(root), candidate != root else { return false }
        let suffix = candidate.dropFirst(root.count)
        return suffix.contains("校区") || suffix.contains("分校") || suffix.contains("校本部")
    }
}

struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: Coordinate
    let isSchool: Bool
    let isSportsGround: Bool

    private init(name: String, subtitle: String, coordinate: Coordinate, isSchool: Bool) {
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.isSchool = isSchool
        self.isSportsGround = false
    }

    static func knownCampus(matching query: String) -> PlaceResult? {
        let normalized = SchoolSearchRules.expandedQuery(query)
            .filter { !$0.isWhitespace && !"（）()·-".contains($0) }
        guard normalized == "北京邮电大学沙河校区" else { return nil }
        // WGS-84 campus position from OpenStreetMap way 685054417.
        // https://www.openstreetmap.org/way/685054417
        guard let coordinate = try? Coordinate(latitude: 40.15608, longitude: 116.28333) else {
            return nil
        }
        return PlaceResult(name: "北京邮电大学（沙河校区）",
                           subtitle: "北京市昌平区南丰路1号 · OpenStreetMap",
                           coordinate: coordinate, isSchool: true)
    }

    static func campuses(of school: PlaceResult, rootName: String,
                         among candidates: [PlaceResult]) -> [PlaceResult] {
        var matches = candidates.filter {
            $0.isSchool && SchoolSearchRules.isCampus($0.name, of: rootName)
                && $0.coordinate.distance(to: school.coordinate) >= 80
        }
        if SchoolSearchRules.normalizedName(rootName) == "北京邮电大学",
           let known = knownCampus(matching: "北京邮电大学沙河校区") {
            matches.append(known)
        }
        var unique: [PlaceResult] = []
        for candidate in matches {
            if candidate.coordinate.distance(to: school.coordinate) < 80
                || unique.contains(where: { $0.coordinate.distance(to: candidate.coordinate) < 80 }) {
                continue
            }
            unique.append(candidate)
        }
        return unique
    }

    init?(mapItem: MKMapItem) {
        guard let coordinate = try? Coordinate(latitude: mapItem.placemark.coordinate.latitude,
                                               longitude: mapItem.placemark.coordinate.longitude) else { return nil }
        let name = mapItem.name ?? "未命名地点"
        self.name = name
        self.subtitle = mapItem.placemark.title ?? ""
        self.coordinate = coordinate
        let category = mapItem.pointOfInterestCategory?.rawValue
        self.isSportsGround = SchoolSearchRules.isSportsGround(name: name, category: category)
        self.isSchool = SchoolSearchRules.isSchool(
            name: name,
            category: category
        )
    }
}

@MainActor
final class PlaceSearchController: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [PlaceResult] = []
    @Published private(set) var selected: PlaceResult?
    @Published private(set) var message = "可搜索地点或学校名称。"
    @Published private(set) var isSearching = false
    @Published private(set) var focusRevision = 0
    @Published private(set) var history: [String]

    private let defaults: UserDefaults
    private static let historyKey = "placeSearchHistory.v1"
    private var requestNumber = 0
    private var typingTask: Task<Void, Never>?
    private var suppressNextQueryChange = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = SearchHistory(entries: defaults.stringArray(forKey: Self.historyKey) ?? []).entries
    }

    func queryChanged() {
        if suppressNextQueryChange {
            suppressNextQueryChange = false
            return
        }
        requestNumber += 1
        typingTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            selected = nil
            isSearching = false
            message = "可搜索地点或学校名称。"
            return
        }
        typingTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            search(recordHistory: false)
        }
    }

    func search(recordHistory: Bool = true) {
        typingTask?.cancel()
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            message = "请输入地点或学校名称。"
            return
        }
        if recordHistory { remember(searchText) }
        requestNumber += 1
        let request = requestNumber
        isSearching = true
        results = []
        selected = nil
        message = "正在搜索“\(searchText)”…"
        Task {
            do {
                if let campus = PlaceResult.knownCampus(matching: searchText) {
                    results = [campus]
                    await searchGrounds(near: campus, request: request)
                    return
                }
                let expanded = SchoolSearchRules.expandedQuery(searchText)
                let items = try await searchItems(query: expanded)
                guard request == requestNumber else { return }
                let found = items.compactMap(PlaceResult.init(mapItem:))
                guard !found.isEmpty else {
                    isSearching = false
                    message = "没有找到匹配地点。"
                    return
                }
                let containsSchoolTerm = SchoolSearchRules.isSchool(name: expanded)
                let school = (containsSchoolTerm ? found.first(where: {
                    $0.isSchool && SchoolSearchRules.normalizedName($0.name)
                        == SchoolSearchRules.normalizedName(expanded)
                }) ?? found.first(where: { $0.isSchool }) : nil)
                    ?? (found.first?.isSchool == true ? found.first : nil)
                if !SchoolSearchRules.isSportsGround(name: searchText), let school {
                    await searchSchool(school, rootName: expanded,
                                       initialResults: found, request: request)
                } else {
                    results = Array(found.prefix(8))
                    selectWithoutRefinement(results[0])
                    isSearching = false
                    message = "找到 \(found.count) 个地点。"
                }
            } catch {
                guard request == requestNumber else { return }
                isSearching = false
                message = "搜索失败：\(error.localizedDescription)"
            }
        }
    }

    func select(_ result: PlaceResult) {
        remember(query)
        selectWithoutRefinement(result)
        guard result.isSchool else {
            message = "已选择“\(result.name)”。"
            return
        }
        requestNumber += 1
        let request = requestNumber
        isSearching = true
        let schoolResults = results.filter(\.isSchool)
        Task { await searchGrounds(near: result, request: request,
                                   schoolResults: schoolResults) }
    }

    func searchHistoryItem(_ item: String) {
        if query != item { suppressNextQueryChange = true }
        query = item
        search()
    }

    func rememberCurrentQuery() { remember(query) }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }

    private func remember(_ text: String) {
        var updated = SearchHistory(entries: history)
        updated.record(text)
        history = updated.entries
        defaults.set(history, forKey: Self.historyKey)
    }

    private func selectWithoutRefinement(_ result: PlaceResult) {
        selected = result
        focusRevision += 1
    }

    private func searchSchool(_ school: PlaceResult, rootName: String,
                              initialResults: [PlaceResult],
                              request: Int) async {
        let initialCampuses = PlaceResult.campuses(of: school, rootName: rootName,
                                                   among: initialResults)
        results = [school] + initialCampuses
        selectWithoutRefinement(school)
        message = "正在查找校区与附近运动场地…"
        var campuses = initialCampuses
        if !rootName.contains("校区") && !rootName.contains("分校") {
            let items = (try? await searchItems(query: "\(rootName) 校区")) ?? []
            guard request == requestNumber else { return }
            campuses = PlaceResult.campuses(of: school, rootName: rootName,
                among: initialCampuses + items.compactMap(PlaceResult.init(mapItem:)))
            results = [school] + campuses
        }
        await searchGrounds(near: school, request: request,
                            schoolResults: [school] + campuses)
    }

    private func searchGrounds(near school: PlaceResult, request: Int,
                               schoolResults: [PlaceResult]? = nil) async {
        selectWithoutRefinement(school)
        message = "已识别为学校，正在搜索附近的运动场地…"
        let latitude = school.coordinate.latitude
        let longitude = school.coordinate.longitude
        let longitudeSpan = min(1, 0.05 / max(0.2, cos(latitude * .pi / 180)))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: longitudeSpan)
        )
        async let schoolTracks = searchItems(query: SchoolSearchRules.sportsQuery(for: school.name), region: region)
        async let tracks = searchItems(query: "运动场", region: region)
        async let basketball = searchItems(query: "篮球场", region: region)
        async let playground = searchItems(query: "操场", region: region)
        async let football = searchItems(query: "足球场", region: region)
        async let tennis = searchItems(query: "网球场", region: region)
        async let indoor = searchItems(query: "体育馆", region: region)
        async let swimming = searchItems(query: "游泳馆", region: region)
        async let badminton = searchItems(query: "羽毛球场", region: region)
        async let fitness = searchItems(query: "健身中心", region: region)
        var items: [MKMapItem] = []
        items += (try? await schoolTracks) ?? []
        items += (try? await tracks) ?? []
        items += (try? await basketball) ?? []
        items += (try? await playground) ?? []
        items += (try? await football) ?? []
        items += (try? await tennis) ?? []
        items += (try? await indoor) ?? []
        items += (try? await swimming) ?? []
        items += (try? await badminton) ?? []
        items += (try? await fitness) ?? []
        guard request == requestNumber else { return }
        let grounds = nearbyGrounds(items, school: school)
        results = (schoolResults ?? [school]) + grounds
        isSearching = false
        message = grounds.isEmpty
            ? "已识别为学校，附近没有找到运动场地。"
            : "已识别为学校，附近找到 \(grounds.count) 处运动场地。"
    }

    private func nearbyGrounds(_ items: [MKMapItem], school: PlaceResult) -> [PlaceResult] {
        let nearby = items.compactMap(PlaceResult.init(mapItem:)).filter { result in
            result.isSportsGround
                && result.coordinate.distance(to: school.coordinate) <= 3_000
        }
        .sorted { $0.coordinate.distance(to: school.coordinate) < $1.coordinate.distance(to: school.coordinate) }
        var unique: [PlaceResult] = []
        for result in nearby {
            if unique.contains(where: {
                $0.name.caseInsensitiveCompare(result.name) == .orderedSame
                    && $0.coordinate.distance(to: result.coordinate) < 80
            }) { continue }
            unique.append(result)
        }
        return unique
    }

    private func searchItems(query: String, region: MKCoordinateRegion? = nil) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }
}
