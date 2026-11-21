import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = SimulatorController()
    @StateObject private var placeSearch = PlaceSearchController()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("restoreLastRoute") private var restoreLastRoute = true
    @AppStorage("autoRefreshDevices") private var autoRefreshDevices = true
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("hasAcknowledgedResearchNotice") private var hasAcknowledgedResearchNotice = false
    @AppStorage("lastShownReleaseVersion") private var lastShownReleaseVersion = ""
    @AppStorage("ignoredUpdateVersion") private var ignoredUpdateVersion = ""
    @AppStorage("hideWirelessGuide") private var hideWirelessGuide = false
    @State private var showingResearchNotice = false
    @State private var showingReleaseNotes = false
    @State private var iphoneIP = RecentIPConnection.load().first?.address ?? ""
    @State private var showingWirelessGuide = false
    @State private var showingWirelessSetup = false
    @State private var wirelessGuideDontShowAgain = false
    @State private var name = "我的路线"
    @State private var latitude = "39.9042"
    @State private var longitude = "116.4074"
    @State private var points: [Coordinate] = []
    @State private var routeEditorID = ""
    @State private var deviceDrafts: [String: RouteDraft] = [:]
    @State private var sharedDraft: RouteDraft?
    @State private var editorBaseline: RouteDraft?
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
    @State private var updateMessage: String?
    @State private var checkedAtStartup = false
    @State private var startupUpdate: String?
    @State private var showingUpdateDetails = false
    @State private var showingSearchHistory = false
    @State private var hasLoadedDraft = false
    @State private var hasSavedDraft = false

    private let accent = Color.teal

    var body: some View {
        VStack(spacing: 0) {
            header
            if let version = startupUpdate, version == updateChecker.latestVersion {
                updateBanner(version)
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                mapPanel
                sidebar.frame(width: 310)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: controller.isRunning ? "location.fill" : "info.circle.fill")
                        .foregroundStyle(accent)
                    Text(controller.status)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                }
                Text("仅供开发工具研究学习；请勿用于作弊、造假或其他违法用途。使用后请于 24 小时内删除，使用者自行承担不当使用的后果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !checkedAtStartup {
                checkedAtStartup = true
                Task {
                    await updateChecker.check()
                    if let latest = updateChecker.latestVersion,
                       UpdateChecker.shouldPrompt(current: updateChecker.currentVersion,
                                                  latest: latest, ignoredThrough: ignoredUpdateVersion) {
                        startupUpdate = latest
                    }
                }
            }
            if !hasLoadedDraft { restoreDraftIfNeeded() }
            if let notes = ReleaseNotes.load(currentVersion: updateChecker.currentVersion),
               lastShownReleaseVersion != notes.version {
                showingReleaseNotes = true
            } else {
                continueStartup()
            }
        }
        .onChange(of: controller.wirelessPreparationCount) { _ in
            if !hideWirelessGuide { showingWirelessGuide = true }
        }
        .onChange(of: routeDraft) { draft in
            guard hasLoadedDraft, draft != editorBaseline else { return }
            editorBaseline = nil
            if routeEditorID.isEmpty {
                if RouteDraftStore().save(draft) { hasSavedDraft = true }
            } else {
                deviceDrafts[routeEditorID] = draft
            }
            if controller.isRunning, let config = try? configuration(from: draft, forRun: true, includePending: false) {
                for device in controller.selectedDevices where device.id == routeEditorID
                    || (routeEditorID.isEmpty && deviceDrafts[device.id] == nil) {
                    controller.updateRun(deviceID: device.id, configuration: config)
                }
            }
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(isPresented: $showingReleaseNotes, onDismiss: {
            lastShownReleaseVersion = updateChecker.currentVersion
            continueStartup()
        }) { releaseNotesSheet }
        .sheet(isPresented: $showingWirelessGuide, onDismiss: {
            if wirelessGuideDontShowAgain { hideWirelessGuide = true }
            wirelessGuideDontShowAgain = false
        }) { wirelessGuideSheet }
        .sheet(item: $controller.developerModeGuideDevice) { developerModeGuideSheet($0) }
        .alert("检查更新", isPresented: Binding(
            get: { updateMessage != nil },
            set: { if !$0 { updateMessage = nil } })) {
                Button("确定") { updateMessage = nil }
            } message: {
                Text(updateMessage ?? "")
            }
        .alert("未能通过 IP 连接 iPhone", isPresented: Binding(
            get: { controller.ipConnectionError != nil },
            set: { if !$0 { controller.ipConnectionError = nil } })) {
                Button("确定") { controller.ipConnectionError = nil }
            } message: {
                Text((controller.ipConnectionError ?? "") + "\n\n也可以在 iPhone 的“设置 → 个人热点”打开“允许其他人加入”，让 Mac 连接该热点，再点击“刷新”。")
            }
        .alert("使用须知", isPresented: $showingResearchNotice) {
            Button("我已知悉") {
                hasAcknowledgedResearchNotice = true
                if autoRefreshDevices { controller.refresh() }
            }
        } message: {
            Text("本软件仅用于研究学习 Apple Developer Toolkit 和 Android Debug Bridge，禁止用于作弊、造假等任何非法行为。下载学习后请于 24 小时内删除本软件。使用者因不当使用造成的不良影响由本人自行承担，与开发者无关。")
        }
    }

    private func continueStartup() {
        if !hasAcknowledgedResearchNotice {
            showingResearchNotice = true
        } else if autoRefreshDevices {
            controller.refresh()
        }
    }

    private var releaseNotesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AnyWay \(updateChecker.currentVersion) 更新内容").font(.title2.bold())
            if let notes = ReleaseNotes.load(currentVersion: updateChecker.currentVersion) {
                Text("重大更新").font(.headline)
                ForEach(notes.highlights, id: \.self) { Text("• \($0)") }
                Text("问题修复").font(.headline)
                ForEach(notes.fixes, id: \.self) { Text("• \($0)") }
            }
            HStack {
                Spacer()
                Button("开始使用") { showingReleaseNotes = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 540)
    }

    private func developerModeGuideSheet(_ device: LocationDevice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在 iPhone 上开启开发者模式").font(.title2.bold())
            Text("已尝试为 \(device.name) 显示开发者模式开关。请在手机上完成以下操作：")
            Text("1. 解锁 iPhone，打开“设置 → 隐私与安全性 → 开发者模式”。")
            Text("2. 打开开关并选择“重新启动”。")
            Text("3. 重启后解锁手机，确认“打开开发者模式”，按提示输入锁屏密码。")
            Text("4. 回到 AnyWay，点击“刷新”重新连接设备。")
            HStack {
                Spacer()
                Button("稍后再说") { controller.developerModeGuideDevice = nil }
                Button("完成，刷新设备") {
                    controller.developerModeGuideDevice = nil
                    controller.refresh()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 530)
    }

    private var wirelessGuideSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("iPhone 无线连接已准备好").font(.title2.bold())
            Text("拔掉 USB 数据线后，选择以下任一种连接方式：")
            Text("方案 1：让 Mac 和 iPhone 连接同一个私人局域网。")
            Text("方案 2：在 iPhone 开启个人热点，让 Mac 连接该热点。")
            Text("连接后点击“刷新”。校园网搜不到设备时，可在“目标设备”中输入 iPhone 的 Wi-Fi IPv4 地址直连。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("勾选后不再显示此内容", isOn: $wirelessGuideDontShowAgain)
            HStack {
                Spacer()
                Button("知道了") { showingWirelessGuide = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 530)
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
            Button {
                saveConfiguration()
            } label: {
                Label("保存配置", systemImage: "square.and.arrow.up")
            }
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
            Picker("外观", selection: $appearanceMode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Toggle("启动时恢复上次路线", isOn: $restoreLastRoute)
            Text("自动记住路径点、未应用的坐标文本和移动参数；关闭后仍保存编辑内容，但启动时不自动载入。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("启动时自动刷新设备", isOn: $autoRefreshDevices)
            HStack {
                Text("当前版本：\(updateChecker.currentVersion)")
                Spacer()
                Button(updateChecker.isChecking ? "正在检查…" : "检查更新") {
                    Task {
                        await updateChecker.check()
                        if let error = updateChecker.lastError {
                            updateMessage = "无法连接 GitHub：\(error)"
                        } else if !updateChecker.hasUpdate {
                            updateMessage = "当前已是最新版本（\(updateChecker.currentVersion)）。"
                        }
                    }
                }
                .disabled(updateChecker.isChecking)
            }
            if updateChecker.hasUpdate, let version = updateChecker.latestVersion {
                latestVersionRow(version)
            }
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
        .onChange(of: updateChecker.latestVersion) { _ in showingUpdateDetails = false }
    }

    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 12) {
            Label("AnyWay \(version) 已发布", systemImage: "arrow.down.circle")
                .font(.callout.weight(.semibold))
            Spacer()
            Button("查看更新") {
                startupUpdate = nil
                showingUpdateDetails = true
                showingSettings = true
            }
            Button("稍后") { startupUpdate = nil }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(accent.opacity(0.1))
    }

    private func latestVersionRow(_ version: String) -> some View {
        let canIgnore = UpdateChecker.shouldPrompt(current: updateChecker.currentVersion,
                                                    latest: version, ignoredThrough: ignoredUpdateVersion)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showingUpdateDetails.toggle()
                } label: {
                    Label("最新版本：\(version)", systemImage: showingUpdateDetails ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityHint(showingUpdateDetails ? "收起更新内容" : "展开更新内容")
                Spacer()
                Button(canIgnore ? "忽略本次更新" : "已忽略此版本") {
                    ignoredUpdateVersion = version
                    startupUpdate = nil
                }
                .disabled(!canIgnore)
            }
            if showingUpdateDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let notes = updateChecker.releaseNotes
                        if notes.isEmpty {
                            Text("发布页暂无更新说明。").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(notes.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.hasPrefix("#") {
                                    Text(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).font(.headline)
                                } else if !trimmed.isEmpty {
                                    let paragraph = trimmed.hasPrefix("- ") ? "• " + trimmed.dropFirst(2) : trimmed
                                    Text((try? AttributedString(markdown: paragraph, options: .init(
                                        interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(paragraph))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                if let url = updateChecker.releaseURL { Link("打开新版下载页", destination: url) }
            }
        }
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
                         previewRoute: runningPreview,
                         variationMeters: min(20, max(0, Double(pathVariation) ?? 2)),
                         previewSeed: 42,
                         fitRevision: fitRevision,
                         searchCoordinate: placeSearch.selected?.coordinate,
                         searchTitle: placeSearch.selected?.name ?? "",
                         focusRevision: placeSearch.focusRevision,
                         singlePoint: try? RouteParser.coordinate(latitude: latitude, longitude: longitude),
                         editable: !textPending,
                         onPointMoved: { index, point in
                guard !textPending, points.indices.contains(index) else { return }
                points[index] = point
                syncRouteText()
                controller.status = "已移动第 \(index + 1) 个路径点。"
            }) { point in
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
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary)
                .allowsHitTesting(false))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    guard !points.isEmpty else { return }
                    points.removeLast()
                    syncRouteText()
                } label: {
                    Label("撤销上一点", systemImage: "arrow.uturn.backward")
                }
                .disabled(points.isEmpty || textPending)
                Button("清空路线") {
                    points.removeAll()
                    syncRouteText()
                }
                .disabled(points.isEmpty || textPending)
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
                    Button("加入路线") { addSelectedToRoute() }
                        .disabled(points.count >= 10_000)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card("目标设备", icon: "iphone.gen3") {
                    HStack {
                        Text("已选 \(controller.selectedDevices.count) 台")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if controller.devices.filter({ $0.kind == .iphone }).count > 1 {
                            Button("全选 iPhone") { controller.selectAllIPhones() }
                                .disabled(controller.isBusy)
                        }
                        Button {
                            controller.refresh()
                        } label: {
                            Label(controller.isRefreshing ? "刷新中…" : "刷新设备", systemImage: "arrow.clockwise")
                        }
                        .disabled(controller.isBusy || controller.isRefreshing)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if controller.devices.isEmpty {
                            Text("没有可用设备").foregroundStyle(.secondary)
                        }
                        ForEach(controller.devices) { device in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { controller.selectedDeviceIDs.contains(device.id) },
                                    set: { controller.setSelected(device.id, isSelected: $0) }
                                )) {
                                    if let alias = controller.deviceNames[device.id] {
                                        VStack(alignment: .leading) {
                                            Text(alias)
                                            Text(device.name).font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text(device.name)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                if device.kind != .simulator {
                                    RenameButton(name: controller.deviceNames[device.id] ?? "") {
                                        controller.renameDevice(id: device.id, to: $0)
                                    }
                                }
                            }
                            .disabled(controller.isBusy)
                        }
                    }
                }

                card("iPhone 无线连接", icon: "wifi") {
                    HStack {
                        TextField("iPhone IPv4 地址", text: $iphoneIP)
                            .textFieldStyle(.roundedBorder)
                        Button("通过 IP 连接") { controller.connectIP(iphoneIP) }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .disabled(iphoneIP.isEmpty || controller.isBusy)
                    }
                    if !controller.recentIPs.isEmpty {
                        Divider()
                        Text("最近使用").font(.caption).foregroundStyle(.secondary)
                        ForEach(controller.recentIPs) { entry in
                            HStack {
                                Button {
                                    iphoneIP = entry.address
                                    controller.connectIP(entry.address, expectedUDID: entry.udid)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(controller.deviceNames[entry.deviceID] ?? "iPhone · " + entry.udid.suffix(8))
                                        Text(entry.name.isEmpty ? entry.address : "网络：\(entry.name) · \(entry.address)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help("重新连接此 iPhone")
                                Spacer()
                                RenameButton(name: controller.deviceNames[entry.deviceID] ?? "", network: (
                                    entry.name, { controller.renameConnection(entry, to: $0) }
                                )) {
                                    controller.renameDevice(id: entry.deviceID, to: $0)
                                }
                            }
                            .disabled(controller.isBusy)
                        }
                    }
                    Divider()
                    Button {
                        showingWirelessSetup.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showingWirelessSetup ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text("首次无线配对")
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showingWirelessSetup ? "已展开" : "已收起")
                    if showingWirelessSetup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("用 USB 连接并选中 iPhone，再开启无线连接。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("开启无线连接") { controller.prepareWirelessIPhones() }
                                .disabled(controller.isBusy || !controller.selectedDevices.contains {
                                    $0.kind == .iphone && $0.isUSB
                                })
                        }
                        .padding(.top, 6)
                    }
                }

                card("单点定位", icon: "mappin.circle") {
                    Button(selectingSinglePoint ? "退出地图选点" : "在地图上选点") {
                        selectingSinglePoint.toggle()
                    }
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
                    Picker("编辑路线", selection: Binding(
                        get: { routeEditorID }, set: { switchRouteEditor(to: $0) }
                    )) {
                        Text("共用配置").tag("")
                        ForEach(controller.devices) { device in
                            Text(controller.deviceNames[device.id] ?? device.name).tag(device.id)
                        }
                        if !routeEditorID.isEmpty && !controller.devices.contains(where: { $0.id == routeEditorID }) {
                            Text("已断开的设备").tag(routeEditorID)
                        }
                    }
                    if !routeEditorID.isEmpty, deviceDrafts[routeEditorID] != nil {
                        Button("恢复使用共用配置") {
                            let deviceID = routeEditorID
                            switchRouteEditor(to: "")
                            deviceDrafts.removeValue(forKey: deviceID)
                            if let config = try? configuration(from: routeDraft, forRun: true, includePending: false) {
                                controller.updateRun(deviceID: deviceID, configuration: config)
                            }
                        }
                    }
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
                        Button("应用到地图") { applyRouteText() }
                            .disabled(!textPending)
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
                    Text("每圈在路线附近生成不同轨迹。偏移设为 0 时使用 0.5 米上限，短路线按比例缩小。")
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

    private var runningPreview: [Coordinate] {
        if !routeEditorID.isEmpty { return controller.previews[routeEditorID] ?? [] }
        for device in controller.selectedDevices where deviceDrafts[device.id] == nil {
            if let preview = controller.previews[device.id] { return preview }
        }
        return []
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
            applyDraft(draft)
        }
        hasLoadedDraft = true
    }

    private func applyDraft(_ draft: RouteDraft) {
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

    private func switchRouteEditor(to deviceID: String) {
        guard deviceID != routeEditorID else { return }
        let current = routeDraft
        if routeEditorID.isEmpty {
            sharedDraft = current
        } else if current != editorBaseline {
            deviceDrafts[routeEditorID] = current
        }
        guard let sharedDraft else { return }
        routeEditorID = deviceID
        let next = deviceDrafts[deviceID] ?? sharedDraft
        editorBaseline = next
        applyDraft(next)
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
        if controller.isBusy || !controller.hasSelectedDevices {
            controller.status = "已将“\(selected.name)”填入单点坐标。"
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

    private func configuration(from draft: RouteDraft, forRun: Bool = false,
                               includePending: Bool = true) throws -> RouteConfiguration {
        guard let speed = Double(draft.speed), let jitter = Double(draft.jitter),
              let passes = Int(draft.passes), let variation = Double(draft.pathVariation) else {
            throw ConfigurationError.invalidSettings
        }
        let route = includePending && draft.textPending ? try RouteParser.parse(draft.routeText) : draft.points
        let point = if forRun, let first = route.first {
            first
        } else {
            try RouteParser.coordinate(latitude: draft.latitude, longitude: draft.longitude)
        }
        return try RouteConfiguration(
            name: forRun ? "路线" : draft.name,
            point: point,
            route: route,
            speedMetersPerSecond: speed,
            jitterPercent: jitter,
            passes: passes,
            pathVariationMeters: variation,
            dynamicSpeed: draft.dynamicSpeed,
            dynamicSpeedPlan: dynamicSpeedPlan(from: draft)
        )
    }

    private func dynamicSpeedPlan(from draft: RouteDraft) throws -> DynamicSpeedPlan {
        guard let settings = draft.dynamicSpeedDraft else { return .standard }
        if settings.mode == .automatic {
            return DynamicSpeedPlan(mode: .automatic, preset: settings.preset, intervalKilometers: 0.8,
                                    lowPaceSeconds: 600, recoverySeconds: 25)
        }
        guard let interval = Double(settings.intervalKilometers),
              let minutes = Int(settings.lowPaceMinutes), let seconds = Int(settings.lowPaceSeconds),
              RunningPace.speed(minutes: minutes, seconds: seconds) != nil,
              let duration = Double(settings.recoverySeconds) else {
            if draft.dynamicSpeed { throw ConfigurationError.invalidDynamicSpeed }
            return .standard
        }
        return DynamicSpeedPlan(mode: .custom, preset: settings.preset, intervalKilometers: interval,
                                lowPaceSeconds: minutes * 60 + seconds, recoverySeconds: duration)
    }

    private func startRoute() {
        do {
            let current = routeDraft
            let shared = sharedDraft ?? current
            var configurations: [String: RouteConfiguration] = [:]
            for device in controller.selectedDevices {
                let draft = routeEditorID.isEmpty ? deviceDrafts[device.id] ?? current
                    : device.id == routeEditorID && current != editorBaseline ? current
                    : deviceDrafts[device.id] ?? shared
                guard !draft.textPending else {
                    throw SimctlError.failed("请先在对应路线中点击“应用到地图”，再开始模拟。")
                }
                configurations[device.id] = try configuration(from: draft, forRun: true)
            }
            controller.start(configurations: configurations)
        } catch {
            controller.status = error.localizedDescription
        }
    }

    private func saveConfiguration() {
        do {
            let config = try configuration(from: routeDraft)
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


private struct RenameButton: View {
    let name: String
    var network: (name: String, save: (String) -> Void)? = nil
    let save: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var networkDraft = ""

    var body: some View {
        Button {
            draft = name
            networkDraft = network?.name ?? ""
            editing = true
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(network == nil ? "编辑设备名称" : "编辑设备和网络名称")
        .help(network == nil ? "编辑设备名称" : "编辑设备和网络名称")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("设备名称").font(.headline)
                TextField("留空恢复默认显示", text: $draft)
                    .textFieldStyle(.roundedBorder)
                if network != nil {
                    Text("网络名称").font(.headline)
                    TextField("例如：校园网", text: $networkDraft)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer()
                    Button("取消") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        if draft != name { save(draft) }
                        if let network, networkDraft != network.name { network.save(networkDraft) }
                        editing = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding().frame(width: 250)
        }
    }
}
