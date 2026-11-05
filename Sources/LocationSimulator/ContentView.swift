import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = SimulatorController()
    @StateObject private var placeSearch = PlaceSearchController()
    @State private var name = "我的路线"
    @State private var latitude = "39.9042"
    @State private var longitude = "116.4074"
    @State private var points: [Coordinate] = []
    @State private var routeText = ""
    @State private var textPending = false
    @State private var fitRevision = 0
    @State private var speed = "5"
    @State private var jitter = "15"
    @State private var passes = "2"
    @State private var pathVariation = "2"
    @State private var editorMode = 0

    private let accent = Color.teal

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 18) {
                mapPanel
                sidebar.frame(width: 310)
            }
            .padding(20)
            Divider()
            HStack(spacing: 9) {
                Image(systemName: controller.isRunning ? "location.fill" : "info.circle.fill")
                    .foregroundStyle(accent)
                Text(controller.status)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { controller.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "location.north.line.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 43, height: 43)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("定位模拟器").font(.title2.bold())
                Text("绘制路径 · 模拟移动 · 保存方案")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                importConfiguration()
            } label: {
                Label("导入配置", systemImage: "square.and.arrow.down")
            }
            .disabled(controller.isRunning)
            Button {
                saveConfiguration()
            } label: {
                Label("保存配置", systemImage: "square.and.arrow.up")
            }
            .disabled(controller.isRunning)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("路线画布").font(.headline)
                    Text("单击添加路径点；曲线显示当前模拟轨迹")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(points.count) 个点")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.1), in: Capsule())
            }
            searchPanel
            RouteMapView(points: points,
                         previewRoute: controller.previewRoute,
                         variationMeters: min(20, max(0, Double(pathVariation) ?? 2)),
                         previewSeed: controller.previewSeed,
                         fitRevision: fitRevision,
                         searchCoordinate: placeSearch.selected?.coordinate,
                         searchTitle: placeSearch.selected?.name ?? "",
                         focusRevision: placeSearch.focusRevision) { point in
                guard !controller.isRunning else { return }
                guard !textPending else {
                    controller.status = "请先点击“应用到地图”，再继续在地图上添加点。"
                    return
                }
                guard points.count < 10_000 else {
                    controller.status = "路径最多支持 10000 个点。"
                    return
                }
                points.append(point)
                syncRouteText()
                controller.status = "已添加第 \(points.count) 个路径点。"
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    guard !points.isEmpty else { return }
                    points.removeLast()
                    syncRouteText()
                } label: {
                    Label("撤销上一点", systemImage: "arrow.uturn.backward")
                }
                .disabled(points.isEmpty || controller.isRunning)
                Button("清空路线") {
                    points.removeAll()
                    syncRouteText()
                }
                .disabled(points.isEmpty || controller.isRunning)
                Spacer()
                Button {
                    fitRevision += 1
                } label: {
                    Label("适合窗口", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(points.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索地点或学校，例如：北京大学", text: $placeSearch.query)
                    .textFieldStyle(.plain)
                    .onSubmit { placeSearch.search() }
                if placeSearch.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("搜索") { placeSearch.search() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))

            if !placeSearch.results.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(placeSearch.results) { result in
                            Button {
                                placeSearch.select(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.name)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text(result.isSchool ? "学校" : result.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 165, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(placeSearch.selected?.id == result.id
                                            ? accent.opacity(0.12)
                                            : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack(spacing: 10) {
                Text(placeSearch.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if placeSearch.selected != nil {
                    Button("设为单点") { useSelectedAsPoint() }
                        .disabled(controller.isRunning)
                    Button("加入路线") { addSelectedToRoute() }
                        .disabled(controller.isRunning || points.count >= 10_000)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card("模拟设备", icon: "iphone.gen3") {
                    HStack(spacing: 8) {
                        Picker("", selection: $controller.selectedDevice) {
                            if controller.devices.isEmpty { Text("没有已启动的模拟器").tag("") }
                            ForEach(controller.devices) { device in
                                Text(device.name).tag(device.udid)
                            }
                        }
                        .labelsHidden()
                        Button { controller.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新已启动的模拟器")
                    }
                }

                card("单点定位", icon: "mappin.circle") {
                    HStack(spacing: 8) {
                        field("纬度", text: $latitude)
                        field("经度", text: $longitude)
                    }
                    HStack {
                        Button("设置定位") { setPoint() }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                        Button("清除定位") { controller.clear() }
                    }
                    .disabled(controller.selectedDevice.isEmpty || controller.isRunning)
                }

                card("路径编辑", icon: "point.topleft.down.curvedto.point.bottomright.up") {
                    field("方案名称", text: $name)
                    Picker("", selection: $editorMode) {
                        Text("地图绘制").tag(0)
                        Text("坐标文本").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if editorMode == 0 {
                        Text("在左侧地图单击添加路径点。重复运行时会沿原路折返。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextEditor(text: Binding(
                            get: { routeText },
                            set: { routeText = $0; textPending = true }
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 118)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                        .disabled(controller.isRunning)
                        Button("应用到地图") { applyRouteText() }
                            .disabled(!textPending || controller.isRunning)
                        Text("每行：纬度,经度")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                card("移动参数", icon: "speedometer") {
                    HStack(spacing: 8) {
                        field("速度 m/s", text: $speed)
                        field("抖动 ±%", text: $jitter)
                        field("趟数", text: $passes)
                    }
                    field("路线偏移上限 m", text: $pathVariation)
                    Text("每趟生成不同的平滑轨迹；中途路径点带小幅偏差，起终点保持准确。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Button {
                        startRoute()
                    } label: {
                        Label("开始模拟", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(controller.selectedDevice.isEmpty || controller.isRunning)

                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(!controller.isRunning)
                    .help("停止路径模拟")
                }
                .controlSize(.large)
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func syncRouteText() {
        routeText = points.map(\.simctlArgument).joined(separator: "\n")
        textPending = false
    }

    private func resolvedPoints() throws -> [Coordinate] {
        if textPending { return try RouteParser.parse(routeText) }
        return points
    }

    private func applyRouteText() {
        do {
            points = try RouteParser.parse(routeText)
            textPending = false
            fitRevision += 1
            controller.status = "已将 \(points.count) 个路径点应用到地图。"
        } catch {
            controller.status = error.localizedDescription
        }
    }

    private func setPoint() {
        do {
            controller.setPoint(try RouteParser.coordinate(latitude: latitude, longitude: longitude))
        } catch {
            controller.status = error.localizedDescription
        }
    }

    private func useSelectedAsPoint() {
        guard let selected = placeSearch.selected else { return }
        latitude = String(selected.coordinate.latitude)
        longitude = String(selected.coordinate.longitude)
        if controller.selectedDevice.isEmpty {
            controller.status = "已将“\(selected.name)”填入单点坐标；请选择模拟器后设置定位。"
        } else {
            controller.setPoint(selected.coordinate)
        }
    }

    private func addSelectedToRoute() {
        guard let selected = placeSearch.selected else { return }
        guard !textPending else {
            controller.status = "请先点击“应用到地图”，再加入搜索地点。"
            return
        }
        guard points.count < 10_000 else {
            controller.status = "路径最多支持 10000 个点。"
            return
        }
        points.append(selected.coordinate)
        syncRouteText()
        controller.status = "已将“\(selected.name)”加入路线。"
    }

    private func currentConfiguration() throws -> RouteConfiguration {
        guard let speedValue = Double(speed), let jitterValue = Double(jitter),
              let passCount = Int(passes),
              let variationValue = Double(pathVariation) else { throw ConfigurationError.invalidSettings }
        return try RouteConfiguration(
            name: name,
            point: RouteParser.coordinate(latitude: latitude, longitude: longitude),
            route: resolvedPoints(),
            speedMetersPerSecond: speedValue,
            jitterPercent: jitterValue,
            passes: passCount,
            pathVariationMeters: variationValue
        )
    }

    private func startRoute() {
        do {
            let config = try currentConfiguration()
            guard config.route.count >= 2 else { throw RouteError.tooFewPoints }
            if textPending {
                points = config.route
                textPending = false
                fitRevision += 1
            }
            controller.start(points: config.route, speed: config.speedMetersPerSecond,
                             jitter: config.jitterPercent, loops: config.passes,
                             variationMeters: config.pathVariationMeters)
        } catch {
            controller.status = error.localizedDescription
        }
    }

    private func saveConfiguration() {
        do {
            let config = try currentConfiguration()
            let data = try ConfigurationCodec.encode(config)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(config.name).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            if textPending {
                points = config.route
                textPending = false
                fitRevision += 1
            }
            controller.status = "配置已保存：\(url.lastPathComponent)"
        } catch {
            controller.status = "保存失败：\(error.localizedDescription)"
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try ConfigurationCodec.decode(Data(contentsOf: url))
            name = config.name
            latitude = String(config.point.latitude)
            longitude = String(config.point.longitude)
            points = config.route
            speed = String(config.speedMetersPerSecond)
            jitter = String(config.jitterPercent)
            passes = String(config.passes)
            pathVariation = String(config.pathVariationMeters)
            syncRouteText()
            fitRevision += 1
            controller.status = "已导入配置：\(url.lastPathComponent)"
        } catch {
            controller.status = "导入失败：\(error.localizedDescription)"
        }
    }
}
