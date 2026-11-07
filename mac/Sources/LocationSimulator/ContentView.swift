import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = SimulatorController()
    @StateObject private var placeSearch = PlaceSearchController()
    @AppStorage("restoreLastRoute") private var restoreLastRoute = true
    @AppStorage("autoRefreshDevices") private var autoRefreshDevices = true
    @State private var name = "我的路线"
    @State private var latitude = "39.9042"
    @State private var longitude = "116.4074"
    @State private var points: [Coordinate] = []
    @State private var routeText = ""
    @State private var textPending = false
    @State private var fitRevision = 0
    @State private var speed = "5"
    @State private var paceMinutes = "3"
    @State private var paceSeconds = "20"
    @State private var jitter = "15"
    @State private var passes = "2"
    @State private var pathVariation = "2"
    @State private var dynamicSpeed = false
    @State private var dynamicMode: DynamicSpeedMode = .automatic
    @State private var dynamicPreset: DynamicSpeedPreset = .campus
    @State private var recoveryEveryKm = "0.8"
    @State private var lowPaceMinutes = "10"
    @State private var lowPaceSeconds = "0"
    @State private var recoverySeconds = "25"
    @State private var trackSide: TrackSide = .right
    @State private var editorMode = 0
    @State private var selectingSinglePoint = false
    @State private var showingSettings = false
    @State private var showingSearchHistory = false
    @State private var hasLoadedDraft = false
    @State private var hasSavedDraft = false

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
        .onAppear {
            if !hasLoadedDraft { restoreDraftIfNeeded() }
            if autoRefreshDevices { controller.refresh() }
        }
        .onChange(of: routeDraft) { draft in
            guard hasLoadedDraft else { return }
            if RouteDraftStore().save(draft) { hasSavedDraft = true }
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
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
            Button { showingSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
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

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("设置", systemImage: "gearshape").font(.title2.bold())
                Spacer()
                Button("完成") { showingSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            Toggle("启动时恢复上次路线", isOn: $restoreLastRoute)
            Text("自动记住路径点、未应用的坐标文本和移动参数；关闭后仍保存编辑内容，但启动时不自动载入。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("启动时自动刷新设备", isOn: $autoRefreshDevices)
            Divider()
            HStack {
                Text("搜索历史：\(placeSearch.history.count) 条")
                Spacer()
                Button("清除搜索历史") { placeSearch.clearHistory() }
                    .disabled(placeSearch.history.isEmpty)
            }
            HStack {
                Text("上次路线记忆")
                Spacer()
                Button("清除路线记忆") {
                    RouteDraftStore().clear()
                    hasSavedDraft = false
                }
                .disabled(!hasSavedDraft)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("地图画布").font(.headline)
                    Text(selectingSinglePoint ? "单击地图选择单点定位；拖动可移动地图"
                         : "单击添加路径点；曲线显示当前模拟轨迹")
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
                         focusRevision: placeSearch.focusRevision,
                         singlePoint: try? RouteParser.coordinate(latitude: latitude, longitude: longitude),
                         editable: !controller.isRunning && !textPending,
                         onPointMoved: { index, point in
                guard !controller.isRunning, !textPending, points.indices.contains(index) else { return }
                points[index] = point
                syncRouteText()
                controller.status = "已移动第 \(index + 1) 个路径点。"
            }) { point in
                guard !controller.isRunning else { return }
                if selectingSinglePoint {
                    latitude = String(point.latitude)
                    longitude = String(point.longitude)
                    controller.status = "已在地图上选择单点。点击“设置定位”应用到设备。"
                    return
                }
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
                    .onChange(of: placeSearch.query) { _ in placeSearch.queryChanged() }
                Button { showingSearchHistory = true } label: {
                    Label("搜索历史", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("查看搜索历史")
                .popover(isPresented: $showingSearchHistory, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("搜索历史").font(.headline)
                        if placeSearch.history.isEmpty {
                            Text("暂无搜索记录")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(placeSearch.history, id: \.self) { item in
                                Button {
                                    placeSearch.searchHistoryItem(item)
                                    showingSearchHistory = false
                                } label: {
                                    Label(item, systemImage: "clock.arrow.circlepath")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                            Divider()
                            Button("清除历史") { placeSearch.clearHistory() }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(14)
                    .frame(width: 250, alignment: .leading)
                }
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
                card("目标设备", icon: "iphone.gen3") {
                    VStack(alignment: .leading, spacing: 6) {
                        if controller.devices.isEmpty {
                            Text("没有可用设备").foregroundStyle(.secondary)
                        }
                        ForEach(controller.devices) { device in
                            Toggle(device.name, isOn: Binding(
                                get: { controller.selectedDeviceIDs.contains(device.id) },
                                set: { controller.setSelected(device.id, isSelected: $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(controller.isBusy)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("已选 \(controller.selectedDevices.count) 台")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("全选 iPhone") { controller.selectAllIPhones() }
                            .disabled(!controller.hasIPhones || controller.isBusy)
                        Button { controller.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(controller.isBusy)
                        .help("刷新模拟器、iPhone 与 Android 设备")
                    }
                }

                card("单点定位", icon: "mappin.circle") {
                    Button(selectingSinglePoint ? "退出地图选点" : "在地图上选点") {
                        selectingSinglePoint.toggle()
                    }
                    .disabled(controller.isRunning)
                    Text(selectingSinglePoint ? "在左侧地图单击目标位置，坐标会自动填入下方。"
                         : "可以输入坐标、搜索地点，或在地图上选点。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    .disabled(!controller.hasSelectedDevices || controller.isBusy)
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
                        Text("在左侧地图单击添加路径点。终点会自动连接起点，重复运行时同向绕圈。")
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

                card("400 米环形跑道", icon: "figure.run.circle") {
                    Text("在地图上标出一条长直边的两个端点；模板会补全另一条直边和两端弯道。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("展开方向", selection: $trackSide) {
                        ForEach(TrackSide.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("方向按第 1 点到第 2 点判断；两点需相距 20～199 米。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("由两个端点生成跑道") { generateTrack() }
                        .disabled(controller.isRunning)
                }

                card("移动参数", icon: "speedometer") {
                    HStack(spacing: 8) {
                        field("速度 m/s", text: $speed)
                        field("抖动 ±%", text: $jitter)
                        field("圈数", text: $passes)
                    }
                    HStack(spacing: 8) {
                        field("配速 分/公里", text: $paceMinutes)
                        field("秒/公里", text: $paceSeconds)
                    }
                    .onChange(of: paceMinutes) { _ in syncSpeedFromPace() }
                    .onChange(of: paceSeconds) { _ in syncSpeedFromPace() }
                    .onChange(of: speed) { _ in syncPaceFromSpeed() }
                    Toggle("动态速度", isOn: $dynamicSpeed)
                        .font(.caption)
                    if dynamicSpeed {
                        Picker("配置方式", selection: $dynamicMode) {
                            ForEach(DynamicSpeedMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if dynamicMode == .automatic {
                            Picker("自动范例", selection: $dynamicPreset) {
                                ForEach(DynamicSpeedPreset.allCases, id: \.self) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(dynamicPreset.description)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            field("每隔多少公里进入低速段", text: $recoveryEveryKm)
                            HStack(spacing: 8) {
                                field("低速配速 分/公里", text: $lowPaceMinutes)
                                field("秒/公里", text: $lowPaceSeconds)
                            }
                            field("低速持续秒数", text: $recoverySeconds)
                        }
                    }
                    field("路线偏移上限 m", text: $pathVariation)
                    Text("每圈生成不同的平滑轨迹；中途路径点带小幅偏差，闭合点保持准确。")
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
                    .disabled(!controller.hasSelectedDevices || controller.isBusy)

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

    private var routeDraft: RouteDraft {
        RouteDraft(name: name, latitude: latitude, longitude: longitude,
                   points: points, routeText: routeText, textPending: textPending,
                   speed: speed, jitter: jitter, passes: passes,
                   pathVariation: pathVariation, dynamicSpeed: dynamicSpeed,
                   dynamicSpeedDraft: DynamicSpeedDraft(
                    mode: dynamicMode, preset: dynamicPreset,
                    intervalKilometers: recoveryEveryKm,
                    lowPaceMinutes: lowPaceMinutes,
                    lowPaceSeconds: lowPaceSeconds,
                    recoverySeconds: recoverySeconds),
                   editorMode: editorMode)
    }

    private func restoreDraftIfNeeded() {
        let store = RouteDraftStore()
        hasSavedDraft = store.hasSavedDraft
        if restoreLastRoute, let draft = store.load() {
            name = draft.name
            latitude = draft.latitude
            longitude = draft.longitude
            points = draft.points
            routeText = draft.routeText
            textPending = draft.textPending
            speed = draft.speed
            if let speedValue = Double(draft.speed),
               let pace = RunningPace.components(speed: speedValue) {
                paceMinutes = String(pace.minutes)
                paceSeconds = String(pace.seconds)
            }
            jitter = draft.jitter
            passes = draft.passes
            pathVariation = draft.pathVariation
            dynamicSpeed = draft.dynamicSpeed
            if let dynamicDraft = draft.dynamicSpeedDraft {
                dynamicMode = dynamicDraft.mode
                dynamicPreset = dynamicDraft.preset
                recoveryEveryKm = dynamicDraft.intervalKilometers
                lowPaceMinutes = dynamicDraft.lowPaceMinutes
                lowPaceSeconds = dynamicDraft.lowPaceSeconds
                recoverySeconds = dynamicDraft.recoverySeconds
            }
            editorMode = draft.editorMode
            fitRevision += 1
        }
        hasLoadedDraft = true
    }

    private func syncSpeedFromPace() {
        guard let minutes = Int(paceMinutes), let seconds = Int(paceSeconds),
              let paceSpeed = RunningPace.speed(minutes: minutes, seconds: seconds) else { return }
        if let currentSpeed = Double(speed),
           let components = RunningPace.components(speed: currentSpeed),
           components.minutes == minutes, components.seconds == seconds { return }
        speed = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), paceSpeed)
    }

    private func syncPaceFromSpeed() {
        guard let value = Double(speed),
              let components = RunningPace.components(speed: value) else { return }
        let minutes = String(components.minutes)
        let seconds = String(components.seconds)
        if paceMinutes != minutes { paceMinutes = minutes }
        if paceSeconds != seconds { paceSeconds = seconds }
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

    private func generateTrack() {
        do {
            let endpoints = try resolvedPoints()
            guard endpoints.count == 2 else {
                controller.status = "请先只保留长直边的两个端点，再生成跑道。"
                return
            }
            let track = try TrackTemplate.generate(from: endpoints[0], to: endpoints[1],
                                                   side: trackSide)
            points = track.points
            editorMode = 0
            selectingSinglePoint = false
            syncRouteText()
            fitRevision += 1
            controller.status = String(format: "已生成 %.1f 米环形跑道，宽约 %.0f 米。",
                                       track.lengthMeters, track.widthMeters)
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
        placeSearch.rememberCurrentQuery()
        latitude = String(selected.coordinate.latitude)
        longitude = String(selected.coordinate.longitude)
        if !controller.hasSelectedDevices {
            controller.status = "已将“\(selected.name)”填入单点坐标；请选择设备后设置定位。"
        } else {
            controller.setPoint(selected.coordinate)
        }
    }

    private func addSelectedToRoute() {
        guard let selected = placeSearch.selected else { return }
        placeSearch.rememberCurrentQuery()
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
        guard let minutes = Int(paceMinutes), let seconds = Int(paceSeconds),
              RunningPace.speed(minutes: minutes, seconds: seconds) != nil,
              let speedValue = Double(speed), let jitterValue = Double(jitter),
              let passCount = Int(passes),
              let variationValue = Double(pathVariation) else { throw ConfigurationError.invalidSettings }
        let plan = try dynamicSpeedPlan(baseSpeed: speedValue)
        return try RouteConfiguration(
            name: name,
            point: RouteParser.coordinate(latitude: latitude, longitude: longitude),
            route: resolvedPoints(),
            speedMetersPerSecond: speedValue,
            jitterPercent: jitterValue,
            passes: passCount,
            pathVariationMeters: variationValue,
            dynamicSpeed: dynamicSpeed,
            dynamicSpeedPlan: plan
        )
    }

    private func dynamicSpeedPlan(baseSpeed: Double) throws -> DynamicSpeedPlan {
        if dynamicMode == .automatic {
            return DynamicSpeedPlan(mode: .automatic, preset: dynamicPreset,
                                    intervalKilometers: 0.8, lowPaceSeconds: 600,
                                    recoverySeconds: 25)
        }
        guard let interval = Double(recoveryEveryKm),
              let minutes = Int(lowPaceMinutes), let seconds = Int(lowPaceSeconds),
              RunningPace.speed(minutes: minutes, seconds: seconds) != nil,
              let duration = Double(recoverySeconds) else {
            if dynamicSpeed { throw ConfigurationError.invalidDynamicSpeed }
            return .standard
        }
        let plan = DynamicSpeedPlan(mode: .custom, preset: dynamicPreset,
                                    intervalKilometers: interval,
                                    lowPaceSeconds: minutes * 60 + seconds,
                                    recoverySeconds: duration)
        if dynamicSpeed && !plan.isValid(baseSpeed: baseSpeed) {
            throw ConfigurationError.invalidDynamicSpeed
        }
        return plan
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
                             variationMeters: config.pathVariationMeters,
                             dynamicSpeed: config.dynamicSpeed,
                             dynamicSpeedPlan: config.dynamicSpeedPlan)
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
            if let pace = RunningPace.components(speed: config.speedMetersPerSecond) {
                paceMinutes = String(pace.minutes)
                paceSeconds = String(pace.seconds)
            }
            jitter = String(config.jitterPercent)
            passes = String(config.passes)
            pathVariation = String(config.pathVariationMeters)
            dynamicSpeed = config.dynamicSpeed
            dynamicMode = config.dynamicSpeedPlan.mode
            dynamicPreset = config.dynamicSpeedPlan.preset
            recoveryEveryKm = String(config.dynamicSpeedPlan.intervalKilometers)
            lowPaceMinutes = String(config.dynamicSpeedPlan.lowPaceSeconds / 60)
            lowPaceSeconds = String(config.dynamicSpeedPlan.lowPaceSeconds % 60)
            recoverySeconds = String(config.dynamicSpeedPlan.recoverySeconds)
            syncRouteText()
            fitRevision += 1
            controller.status = "已导入配置：\(url.lastPathComponent)"
        } catch {
            controller.status = "导入失败：\(error.localizedDescription)"
        }
    }
}

