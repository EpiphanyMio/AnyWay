import Combine
import Foundation
import MapKit

enum SchoolSearchRules {
    private static let schoolTerms = ["学校", "大学", "学院", "中学", "小学", "幼儿园", "校园",
                                      "school", "university", "college", "campus"]
    private static let groundTerms = ["运动场", "操场", "体育场", "田径场", "体育中心", "体育馆",
                                      "stadium", "athletic", "sports field", "playground", "running track"]

    static func isSportsGround(name: String) -> Bool {
        let lowercased = name.lowercased()
        return groundTerms.contains { lowercased.contains($0) }
    }

    static func isSchool(name: String, category: String? = nil) -> Bool {
        if isSportsGround(name: name) { return false }
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
}

struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: Coordinate
    let isSchool: Bool
    let isSportsGround: Bool

    init?(mapItem: MKMapItem) {
        guard let coordinate = try? Coordinate(latitude: mapItem.placemark.coordinate.latitude,
                                               longitude: mapItem.placemark.coordinate.longitude) else { return nil }
        let name = mapItem.name ?? "未命名地点"
        self.name = name
        self.subtitle = mapItem.placemark.title ?? ""
        self.coordinate = coordinate
        let category = mapItem.pointOfInterestCategory?.rawValue
        self.isSportsGround = SchoolSearchRules.isSportsGround(name: name)
            || category?.lowercased().contains("stadium") == true
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

    private var requestNumber = 0

    func search() {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            message = "请输入地点或学校名称。"
            return
        }
        requestNumber += 1
        let request = requestNumber
        isSearching = true
        results = []
        selected = nil
        message = "正在搜索“\(searchText)”…"
        Task {
            do {
                let items = try await searchItems(query: searchText)
                guard request == requestNumber else { return }
                let found = items.compactMap(PlaceResult.init(mapItem:))
                guard !found.isEmpty else {
                    isSearching = false
                    message = "没有找到匹配地点。"
                    return
                }
                let containsSchoolTerm = SchoolSearchRules.isSchool(name: searchText)
                let school = (containsSchoolTerm ? found.first(where: { $0.isSchool }) : nil)
                    ?? (found.first?.isSchool == true ? found.first : nil)
                if !SchoolSearchRules.isSportsGround(name: searchText), let school {
                    await searchGrounds(near: school, request: request)
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
        selectWithoutRefinement(result)
        guard result.isSchool else {
            message = "已选择“\(result.name)”。"
            return
        }
        requestNumber += 1
        let request = requestNumber
        isSearching = true
        Task { await searchGrounds(near: result, request: request) }
    }

    private func selectWithoutRefinement(_ result: PlaceResult) {
        selected = result
        focusRevision += 1
    }

    private func searchGrounds(near school: PlaceResult, request: Int) async {
        selectWithoutRefinement(school)
        message = "已识别为学校，正在搜索附近的“运动场”…"
        let latitude = school.coordinate.latitude
        let longitude = school.coordinate.longitude
        let longitudeSpan = min(1, 0.05 / max(0.2, cos(latitude * .pi / 180)))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: longitudeSpan)
        )
        do {
            var items = try await searchItems(query: SchoolSearchRules.sportsQuery(for: school.name),
                                              region: region)
            guard request == requestNumber else { return }
            var grounds = nearbyGrounds(items, school: school)
            if grounds.isEmpty {
                items = try await searchItems(query: "运动场", region: region)
                grounds = nearbyGrounds(items, school: school)
            }
            guard request == requestNumber else { return }
            results = [school] + Array(grounds.prefix(7))
            isSearching = false
            message = grounds.isEmpty
                ? "已识别为学校，附近没有找到标记为“运动场”的地点。"
                : "已识别为学校，附近找到 \(grounds.count) 处运动场。"
        } catch {
            guard request == requestNumber else { return }
            results = [school]
            isSearching = false
            message = "已识别为学校，但运动场搜索失败：\(error.localizedDescription)"
        }
    }

    private func nearbyGrounds(_ items: [MKMapItem], school: PlaceResult) -> [PlaceResult] {
        items.compactMap(PlaceResult.init(mapItem:)).filter { result in
            result.isSportsGround
                && result.coordinate.distance(to: school.coordinate) <= 3_000
        }
    }

    private func searchItems(query: String, region: MKCoordinateRegion? = nil) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }
}
