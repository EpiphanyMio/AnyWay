"""Windows desktop UI. Run with `python -m winloc.app`."""
from __future__ import annotations

from dataclasses import asdict
import json
import os
from pathlib import Path
import random
import sys
import threading
import time

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDialog, QDoubleSpinBox,
    QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QMainWindow, QMessageBox, QPushButton, QScrollArea, QSpinBox, QSplitter,
    QTabWidget, QTextEdit, QVBoxLayout, QWidget)
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEngineSettings
from PySide6.QtWebEngineWidgets import QWebEngineView

from .core import (Configuration, Coordinate, DynamicPlan, MotionProfile, RouteStepper,
                   closed, generate_track, pace_to_speed, parse_points, speed_to_pace)
from .ios import PhoneSession, connected_devices
from .place_search import USER_AGENT, nearby_sports, search_places
from .update_check import UpdateResult, check_update
from .android import AndroidBridge, connected_devices as connected_android_devices
from .driver_check import (DriverReport, install_apple_devices,
                           probe as probe_ios_drivers)
from .harmony import (HarmonyBridge, configure_hdc,
                      connected_devices as connected_harmony_devices,
                      harmony_usb_connected)

APP_DIR = Path(os.getenv("APPDATA") or Path.home() / ".config") / "WindowsLocationSimulator"
SETTINGS = APP_DIR / "settings.json"
DRAFT = APP_DIR / "draft.json"
RESEARCH_NOTICE = ("本软件仅用于研究学习 Apple Developer Toolkit 和 Android Debug Bridge，禁止用于作弊、造假等任何非法行为。"
                   "下载学习后请于 24 小时内删除本软件。使用者因不当使用造成的不良影响由本人自行承担，与开发者无关。")


class TaskSignals(QObject):
    result = Signal(object)
    error = Signal(str)


class Task(QRunnable):
    def __init__(self, fn):
        super().__init__()
        self.fn = fn
        self.signals = TaskSignals()

    def run(self):
        try:
            self.signals.result.emit(self.fn())
        except Exception as exc:
            self.signals.error.emit(str(exc))


class UpdateRequiredDialog(QDialog):
    def __init__(self, parent, result: UpdateResult):
        super().__init__(parent)
        self.setWindowTitle("需要更新 AnyWay")
        self.setWindowModality(Qt.WindowModality.ApplicationModal)
        self.setWindowFlag(Qt.WindowType.WindowCloseButtonHint, False)
        layout = QVBoxLayout(self)
        message = QLabel(f"发现新版本 {result.latest}（当前 {result.current}）。\n"
                         "请先下载安装最新版，再继续使用。")
        message.setWordWrap(True)
        layout.addWidget(message)
        download = QPushButton("打开新版下载页")
        download.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(result.release_url)))
        layout.addWidget(download)
        quit_button = QPushButton("退出软件")
        quit_button.clicked.connect(self._quit)
        layout.addWidget(quit_button)
        self.setMinimumWidth(370)

    def _quit(self):
        self.accept()
        QApplication.instance().quit()

    def reject(self):
        pass

    def closeEvent(self, event):
        event.ignore()


class MapBridge(QObject):
    clicked = Signal(float, float)
    point_moved = Signal(int, float, float)

    @Slot(float, float)
    def mapClicked(self, latitude, longitude):
        self.clicked.emit(latitude, longitude)

    @Slot(int, float, float)
    def pointMoved(self, index, latitude, longitude):
        self.point_moved.emit(index, latitude, longitude)


class RouteSignals(QObject):
    status = Signal(str)
    point = Signal(object)
    preview = Signal(object)
    finished = Signal()


class RouteRunner(QRunnable):
    def __init__(self, session, udid, config):
        super().__init__()
        self.session, self.udid, self.config = session, udid, config
        self.stop_event = threading.Event()
        self.signals = RouteSignals()

    def run(self):
        c = self.config
        if hasattr(self.session, "replay"):
            try:
                self.session.replay(self.udid, c, self.stop_event,
                                    self.signals.status.emit, self.signals.preview.emit)
            except Exception as exc:
                self.signals.status.emit(f"模拟失败：{exc}")
            finally:
                self.signals.finished.emit()
            return
        points = closed(c.route)
        seed = random.getrandbits(64)
        motion = MotionProfile(c.speedMetersPerSecond, c.dynamicSpeed, c.dynamicSpeedPlan, seed)
        offset = 0.0
        try:
            self.session.set(self.udid, points[0])
            self.signals.point.emit(points[0])
            for lap in range(c.passes):
                if self.stop_event.is_set():
                    break
                stepper = RouteStepper(points, c.pathVariationMeters, seed + lap)
                self.signals.preview.emit((points, seed + lap))
                self.signals.status.emit(f"正在运行第 {lap + 1}/{c.passes} 圈。")
                last = time.monotonic()
                while not stepper.finished and not self.stop_event.is_set():
                    self.stop_event.wait(max(0, .5 - (time.monotonic() - last)))
                    if self.stop_event.is_set():
                        break
                    now = time.monotonic()
                    elapsed = max(.001, now - last)
                    last = now
                    offset = .8 * offset + .2 * random.uniform(-c.jitterPercent / 100, c.jitterPercent / 100)
                    point = stepper.advance(motion.advance(elapsed, 1 + offset))
                    self.session.set(self.udid, point)
                    self.signals.point.emit(point)
                    if c.dynamicSpeed and motion.recovery_left:
                        self.signals.status.emit(f"正在运行第 {lap + 1}/{c.passes} 圈 · 低速段。")
            self.signals.status.emit("路径模拟已停止，定位停留在当前点。" if self.stop_event.is_set()
                                     else "路径模拟完成，定位停留在最后一个点。")
        except Exception as exc:
            self.signals.status.emit(f"模拟失败：{exc}")
        finally:
            self.signals.finished.emit()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AnyWay · Windows")
        available = QApplication.primaryScreen().availableGeometry()
        self.resize(min(1250, available.width()), min(820, available.height()))
        self.pool = QThreadPool.globalInstance()
        self.ios_session = PhoneSession()
        self.android_bridge = AndroidBridge()
        self.harmony_bridge = HarmonyBridge()
        self.runner = None
        self._device_busy = False
        self.points = []
        self.places = []
        self.selected_place = None
        self.text_pending = False
        self._cleared_draft_snapshot = None
        self.map_ready = False
        self.groups = []
        self.settings = self._read_json(SETTINGS, {"restore": True, "auto_refresh": True, "history": []})
        self._build_ui()
        self._apply_style()
        self._load_draft()
        self._update_action_state()
        self.draft_timer = QTimer(self)
        self.draft_timer.timeout.connect(self._save_draft)
        self.draft_timer.start(2000)
        if not self.settings.get("research_notice_acknowledged", False):
            QTimer.singleShot(0, self._show_research_notice)
        if self.settings.get("auto_refresh", True):
            QTimer.singleShot(200, self.refresh_devices)
        QTimer.singleShot(300, self.check_for_updates)

    @staticmethod
    def _read_json(path, fallback):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return fallback

    @staticmethod
    def _write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")

    def _button(self, title, callback, row):
        button = QPushButton(title)
        button.clicked.connect(callback)
        row.addWidget(button)
        return button

    def _box(self, title, parent):
        box = QGroupBox(title)
        self.groups.append(box)
        layout = QVBoxLayout(box)
        parent.addWidget(box)
        return layout

    def _build_ui(self):
        root = QWidget()
        root.setObjectName("centralRoot")
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(18, 16, 18, 12)
        outer.setSpacing(12)
        toolbar = QHBoxLayout()
        title = QLabel("AnyWay")
        title.setObjectName("appTitle")
        toolbar.addWidget(title)
        subtitle = QLabel("位置模拟工作台")
        subtitle.setObjectName("appSubtitle")
        toolbar.addWidget(subtitle)
        toolbar.addStretch()
        self._button("设置", self.show_settings, toolbar)
        self.import_button = self._button("导入配置", self.import_config, toolbar)
        self.save_button = self._button("保存配置", self.save_config, toolbar)
        outer.addLayout(toolbar)
        splitter = QSplitter(Qt.Horizontal)
        outer.addWidget(splitter, 1)
        left = QWidget()
        left_layout = QVBoxLayout(left)
        search_row = QHBoxLayout()
        self.search_input = QLineEdit()
        self.search_input.setPlaceholderText("搜索地点或学校，例如：北京大学")
        self.search_input.returnPressed.connect(self.search)
        search_row.addWidget(self.search_input, 1)
        self._button("历史", self.show_history, search_row)
        self._button("搜索", self.search, search_row)
        left_layout.addLayout(search_row)
        self.results = QListWidget()
        self.results.setMaximumHeight(94)
        self.results.currentRowChanged.connect(self.select_place)
        left_layout.addWidget(self.results)
        result_row = QHBoxLayout()
        self.place_point_button = self._button("设为单点", self.place_as_point, result_row)
        self.place_route_button = self._button("加入路线", self.place_to_route, result_row)
        result_row.addStretch()
        left_layout.addLayout(result_row)
        self.map = QWebEngineView()
        self.map.setObjectName("mapCanvas")
        self.map.settings().setAttribute(QWebEngineSettings.WebAttribute.LocalContentCanAccessRemoteUrls, True)
        self.map.page().profile().setHttpUserAgent(USER_AGENT)
        self.bridge = MapBridge()
        self.bridge.clicked.connect(self.map_clicked)
        self.bridge.point_moved.connect(self.map_point_moved)
        channel = QWebChannel(self.map.page())
        channel.registerObject("bridge", self.bridge)
        self.map.page().setWebChannel(channel)
        self.map.loadFinished.connect(self._map_loaded)
        map_dir = Path(__file__).parent
        map_html = (map_dir / "map.html").read_text(encoding="utf-8")
        for placeholder, asset in (
            ("__LEAFLET_CSS__", map_dir / "vendor" / "leaflet" / "leaflet.css"),
            ("__QWEBCHANNEL_JS__", map_dir / "qwebchannel.js"),
            ("__LEAFLET_JS__", map_dir / "vendor" / "leaflet" / "leaflet.js"),
        ):
            map_html = map_html.replace(placeholder, asset.read_text(encoding="utf-8"))
        self.map.setHtml(map_html, QUrl.fromLocalFile(str(map_dir / "map.html")))
        left_layout.addWidget(self.map, 1)
        map_buttons = QHBoxLayout()
        self.undo_button = self._button("撤销上一点", self.undo_point, map_buttons)
        self.clear_route_button = self._button("清空路线", self.clear_route, map_buttons)
        self._button("适合窗口", lambda: self.draw_map(True), map_buttons)
        left_layout.addLayout(map_buttons)
        splitter.addWidget(left)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        side = QVBoxLayout(sidebar)
        scroll.setWidget(sidebar)
        scroll.setMinimumWidth(360)
        splitter.addWidget(scroll)
        splitter.setSizes([830, 400])

        devices = self._box("目标设备", side)
        self.device_combo = QComboBox()
        devices.addWidget(self.device_combo)
        row = QHBoxLayout()
        self.refresh_button = self._button("刷新", self.refresh_devices, row)
        self._button("检查 iOS 驱动", self.check_ios_drivers, row)
        devices.addLayout(row)
        device_hint = QLabel("支持 USB iPhone、ADB Android 和 hdc HarmonyOS 7+ 设备。")
        device_hint.setWordWrap(True)
        devices.addWidget(device_hint)
        self.driver_guide = QLabel()
        self.driver_guide.setTextFormat(Qt.RichText)
        self.driver_guide.setOpenExternalLinks(True)
        self.driver_guide.setWordWrap(True)
        self.driver_guide.hide()
        devices.addWidget(self.driver_guide)
        self.repair_button = self._button("一键补全 iOS 驱动", self.repair_ios_drivers, devices)
        self.repair_button.hide()

        single = self._box("单点定位", side)
        self.pick_point = QCheckBox("在地图上选点")
        single.addWidget(self.pick_point)
        form = QFormLayout()
        self.latitude, self.longitude = QLineEdit("39.9042"), QLineEdit("116.4074")
        form.addRow("纬度", self.latitude)
        form.addRow("经度", self.longitude)
        single.addLayout(form)
        row = QHBoxLayout()
        self.set_button = self._button("设置定位", self.set_point, row)
        self.clear_button = self._button("清除定位", self.clear_location, row)
        single.addLayout(row)

        route = self._box("路径编辑", side)
        self.name = QLineEdit("我的路线")
        route.addWidget(self.name)
        self.editor_tabs = QTabWidget()
        map_tab = QWidget()
        map_tab_layout = QVBoxLayout(map_tab)
        route_hint = QLabel("在左侧地图单击添加路径点，拖动已有点可调整位置；终点会自动连接起点。")
        route_hint.setWordWrap(True)
        map_tab_layout.addWidget(route_hint)
        map_tab_layout.addStretch()
        self.editor_tabs.addTab(map_tab, "地图绘制")
        text_tab = QWidget()
        text_layout = QVBoxLayout(text_tab)
        self.route_text = QTextEdit()
        self.route_text.setPlaceholderText("每行：纬度,经度")
        self.route_text.setMaximumHeight(115)
        self.route_text.textChanged.connect(self._text_changed)
        text_layout.addWidget(self.route_text)
        self.apply_button = self._button("应用到地图", self.apply_text, text_layout)
        self.editor_tabs.addTab(text_tab, "坐标文本")
        route.addWidget(self.editor_tabs)

        track = self._box("400 米环形跑道", side)
        track_hint = QLabel("先在地图上选择一条长直边的两个端点（20～200 米，不含 200 米）。")
        track_hint.setWordWrap(True)
        track.addWidget(track_hint)
        self.track_side = QComboBox()
        self.track_side.addItem("右侧展开", "right")
        self.track_side.addItem("左侧展开", "left")
        track.addWidget(self.track_side)
        self.track_button = self._button("由两个端点生成跑道", self.make_track, track)

        params = self._box("移动参数", side)
        form = QFormLayout()
        self.speed = QDoubleSpinBox()
        self.speed.setRange(.01, 100)
        self.speed.setDecimals(3)
        self.speed.setValue(5)
        self.speed.valueChanged.connect(self._sync_pace)
        form.addRow("速度 m/s", self.speed)
        self.pace_min, self.pace_sec = QSpinBox(), QSpinBox()
        self.pace_min.setRange(0, 999)
        self.pace_sec.setRange(0, 59)
        self.pace_min.setValue(3)
        self.pace_sec.setValue(20)
        self.pace_min.valueChanged.connect(self._sync_speed)
        self.pace_sec.valueChanged.connect(self._sync_speed)
        form.addRow("配速 分/公里", self.pace_min)
        form.addRow("配速 秒/公里", self.pace_sec)
        self.jitter = QDoubleSpinBox()
        self.jitter.setRange(0, 100)
        self.jitter.setValue(15)
        form.addRow("速度抖动 ±%", self.jitter)
        self.passes = QSpinBox()
        self.passes.setRange(1, 1000)
        self.passes.setValue(2)
        form.addRow("圈数", self.passes)
        self.variation = QDoubleSpinBox()
        self.variation.setRange(0, 20)
        self.variation.setValue(2)
        self.variation.valueChanged.connect(lambda: self.draw_map(False))
        form.addRow("路线偏移上限 m", self.variation)
        params.addLayout(form)
        self.dynamic = QCheckBox("动态速度")
        params.addWidget(self.dynamic)
        self.dynamic_mode = QComboBox()
        self.dynamic_mode.addItem("自动配置", "automatic")
        self.dynamic_mode.addItem("自定义", "custom")
        params.addWidget(self.dynamic_mode)
        self.preset = QComboBox()
        for name, key in (("间歇慢跑", "campus"), ("轻松跑", "easy"), ("耐力跑", "endurance")):
            self.preset.addItem(name, key)
        params.addWidget(self.preset)
        custom = QFormLayout()
        self.interval = QDoubleSpinBox()
        self.interval.setRange(.1, 20)
        self.interval.setValue(.8)
        custom.addRow("低速间隔 km", self.interval)
        self.low_min, self.low_sec = QSpinBox(), QSpinBox()
        self.low_min.setRange(1, 60)
        self.low_min.setValue(10)
        self.low_sec.setRange(0, 59)
        custom.addRow("低速配速 分/公里", self.low_min)
        custom.addRow("低速配速 秒/公里", self.low_sec)
        self.recovery = QDoubleSpinBox()
        self.recovery.setRange(5, 300)
        self.recovery.setValue(25)
        custom.addRow("低速持续秒数", self.recovery)
        params.addLayout(custom)

        run = QHBoxLayout()
        self.start_button = self._button("开始模拟", self.start_route, run)
        self.start_button.setObjectName("primaryButton")
        self.stop_button = self._button("停止", self.stop_route, run)
        self.stop_button.setEnabled(False)
        side.addLayout(run)
        side.addStretch()
        self.status = QLabel("连接设备后点击刷新。")
        self.status.setObjectName("statusLabel")
        self.status.setWordWrap(True)
        outer.addWidget(self.status)
        notice = QLabel("仅供开发工具研究学习；请勿用于作弊、造假或其他违法用途。使用后请于 24 小时内删除，使用者自行承担不当使用的后果。")
        notice.setObjectName("noticeLabel")
        notice.setWordWrap(True)
        outer.addWidget(notice)

    def _apply_style(self):
        self.setStyleSheet("""
            QWidget { color: #1c2938; font-size: 13px; }
            QMainWindow, QWidget#centralRoot, QWidget#sidebar, QDialog { background: #f5f7fa; }
            QLabel#appTitle { font-size: 25px; font-weight: 700; color: #102d3b; }
            QLabel#appSubtitle { color: #677989; margin-left: 8px; }
            QGroupBox { background: #ffffff; border: 1px solid #dce5eb; border-radius: 16px;
                        margin-top: 12px; padding: 14px 12px 12px; font-weight: 600; }
            QGroupBox::title { subcontrol-origin: margin; left: 15px; padding: 0 5px; color: #31516a; }
            QLineEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox, QListWidget {
                color: #1c2938; background: #ffffff; border: 1px solid #cad6df; border-radius: 10px;
                padding: 5px 7px; selection-background-color: #c8ece8; }
            QLineEdit:disabled, QTextEdit:disabled, QComboBox:disabled,
            QSpinBox:disabled, QDoubleSpinBox:disabled, QListWidget:disabled {
                color: #536675; background: #edf1f4; }
            QComboBox QAbstractItemView { color: #1c2938; background: #ffffff;
                                      selection-color: #075b55; selection-background-color: #d9f1ed; }
            QLineEdit:focus, QTextEdit:focus, QComboBox:focus { border: 1px solid #087f77; }
            QPushButton { color: #173042; background: #ffffff; border: 1px solid #cad6df;
                          border-radius: 12px; padding: 8px 14px; font-weight: 500; }
            QPushButton:hover { background: #e9f5f3; border-color: #78b8ae; }
            QPushButton:pressed { background: #d9f1ed; border-color: #087f77; }
            QPushButton:disabled { color: #536675; background: #edf1f4; border-color: #d9e1e7; }
            QPushButton#primaryButton { background: #087f77; color: white; border-color: #087f77;
                                        font-weight: 600; }
            QPushButton#primaryButton:hover { background: #076e67; }
            QPushButton#primaryButton:disabled { color: #536675; background: #edf1f4;
                                                  border-color: #d9e1e7; }
            QCheckBox:disabled { color: #536675; }
            QScrollArea { border: 0; background: #f5f7fa; }
            QSplitter::handle { background: #dce5eb; }
            QTabWidget::pane { border: 1px solid #dce5eb; border-radius: 10px; }
            QTabBar::tab { color: #31516a; padding: 7px 12px; background: #edf2f5; border-radius: 9px; }
            QTabBar::tab:selected { background: #d9f1ed; color: #075b55; }
            QLabel#statusLabel { background: #e8f2f4; border-radius: 12px; padding: 9px 12px; }
            QLabel#noticeLabel { color: #657582; font-size: 11px; }
        """)

    def _show_research_notice(self):
        QMessageBox.warning(self, "使用须知", RESEARCH_NOTICE, QMessageBox.Ok)
        self.settings["research_notice_acknowledged"] = True
        self._write_json(SETTINGS, self.settings)

    def _task(self, fn, done, busy_text):
        self.status.setText(busy_text)
        task = Task(fn)
        task.signals.result.connect(done)
        task.signals.error.connect(self.status.setText)
        self.pool.start(task)

    def _map_loaded(self, ok):
        self.map_ready = ok
        if ok:
            self.draw_map(True)
        else:
            self.status.setText("地图加载失败：本软件接入境外 OpenStreetMap 地图服务，中国大陆暂不可用。")

    def _js(self, function, *args):
        if self.map_ready:
            self.map.page().runJavaScript(function + "(" + ",".join(json.dumps(a, ensure_ascii=False) for a in args) + ")")

    def draw_map(self, fit=False, preview=None):
        if preview is None:
            preview = closed(self.points)
            if len(preview) >= 2:
                stepper = RouteStepper(preview, self.variation.value(), 42)
                count = min(4000, max(2, int(stepper.total / 4)))
                spacing = max(4, stepper.total / max(1, count - 1))
                path = [preview[0]]
                while not stepper.finished and len(path) < 4000:
                    path.append(stepper.advance(spacing))
                preview = path
        selected = self.selected_place["point"] if self.selected_place else None
        try:
            single = self._single_coordinate()
        except ValueError:
            single = None
        self._js("draw", [asdict(p) for p in self.points], [asdict(p) for p in preview],
                 asdict(single) if single else None, asdict(selected) if selected else None,
                 fit, not self.runner and not self.text_pending)

    def _single_coordinate(self):
        return Coordinate(float(self.latitude.text()), float(self.longitude.text()))

    def map_clicked(self, latitude, longitude):
        if self.runner:
            return
        point = Coordinate(latitude, longitude)
        if self.pick_point.isChecked():
            self.latitude.setText(str(latitude))
            self.longitude.setText(str(longitude))
            self.status.setText("已选择单点；点击“设置定位”应用到设备。")
        elif self.text_pending:
            self.status.setText("请先点击“应用到地图”，再继续添加点。")
            return
        elif len(self.points) < 10_000:
            self.points.append(point)
            self._sync_text()
            self.status.setText(f"已添加第 {len(self.points)} 个路径点。")
        self.draw_map(False)

    def map_point_moved(self, index, latitude, longitude):
        if self.runner or self.text_pending or not 0 <= index < len(self.points):
            self.draw_map(False)
            return
        try:
            self.points[index] = Coordinate(latitude, longitude)
        except ValueError as exc:
            self.status.setText(str(exc))
            self.draw_map(False)
            return
        self._sync_text()
        self.draw_map(False)
        self.status.setText(f"已移动第 {index + 1} 个路径点。")

    def _text_changed(self):
        self.text_pending = True
        self._update_action_state()

    def _sync_text(self):
        self.route_text.blockSignals(True)
        self.route_text.setPlainText("\n".join(f"{p.latitude:.8f},{p.longitude:.8f}" for p in self.points))
        self.route_text.blockSignals(False)
        self.text_pending = False
        self._update_action_state()

    def apply_text(self):
        try:
            self.points = parse_points(self.route_text.toPlainText())
            self.text_pending = False
            self._update_action_state()
            self.draw_map(True)
            self.status.setText(f"已应用 {len(self.points)} 个路径点。")
        except ValueError as exc:
            self.status.setText(str(exc))

    def undo_point(self):
        if not self.runner and self.points:
            self.points.pop()
            self._sync_text()
            self.draw_map(True)

    def clear_route(self):
        if not self.runner:
            self.points = []
            self._sync_text()
            self.draw_map(False)

    def make_track(self):
        try:
            points = parse_points(self.route_text.toPlainText()) if self.text_pending else self.points
            if len(points) != 2:
                raise ValueError("生成跑道需要恰好两个端点。")
            self.points = generate_track(points[0], points[1], self.track_side.currentData())
            self._sync_text()
            self.draw_map(True)
            self.status.setText("已生成约 400 米环形跑道。")
        except ValueError as exc:
            self.status.setText(str(exc))

    def _sync_speed(self):
        try:
            speed = pace_to_speed(self.pace_min.value(), self.pace_sec.value())
            self.speed.blockSignals(True)
            self.speed.setValue(speed)
            self.speed.blockSignals(False)
        except ValueError:
            pass

    def _sync_pace(self):
        minutes, seconds = speed_to_pace(self.speed.value())
        for widget, value in ((self.pace_min, minutes), (self.pace_sec, seconds)):
            widget.blockSignals(True)
            widget.setValue(value)
            widget.blockSignals(False)

    def _configuration(self):
        if self.text_pending:
            raise ValueError("坐标文本有未应用的修改，请先点击“应用到地图”。")
        plan = DynamicPlan(self.dynamic_mode.currentData(), self.preset.currentData(),
                           self.interval.value(), self.low_min.value() * 60 + self.low_sec.value(),
                           self.recovery.value())
        config = Configuration(self.name.text(), self._single_coordinate(), self.points[:],
                               self.speed.value(), self.jitter.value(), self.passes.value(),
                               self.variation.value(), self.dynamic.isChecked(), plan)
        config.validate()
        return config

    def save_config(self):
        try:
            config = self._configuration()
            path, _ = QFileDialog.getSaveFileName(self, "保存配置", config.name + ".json", "JSON (*.json)")
            if path:
                Path(path).write_text(config.to_json(), encoding="utf-8")
                self.status.setText("配置已保存：" + path)
        except (ValueError, OSError) as exc:
            self.status.setText(str(exc))

    def import_config(self):
        path, _ = QFileDialog.getOpenFileName(self, "导入配置", "", "JSON (*.json)")
        if not path:
            return
        try:
            config = Configuration.from_json(Path(path).read_text(encoding="utf-8"))
            self._apply_config(config)
            self.status.setText("配置已导入：" + path)
        except (ValueError, OSError, KeyError, TypeError) as exc:
            self.status.setText("导入失败：" + str(exc))

    def _apply_config(self, c):
        self.name.setText(c.name)
        self.latitude.setText(str(c.point.latitude))
        self.longitude.setText(str(c.point.longitude))
        self.points = c.route[:]
        self._sync_text()
        self.speed.setValue(c.speedMetersPerSecond)
        self.jitter.setValue(c.jitterPercent)
        self.passes.setValue(c.passes)
        self.variation.setValue(c.pathVariationMeters)
        self.dynamic.setChecked(c.dynamicSpeed)
        self.dynamic_mode.setCurrentIndex(self.dynamic_mode.findData(c.dynamicSpeedPlan.mode))
        self.preset.setCurrentIndex(self.preset.findData(c.dynamicSpeedPlan.preset))
        self.interval.setValue(c.dynamicSpeedPlan.intervalKilometers)
        minutes, seconds = divmod(c.dynamicSpeedPlan.lowPaceSeconds, 60)
        self.low_min.setValue(minutes)
        self.low_sec.setValue(seconds)
        self.recovery.setValue(c.dynamicSpeedPlan.recoverySeconds)
        self.draw_map(True)

    def refresh_devices(self):
        if self.runner or self._device_busy:
            return
        def discover():
            found, errors = [], []
            harmony_attached = False
            for kind, lookup in (("ios", connected_devices), ("android", connected_android_devices),
                                 ("harmony", connected_harmony_devices)):
                try:
                    if kind == "harmony":
                        if not configure_hdc():
                            harmony_attached = harmony_usb_connected()
                            if harmony_attached:
                                errors.append("已接入华为 USB 设备，但未找到 hdc。")
                            continue
                    found.extend((kind, identifier) for identifier in lookup())
                except RuntimeError as exc:
                    errors.append(str(exc))
            return found, errors, harmony_attached
        self._task(discover, self._set_devices, "正在查找 iPhone、Android 和 HarmonyOS 设备…")

    def _set_devices(self, result):
        devices, errors, harmony_attached = result
        previous = self.device_combo.currentData()
        self.device_combo.clear()
        for kind, identifier in devices:
            label = ("iOS 设备 · " + identifier[-8:] if kind == "ios"
                     else "HarmonyOS 设备 · " + identifier if kind == "harmony"
                     else "Android 设备 · " + identifier)
            self.device_combo.addItem(label, (kind, identifier))
        index = self.device_combo.findData(previous)
        if index >= 0:
            self.device_combo.setCurrentIndex(index)
        self._update_action_state()
        self.status.setText((f"找到 {len(devices)} 台设备。" if devices else "未找到设备。")
                            + (" " + "；".join(errors) if errors and not devices else ""))
        if harmony_attached:
            answer = QMessageBox.question(
                self, "安装 HarmonyOS 设备工具",
                "未检测到 HarmonyOS SDK/hdc。是否打开华为官方 Command Line Tools 下载与安装说明？\n\n"
                "安装或解压后再次点击“刷新”，程序会自动查找常见 SDK 目录并配置当前运行环境。",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.Yes)
            if answer == QMessageBox.Yes:
                QDesktopServices.openUrl(QUrl(
                    "https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get"))

    def check_ios_drivers(self):
        self._task(probe_ios_drivers, self._show_driver_diagnosis, "正在检查 iOS 驱动…")

    def _show_driver_diagnosis(self, report: DriverReport):
        self.driver_guide.setText(report.guide_html())
        self.driver_guide.show()
        self.repair_button.setVisible(report.windows and any(
            item in report.missing for item in
            ("Apple Mobile Device Service", "Apple Mobile Device USB Driver")))
        self.status.setText(report.summary())

    def repair_ios_drivers(self):
        self.repair_button.setEnabled(False)
        def finished(message):
            self.repair_button.setEnabled(True)
            self.status.setText(message)
            self.check_ios_drivers()
        def failed(message):
            self.repair_button.setEnabled(True)
            self.status.setText(message)
        task = Task(install_apple_devices)
        task.signals.result.connect(finished)
        task.signals.error.connect(failed)
        self.status.setText("正在安装 Apple Devices 所需设备组件…")
        self.pool.start(task)

    def _target(self):
        target = self.device_combo.currentData()
        if not target:
            raise ValueError("请先连接并选择设备。")
        kind, identifier = target
        backend = {"ios": self.ios_session, "android": self.android_bridge,
                   "harmony": self.harmony_bridge}[kind]
        return backend, identifier

    def set_point(self):
        if self.runner or self._device_busy:
            return
        try:
            backend, identifier = self._target()
            point = self._single_coordinate()
            self._device_task(lambda: backend.set(identifier, point),
                              lambda _: self.status.setText(f"已设置定位：{point.latitude:.8f},{point.longitude:.8f}"),
                              "正在设置定位…")
        except ValueError as exc:
            self.status.setText(str(exc))

    def clear_location(self):
        if self.runner or self._device_busy:
            return
        try:
            backend, identifier = self._target()
            self._device_task(lambda: backend.clear(identifier),
                              lambda _: self.status.setText("已清除模拟定位。"), "正在清除定位…")
        except ValueError as exc:
            self.status.setText(str(exc))

    def start_route(self):
        if self.runner or self._device_busy:
            return
        try:
            backend, identifier = self._target()
            config = self._configuration()
            if len(config.route) < 2:
                raise ValueError("路径至少需要两个坐标点。")
            self.runner = RouteRunner(backend, identifier, config)
            self.runner.signals.status.connect(self.status.setText)
            self.runner.signals.point.connect(lambda _: None)
            self.runner.signals.preview.connect(self._route_preview)
            self.runner.signals.finished.connect(self._route_finished)
            self._set_running(True)
            self.pool.start(self.runner)
        except ValueError as exc:
            self.status.setText(str(exc))

    def _route_preview(self, data):
        points, seed = data
        stepper = RouteStepper(points, self.variation.value(), seed)
        spacing = max(4, stepper.total / 3999)
        preview = [points[0]]
        while not stepper.finished and len(preview) < 4000:
            preview.append(stepper.advance(spacing))
        self.draw_map(False, preview)

    def _route_finished(self):
        self.runner = None
        self._set_running(False)
        self.draw_map(False)

    def _set_running(self, running):
        for group in self.groups:
            group.setEnabled(not running)
        self._update_action_state()
        self.draw_map(False)

    def _update_action_state(self):
        editing = self.runner is None
        idle = editing and not self._device_busy
        has_device = self.device_combo.currentData() is not None
        has_place = self.selected_place is not None
        self.device_combo.setEnabled(idle)
        self.set_button.setEnabled(idle and has_device)
        self.clear_button.setEnabled(idle and has_device)
        self.start_button.setEnabled(idle and has_device)
        self.stop_button.setEnabled(not editing and not self.runner.stop_event.is_set())
        self.refresh_button.setEnabled(idle)
        self.import_button.setEnabled(editing)
        self.save_button.setEnabled(editing)
        self.place_point_button.setEnabled(editing and has_place)
        self.place_route_button.setEnabled(editing and has_place and not self.text_pending
                                           and len(self.points) < 10_000)
        self.undo_button.setEnabled(editing and not self.text_pending and bool(self.points))
        self.clear_route_button.setEnabled(editing and not self.text_pending and bool(self.points))
        self.apply_button.setEnabled(editing and self.text_pending)
        self.track_button.setEnabled(editing)

    def _device_task(self, fn, done, busy_text):
        self._device_busy = True
        self._update_action_state()

        def finished(result):
            self._device_busy = False
            self._update_action_state()
            done(result)

        def failed(message):
            self._device_busy = False
            self._update_action_state()
            self.status.setText(message)

        task = Task(fn)
        task.signals.result.connect(finished)
        task.signals.error.connect(failed)
        self.status.setText(busy_text)
        self.pool.start(task)

    def stop_route(self):
        if self.runner:
            self.runner.stop_event.set()
            self._update_action_state()
            self.status.setText("正在停止…")

    def search(self):
        query = self.search_input.text().strip()
        if not query:
            self.status.setText("请输入地点或学校名称。")
            return
        history = self.settings.setdefault("history", [])
        history[:] = [query] + [item for item in history if item.casefold() != query.casefold()][:11]
        self._write_json(SETTINGS, self.settings)
        self._task(lambda: search_places(query), self._search_done, "正在搜索地点…")

    def _search_done(self, places):
        self.places = places
        self.results.clear()
        for place in places:
            self.results.addItem(place["name"] + " · " + place["subtitle"][:70])
        if places:
            self.results.setCurrentRow(0)
        self.status.setText(f"找到 {len(places)} 个地点。" if places else "没有找到匹配地点。")

    def select_place(self, index):
        self.selected_place = self.places[index] if 0 <= index < len(self.places) else None
        self._update_action_state()
        self.draw_map(False)
        if self.selected_place:
            point = self.selected_place["point"]
            self._js("focus", point.latitude, point.longitude)
            if self.selected_place["school"]:
                self._task(lambda: nearby_sports(point), self._sports_done, "正在搜索学校附近运动场地…")

    def _sports_done(self, grounds):
        existing = {(p["name"], p["point"]) for p in self.places}
        for place in grounds:
            if (place["name"], place["point"]) not in existing:
                self.places.append(place)
                self.results.addItem(place["name"] + " · " + place["subtitle"])
        self.status.setText(f"找到 {len(grounds)} 处附近运动场地。")

    def place_as_point(self):
        if self.selected_place:
            point = self.selected_place["point"]
            self.latitude.setText(str(point.latitude))
            self.longitude.setText(str(point.longitude))
            self.draw_map(False)

    def place_to_route(self):
        if self.selected_place and len(self.points) < 10_000 and not self.text_pending:
            self.points.append(self.selected_place["point"])
            self._sync_text()
            self.draw_map(True)

    def show_history(self):
        dialog = QDialog(self)
        dialog.setWindowTitle("搜索历史")
        layout = QVBoxLayout(dialog)
        listing = QListWidget()
        listing.addItems(self.settings.get("history", []))
        listing.itemDoubleClicked.connect(lambda item: (self.search_input.setText(item.text()), dialog.accept(), self.search()))
        layout.addWidget(listing)
        self._button("清除历史", lambda: (self.settings.update(history=[]), self._write_json(SETTINGS, self.settings), listing.clear()), layout)
        dialog.exec()

    def show_settings(self):
        dialog = QDialog(self)
        self.settings_dialog = dialog
        dialog.setWindowTitle("设置")
        layout = QVBoxLayout(dialog)
        restore = QCheckBox("启动时恢复上次路线")
        restore.setChecked(self.settings.get("restore", True))
        auto = QCheckBox("启动时自动刷新设备")
        auto.setChecked(self.settings.get("auto_refresh", True))
        layout.addWidget(restore)
        layout.addWidget(auto)
        self._button("检查更新", lambda: self.check_for_updates(manual=True), layout)
        self._button("清除搜索历史", lambda: self.settings.update(history=[]), layout)
        self._button("清除路线记忆", self._clear_draft, layout)
        self._button("完成", dialog.accept, layout)
        dialog.exec()
        self.settings_dialog = None
        self.settings.update(restore=restore.isChecked(), auto_refresh=auto.isChecked())
        self._write_json(SETTINGS, self.settings)

    def check_for_updates(self, manual=False):
        if getattr(self, "_update_check_running", False):
            return
        self._update_check_running = True
        task = Task(check_update)
        task.signals.result.connect(lambda result: self._update_checked(result, manual))
        task.signals.error.connect(self._update_check_failed)
        if manual:
            self.status.setText("正在检查更新…")
        self.pool.start(task)

    def _update_checked(self, result: UpdateResult, manual: bool):
        self._update_check_running = False
        if result.required:
            if getattr(self, "settings_dialog", None):
                self.settings_dialog.accept()
            if self.runner:
                self.stop_route()
            self.centralWidget().setEnabled(False)
            self.update_dialog = UpdateRequiredDialog(self, result)
            self.update_dialog.exec()
        elif manual:
            if result.error:
                QMessageBox.information(self, "检查更新", f"无法连接 GitHub：{result.error}")
            else:
                QMessageBox.information(self, "检查更新", f"当前已是最新版本（{result.current}）。")

    def _update_check_failed(self, message):
        self._update_check_running = False
        self.status.setText(f"检查更新失败：{message}")

    def _clear_draft(self):
        self._cleared_draft_snapshot = self._draft_data()
        DRAFT.unlink(missing_ok=True)

    def _draft_data(self):
        return {"name": self.name.text(), "latitude": self.latitude.text(),
                    "longitude": self.longitude.text(), "points": [asdict(p) for p in self.points],
                    "routeText": self.route_text.toPlainText(), "textPending": self.text_pending,
                    "speed": self.speed.value(), "jitter": self.jitter.value(),
                    "passes": self.passes.value(), "pathVariation": self.variation.value(),
                    "dynamicSpeed": self.dynamic.isChecked(), "dynamicMode": self.dynamic_mode.currentData(),
                    "dynamicPreset": self.preset.currentData(), "interval": self.interval.value(),
                    "lowMinutes": self.low_min.value(), "lowSeconds": self.low_sec.value(),
                    "recovery": self.recovery.value(), "editorMode": self.editor_tabs.currentIndex()}

    def _save_draft(self):
        try:
            data = self._draft_data()
            if data == self._cleared_draft_snapshot:
                return
            self._cleared_draft_snapshot = None
            self._write_json(DRAFT, data)
        except OSError:
            pass

    def _load_draft(self):
        if not self.settings.get("restore", True):
            return
        data = self._read_json(DRAFT, {})
        if not data:
            return
        try:
            self.name.setText(data["name"])
            self.latitude.setText(data["latitude"])
            self.longitude.setText(data["longitude"])
            self.points = [Coordinate(**point) for point in data["points"]][:10000]
            self._sync_text()
            if data.get("textPending"):
                self.route_text.setPlainText(data["routeText"][:1_000_000])
                self.text_pending = True
            self.speed.setValue(data["speed"])
            self.jitter.setValue(data["jitter"])
            self.passes.setValue(data["passes"])
            self.variation.setValue(data["pathVariation"])
            self.dynamic.setChecked(data["dynamicSpeed"])
            self.dynamic_mode.setCurrentIndex(max(0, self.dynamic_mode.findData(data["dynamicMode"])))
            self.preset.setCurrentIndex(max(0, self.preset.findData(data["dynamicPreset"])))
            self.interval.setValue(data["interval"])
            self.low_min.setValue(data["lowMinutes"])
            self.low_sec.setValue(data["lowSeconds"])
            self.recovery.setValue(data["recovery"])
            self.editor_tabs.setCurrentIndex(data["editorMode"])
        except (KeyError, TypeError, ValueError):
            pass

    def closeEvent(self, event):
        if self.runner:
            self.runner.stop_event.set()
            self.status.setText("正在停止路线并清除定位…")
        # Finish in-flight set/clear operations before clearing active mock providers.
        if not self.pool.waitForDone(5000):
            event.ignore()
            QMessageBox.information(self, "请稍候", "设备定位操作仍在进行，请稍后再关闭。")
            return
        self._save_draft()
        self.ios_session.close()
        self.android_bridge.close()
        self.harmony_bridge.close()
        event.accept()


def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())

