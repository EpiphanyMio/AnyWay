"""Windows desktop UI. Run with `python -m anyway.app`."""
from __future__ import annotations

from dataclasses import asdict
import ctypes
import json
from pathlib import Path
import random
import sys
import threading
import time

from PySide6.QtCore import QEvent, QObject, QRunnable, Qt, QThreadPool, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QPalette, QTextDocument
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDialog, QDoubleSpinBox,
    QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget, QMenu, QToolButton,
    QMainWindow, QMessageBox, QPushButton, QScrollArea, QSpinBox, QSplitter,
    QTabWidget, QTextEdit, QVBoxLayout, QWidget)
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEngineSettings
from PySide6.QtWebEngineWidgets import QWebEngineView

from .core import (Configuration, Coordinate, DynamicPlan, LiveRoute, RouteStepper,
                   closed, generate_track, pace_to_speed, parse_points, route_length, speed_to_pace)
from .ios import PhoneSession, check_ip, connected_devices_with_status, prepare_wireless
from .place_search import USER_AGENT, nearby_sports, search_places
from .release_notes import load as load_release_notes
from .update_check import UpdateResult, check_update, current_version
from .android import AndroidBridge, connected_devices as connected_android_devices
from .driver_check import (DriverReport, install_apple_devices,
                           probe as probe_ios_drivers)
from .harmony import (HarmonyBridge, configure_hdc,
                      connected_devices as connected_harmony_devices,
                      harmony_usb_connected)
from .user_data import APP_DIR, DRAFT, SETTINGS, migrate_legacy_data, recent_ip_connections, remember_ip

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001

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


class UpdateSettings(QWidget):
    def __init__(self, current, check, ignore):
        super().__init__()
        self.result = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        current_row = QHBoxLayout()
        current_row.addWidget(QLabel(f"当前版本：{current}"), 1)
        self.check_button = QPushButton("检查更新")
        self.check_button.clicked.connect(check)
        current_row.addWidget(self.check_button)
        layout.addLayout(current_row)

        self.latest_row = QWidget()
        latest_layout = QHBoxLayout(self.latest_row)
        latest_layout.setContentsMargins(0, 0, 0, 0)
        self.toggle = QToolButton()
        self.toggle.setCheckable(True)
        self.toggle.setAutoRaise(True)
        self.toggle.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.toggle.toggled.connect(self._expand)
        latest_layout.addWidget(self.toggle)
        latest_layout.addStretch()
        self.ignore_button = QPushButton("忽略本次更新")
        self.ignore_button.clicked.connect(lambda: ignore(self.result))
        latest_layout.addWidget(self.ignore_button)
        layout.addWidget(self.latest_row)

        self.details = QWidget()
        details_layout = QVBoxLayout(self.details)
        details_layout.setContentsMargins(0, 0, 0, 0)
        self.notes = QTextEdit()
        self.notes.setReadOnly(True)
        self.notes.setFixedHeight(150)
        details_layout.addWidget(self.notes)
        download = QPushButton("打开新版下载页")
        download.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(self.result.release_url)))
        details_layout.addWidget(download, alignment=Qt.AlignmentFlag.AlignLeft)
        layout.addWidget(self.details)
        self.latest_row.hide()
        self._expand(False)

    def _expand(self, expanded):
        self.toggle.setArrowType(Qt.ArrowType.DownArrow if expanded else Qt.ArrowType.RightArrow)
        self.details.setVisible(expanded and self.result is not None and self.result.available)

    def render(self, result, ignored_through, checking):
        previous = self.result
        self.result = result
        self.check_button.setEnabled(not checking)
        self.check_button.setText("正在检查…" if checking else "检查更新")
        available = bool(result and result.available)
        self.latest_row.setVisible(available)
        if available:
            if previous is None or previous.latest != result.latest:
                self.toggle.setChecked(False)
            self.toggle.setText(f"最新版本：{result.latest}")
            can_ignore = result.should_prompt(ignored_through)
            self.ignore_button.setEnabled(can_ignore)
            self.ignore_button.setText("忽略本次更新" if can_ignore else "已忽略此版本")
            if result.notes:
                self.notes.document().setMarkdown(
                    result.notes, QTextDocument.MarkdownFeature.MarkdownNoHTML)
            else:
                self.notes.setPlainText("发布页暂无更新说明。")
        self._expand(self.toggle.isChecked())


class _ClickToWheelSpinBox:
    """Let the sidebar scroll until the user clicks this particular spin box."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._wheel_enabled = False
        self._editor = self.findChild(QLineEdit)
        self._editor.installEventFilter(self)

    def eventFilter(self, watched, event):
        if watched is self._editor:
            if event.type() == QEvent.Type.MouseButtonPress and event.button() == Qt.MouseButton.LeftButton:
                self._wheel_enabled = True
            elif event.type() == QEvent.Type.FocusOut:
                self._wheel_enabled = False
        return super().eventFilter(watched, event)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._wheel_enabled = True
        super().mousePressEvent(event)

    def focusOutEvent(self, event):
        self._wheel_enabled = False
        super().focusOutEvent(event)

    def wheelEvent(self, event):
        if self._wheel_enabled and self.hasFocus():
            super().wheelEvent(event)
        else:
            event.ignore()


class ClickToWheelSpinBox(_ClickToWheelSpinBox, QSpinBox):
    pass


class ClickToWheelDoubleSpinBox(_ClickToWheelSpinBox, QDoubleSpinBox):
    pass


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
    preview = Signal(object, object)
    finished = Signal(object, str)


class RouteRunner(QRunnable):
    def __init__(self, session, target, config, seed, index, count):
        super().__init__()
        self.session, self.target = session, target
        self._configuration = config
        self._lock = threading.Lock()
        self.route = LiveRoute(config, seed, index, count)
        self.stop_event = threading.Event()
        self.signals = RouteSignals()

    def update(self, config):
        with self._lock:
            self._configuration = config

    def _update_route(self):
        with self._lock:
            self.route.update(self._configuration)

    def run(self):
        route = self.route
        tick = 1 if self.target[0] == "harmony" else .5
        error = ""
        execution_state = None
        previous_state = 0
        controls_awake = getattr(self.session, "set_keep_awake", None)
        wake_available = False
        wake_attempted = False
        try:
            if self.stop_event.is_set():
                return
            if sys.platform == "win32":
                execution_state = ctypes.windll.kernel32.SetThreadExecutionState
                execution_state.argtypes = [ctypes.c_uint32]
                execution_state.restype = ctypes.c_uint32
                # Continuous and system required. Each worker owns its own request.
                previous_state = execution_state(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
            self.session.set(self.target[1], route.point)
            if controls_awake and not self.stop_event.is_set():
                wake_attempted = True
                wake_available = self._request_awake(controls_awake, True)
            supports_wake = wake_available
            last = time.monotonic()
            next_wake_renewal = last + 15
            previous_status = ""
            while not self.stop_event.is_set() and not route.finished:
                self._update_route()
                if route.finished:
                    break
                if route.preview_changed:
                    self.signals.preview.emit(self.target, route.preview())
                recovery = " · 低速段" if route.motion.recovery_left else ""
                wake_status = "" if wake_available else " · 设备端防休眠不可用"
                status = f"{self.target[1][-8:]} · 第 {route.lap + 1}/{route.config.passes} 圈{recovery}{wake_status}"
                if status != previous_status:
                    self.signals.status.emit(status)
                    previous_status = status
                if self.stop_event.wait(max(0, tick - (time.monotonic() - last))):
                    break
                if supports_wake and time.monotonic() >= next_wake_renewal:
                    wake_available = self._request_awake(controls_awake, True)
                    next_wake_renewal = time.monotonic() + (15 if wake_available else 4)
                if self.stop_event.is_set():
                    break
                now = time.monotonic()
                self._update_route()
                if route.finished:
                    break
                self.session.set(self.target[1], route.advance(now - last))
                last = now
        except Exception as exc:
            error = f"{self.target[1][-8:]} · {exc}"
        finally:
            if wake_attempted:
                self._request_awake(controls_awake, False)
            if previous_state:
                execution_state(previous_state | ES_CONTINUOUS)
            self.signals.finished.emit(self.target, error)

    def _request_awake(self, control, enabled):
        try:
            control(self.target[1], enabled)
            return True
        except (OSError, RuntimeError, ValueError):
            return False


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AnyWay · Windows")
        available = QApplication.primaryScreen().availableGeometry()
        self.resize(min(1250, available.width()), min(820, available.height()))
        self.pool = QThreadPool.globalInstance()
        self.direct_iphone_addresses = {}
        self.ios_sessions = {}
        self.android_bridge = AndroidBridge()
        self.harmony_bridge = HarmonyBridge()
        self.runners = {}
        self._run_errors = []
        self._stopping = False
        self._previews = {}
        self._refreshing = False
        self._usb_iphones = set()
        self._update_result = None
        self._update_check_running = False
        self._manual_update_check = False
        self.update_settings = None
        self._route_scope = None
        self._loading_draft = False
        self._shared_draft = None
        self._device_drafts = {}
        self._editor_baseline = None
        self._last_live_draft = None
        self._device_busy = False
        self.points = []
        self.places = []
        self.selected_place = None
        self.text_pending = False
        self._cleared_draft_snapshot = None
        self.map_ready = False
        self.settings = self._read_json(SETTINGS, {"restore": True, "auto_refresh": True, "history": []})
        self.recent_ips = recent_ip_connections(self.settings)
        self.device_aliases = self.settings.setdefault("device_aliases", {})
        self._build_ui()
        self._apply_style()
        QApplication.styleHints().colorSchemeChanged.connect(self._system_theme_changed)
        self._load_draft()
        self._update_action_state()
        self.live_timer = QTimer(self)
        self.live_timer.timeout.connect(self._update_live_route)
        self.live_timer.setInterval(250)
        self.draft_timer = QTimer(self)
        self.draft_timer.timeout.connect(self._save_draft)
        self.draft_timer.start(2000)
        QTimer.singleShot(0, self._show_startup_notices)

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
        self._button("设置", lambda: self.show_settings(), toolbar)
        self.import_button = self._button("导入配置", self.import_config, toolbar)
        self.save_button = self._button("保存配置", self.save_config, toolbar)
        outer.addLayout(toolbar)
        self.update_banner = QWidget()
        banner = QHBoxLayout(self.update_banner)
        banner.setContentsMargins(10, 2, 10, 2)
        self.update_banner.setObjectName("updateBanner")
        self.update_banner_text = QLabel()
        banner.addWidget(self.update_banner_text, 1)
        self._button("查看更新", self._show_update_details, banner)
        self._button("稍后", self.update_banner.hide, banner)
        self.update_banner.hide()
        outer.addWidget(self.update_banner)
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

        self._build_device_panel(side)

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
        self.route_editor = QComboBox()
        self.route_editor.addItem("共用配置")
        self.route_editor.currentIndexChanged.connect(self._switch_route_editor)
        route.addWidget(QLabel("编辑路线"))
        route.addWidget(self.route_editor)
        self.restore_shared_button = self._button("恢复使用共用配置", self._restore_shared_route, route)
        self.restore_shared_button.hide()
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
        self.speed = ClickToWheelDoubleSpinBox()
        self.speed.setRange(.01, 100)
        self.speed.setDecimals(3)
        self.speed.setValue(5)
        self.speed.valueChanged.connect(self._sync_pace)
        form.addRow("速度 m/s", self.speed)
        self.pace_min, self.pace_sec = ClickToWheelSpinBox(), ClickToWheelSpinBox()
        self.pace_min.setRange(0, 999)
        self.pace_sec.setRange(0, 59)
        self.pace_min.setValue(3)
        self.pace_sec.setValue(20)
        self.pace_min.valueChanged.connect(self._sync_speed)
        self.pace_sec.valueChanged.connect(self._sync_speed)
        form.addRow("配速 分/公里", self.pace_min)
        form.addRow("配速 秒/公里", self.pace_sec)
        self.jitter = ClickToWheelDoubleSpinBox()
        self.jitter.setRange(0, 100)
        self.jitter.setValue(15)
        form.addRow("速度抖动 ±%", self.jitter)
        self.passes = ClickToWheelSpinBox()
        self.passes.setRange(1, 1000)
        self.passes.setValue(2)
        form.addRow("圈数", self.passes)
        self.variation = ClickToWheelDoubleSpinBox()
        self.variation.setRange(0, 20)
        self.variation.setValue(2)
        self.variation.valueChanged.connect(lambda: self.draw_map(False))
        form.addRow("路线偏移上限 m", self.variation)
        self.variation.setToolTip("偏移设为 0 时使用 0.5 米上限，短路线按比例缩小。")
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
        self.interval = ClickToWheelDoubleSpinBox()
        self.interval.setRange(.1, 20)
        self.interval.setValue(.8)
        custom.addRow("低速间隔 km", self.interval)
        self.low_min, self.low_sec = ClickToWheelSpinBox(), ClickToWheelSpinBox()
        self.low_min.setRange(1, 60)
        self.low_min.setValue(10)
        self.low_sec.setRange(0, 59)
        custom.addRow("低速配速 分/公里", self.low_min)
        custom.addRow("低速配速 秒/公里", self.low_sec)
        self.recovery = ClickToWheelDoubleSpinBox()
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
        for widget in (self.speed, self.jitter, self.passes, self.variation, self.interval,
                       self.low_min, self.low_sec, self.recovery, self.pace_min, self.pace_sec):
            widget.valueChanged.connect(self._store_current_device_draft)
        for widget in (self.dynamic_mode, self.preset):
            widget.currentIndexChanged.connect(self._store_current_device_draft)
        self.editor_tabs.currentChanged.connect(self._store_current_device_draft)
        self.dynamic.toggled.connect(self._store_current_device_draft)
        for widget in (self.name, self.latitude, self.longitude):
            widget.textChanged.connect(self._store_current_device_draft)
        self.route_text.textChanged.connect(self._store_current_device_draft)
        notice = QLabel("仅供开发工具研究学习；请勿用于作弊、造假或其他违法用途。使用后请于 24 小时内删除，使用者自行承担不当使用的后果。")
        notice.setObjectName("noticeLabel")
        notice.setWordWrap(True)
        outer.addWidget(notice)

    def _build_device_panel(self, side):
        devices = self._box("目标设备", side)
        self.device_combo = QComboBox()
        self.device_combo.setPlaceholderText("没有可用设备")
        self.device_combo.currentIndexChanged.connect(lambda _index: self._update_action_state())
        target_row = QHBoxLayout()
        target_row.addWidget(self.device_combo, 1)
        self.rename_device_button = self._button("设备命名", self.rename_device, target_row)
        devices.addLayout(target_row)

        actions = QHBoxLayout()
        self.route_targets = QToolButton()
        self.route_targets.setText("选择模拟设备")
        self.route_targets.setMinimumWidth(132)
        self.route_targets.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.route_targets.setMenu(QMenu(self.route_targets))
        actions.addWidget(self.route_targets)
        actions.addStretch()
        self.refresh_button = self._button("刷新设备", self.refresh_devices, actions)
        devices.addLayout(actions)

        wireless = self._box("iPhone 无线连接", side)
        ip_row = QHBoxLayout()
        self.iphone_ip = QLineEdit(self.recent_ips[0]["address"] if self.recent_ips else "")
        self.iphone_ip.setPlaceholderText("iPhone IPv4 地址")
        ip_row.addWidget(self.iphone_ip, 1)
        self.ip_button = self._button("通过 IP 连接", self.connect_ios_ip, ip_row)
        self.ip_button.setObjectName("primaryButton")
        wireless.addLayout(ip_row)
        self.recent_label = QLabel("最近使用")
        wireless.addWidget(self.recent_label)
        self.recent_combo = QComboBox()
        self.recent_combo.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        wireless.addWidget(self.recent_combo)
        recent_row = QHBoxLayout()
        self.reconnect_button = self._button("重新连接", self.reconnect_recent_ip, recent_row)
        self.rename_recent_device_button = self._button("设备命名", self.rename_recent_device, recent_row)
        self.rename_ip_button = self._button("网络命名", self.rename_recent_ip, recent_row)
        wireless.addLayout(recent_row)
        self._show_recent_ips()

        setup = QWidget()
        setup_layout = QVBoxLayout(setup)
        setup_layout.setContentsMargins(8, 0, 0, 0)
        hint = QLabel("用 USB 连接并选中 iPhone，再开启无线连接。")
        hint.setWordWrap(True)
        setup_layout.addWidget(hint)
        setup_actions = QHBoxLayout()
        self.wireless_button = self._button("开启无线连接", self.prepare_ios_wireless, setup_actions)
        self._button("检查 iOS 驱动", self.check_ios_drivers, setup_actions)
        setup_layout.addLayout(setup_actions)
        self.driver_guide = QLabel()
        self.driver_guide.setTextFormat(Qt.RichText)
        self.driver_guide.setOpenExternalLinks(True)
        self.driver_guide.setWordWrap(True)
        self.driver_guide.hide()
        setup_layout.addWidget(self.driver_guide)
        self.repair_button = self._button("一键补全 iOS 驱动", self.repair_ios_drivers, setup_layout)
        self.repair_button.hide()

        disclosure = QToolButton()
        disclosure.setText("首次无线配对")
        disclosure.setCheckable(True)
        disclosure.setAutoRaise(True)
        disclosure.setArrowType(Qt.ArrowType.RightArrow)
        disclosure.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        disclosure.toggled.connect(setup.setVisible)
        disclosure.toggled.connect(lambda open_: disclosure.setArrowType(
            Qt.ArrowType.DownArrow if open_ else Qt.ArrowType.RightArrow))
        wireless.addWidget(disclosure, alignment=Qt.AlignmentFlag.AlignLeft)
        wireless.addWidget(setup)
        setup.hide()

    def _apply_style(self):
        mode = self.settings.get("appearance", "system")
        dark = mode == "dark" or (mode == "system" and
                QApplication.styleHints().colorScheme() == Qt.ColorScheme.Dark)
        palette = QPalette()
        for role, light_color, dark_color in (
            (QPalette.ColorRole.Window, "#f5f7fa", "#151b24"),
            (QPalette.ColorRole.WindowText, "#1c2938", "#e3eaf0"),
            (QPalette.ColorRole.Base, "#ffffff", "#242d39"),
            (QPalette.ColorRole.AlternateBase, "#edf2f5", "#303d49"),
            (QPalette.ColorRole.Text, "#1c2938", "#e3eaf0"),
            (QPalette.ColorRole.Button, "#ffffff", "#303d49"),
            (QPalette.ColorRole.ButtonText, "#1c2938", "#e3eaf0"),
            (QPalette.ColorRole.Highlight, "#087f77", "#087f77"),
            (QPalette.ColorRole.HighlightedText, "#ffffff", "#ffffff"),
        ):
            palette.setColor(role, QColor(dark_color if dark else light_color))
        self.setPalette(palette)
        sheet = """
            QWidget { color: #1c2938; font-size: 13px; }
            QMainWindow, QWidget#centralRoot, QWidget#sidebar, QDialog { background: #f5f7fa; }
            QWidget#updateBanner { background: #e9f5f3; border-radius: 9px; }
            QLabel#appTitle { font-size: 25px; font-weight: 700; color: #102d3b; }
            QLabel#appSubtitle { color: #677989; margin-left: 8px; }
            QGroupBox { background: #ffffff; border: 1px solid #dce5eb; border-radius: 16px;
                        margin-top: 12px; padding: 14px 12px 12px; font-weight: 600; }
            QGroupBox::title { subcontrol-origin: margin; left: 15px; padding: 0 5px; color: #31516a; }
            QLineEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox, QListWidget {
                color: #1c2938; background: #ffffff; border: 1px solid #cad6df; border-radius: 10px;
                padding: 5px 7px; selection-background-color: #c8ece8; }
            QComboBox { padding-right: 34px; }
            QComboBox::drop-down { subcontrol-origin: padding; subcontrol-position: top right;
                                   width: 30px; border: 0; border-left: 1px solid #cad6df;
                                   border-top-right-radius: 9px; border-bottom-right-radius: 9px;
                                   background: #f2f6f8; }
            QComboBox::drop-down:hover { background: #e9f5f3; }
            QComboBox::drop-down:disabled { background: #edf1f4; }
            QComboBox::down-arrow { image: url("__COMBO_ARROW__"); width: 12px; height: 8px; }
            QComboBox::down-arrow:disabled { image: url("__DISABLED_DOWN_ARROW__"); }
            QSpinBox, QDoubleSpinBox { padding-right: 34px; }
            QSpinBox::up-button, QDoubleSpinBox::up-button {
                subcontrol-origin: padding; subcontrol-position: top right;
                width: 30px; height: 15px; border: 0; border-left: 1px solid #cad6df;
                border-top-right-radius: 9px; background: #f2f6f8; }
            QSpinBox::down-button, QDoubleSpinBox::down-button {
                subcontrol-origin: padding; subcontrol-position: bottom right;
                width: 30px; height: 14px; border: 0; border-left: 1px solid #cad6df;
                border-top: 1px solid #cad6df; border-bottom-right-radius: 9px;
                background: #f2f6f8; }
            QSpinBox::up-button:hover, QDoubleSpinBox::up-button:hover,
            QSpinBox::down-button:hover, QDoubleSpinBox::down-button:hover {
                background: #e9f5f3; }
            QSpinBox::up-button:pressed, QDoubleSpinBox::up-button:pressed,
            QSpinBox::down-button:pressed, QDoubleSpinBox::down-button:pressed {
                background: #d9f1ed; }
            QSpinBox::up-button:disabled, QDoubleSpinBox::up-button:disabled,
            QSpinBox::down-button:disabled, QDoubleSpinBox::down-button:disabled {
                background: #edf1f4; }
            QSpinBox::up-arrow, QDoubleSpinBox::up-arrow {
                image: url("__SPIN_UP_ARROW__"); width: 12px; height: 8px; }
            QSpinBox::down-arrow, QDoubleSpinBox::down-arrow {
                image: url("__COMBO_ARROW__"); width: 12px; height: 8px; }
            QSpinBox::up-arrow:disabled, QDoubleSpinBox::up-arrow:disabled {
                image: url("__DISABLED_UP_ARROW__"); }
            QSpinBox::down-arrow:disabled, QDoubleSpinBox::down-arrow:disabled {
                image: url("__DISABLED_DOWN_ARROW__"); }
            QLineEdit:disabled, QTextEdit:disabled, QComboBox:disabled,
            QSpinBox:disabled, QDoubleSpinBox:disabled, QListWidget:disabled {
                color: #536675; background: #edf1f4; }
            QComboBox QAbstractItemView { color: #1c2938; background: #ffffff;
                                      selection-color: #075b55; selection-background-color: #d9f1ed; }
            QLineEdit:focus, QTextEdit:focus, QComboBox:focus,
            QSpinBox:focus, QDoubleSpinBox:focus { border: 1px solid #087f77; }
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
        """
        if dark:
            colors = {
                "#1c2938": "#e3eaf0", "#f5f7fa": "#151b24", "#102d3b": "#f2f8fa",
                "#677989": "#a7b7c5", "#ffffff": "#242d39", "#dce5eb": "#3b4a59",
                "#31516a": "#bfd4df", "#cad6df": "#506274", "#c8ece8": "#245c59",
                "#f2f6f8": "#303d49", "#e9f5f3": "#34514f", "#edf1f4": "#303944",
                "#d9f1ed": "#245c59", "#536675": "#9baebc", "#075b55": "#e2fffa",
                "#173042": "#e3eaf0", "#78b8ae": "#72c7ba", "#d9e1e7": "#475766",
                "#edf2f5": "#303d49", "#e8f2f4": "#263d48", "#657582": "#a7b7c5",
            }
            for light_color, dark_color in colors.items():
                sheet = sheet.replace(light_color, dark_color)
        suffix = "_dark" if dark else ""
        for placeholder, filename in (
            ("__COMBO_ARROW__", f"combo_arrow{suffix}.svg"),
            ("__SPIN_UP_ARROW__", f"spin_up_arrow{suffix}.svg"),
            ("__DISABLED_DOWN_ARROW__", f"down_arrow_disabled{suffix}.svg"),
            ("__DISABLED_UP_ARROW__", f"spin_up_arrow_disabled{suffix}.svg"),
        ):
            sheet = sheet.replace(placeholder, Path(__file__).with_name(filename).as_posix())
        self.setStyleSheet(sheet)
        if self.map_ready:
            self._js("setTheme", dark)

    def _system_theme_changed(self, _scheme):
        if self.settings.get("appearance", "system") == "system":
            self._apply_style()

    def _show_research_notice(self):
        QMessageBox.warning(self, "使用须知", RESEARCH_NOTICE, QMessageBox.Ok)
        self.settings["research_notice_acknowledged"] = True
        self._write_json(SETTINGS, self.settings)

    def _show_startup_notices(self):
        version = current_version()
        notes = load_release_notes(version)
        if notes and self.settings.get("last_shown_release_version") != version:
            content = ("重大更新\n" + "\n".join(f"• {item}" for item in notes.highlights)
                       + "\n\n问题修复\n" + "\n".join(f"• {item}" for item in notes.fixes))
            QMessageBox.information(self, f"AnyWay {version} 更新内容", content, QMessageBox.Ok)
            self.settings["last_shown_release_version"] = version
            self._write_json(SETTINGS, self.settings)
        if not self.settings.get("research_notice_acknowledged", False):
            self._show_research_notice()
        if self.settings.get("auto_refresh", True):
            self.refresh_devices()
        QTimer.singleShot(300, self.check_for_updates)

    def _task(self, fn, done, busy_text, on_error=None):
        self.status.setText(busy_text)
        task = Task(fn)
        task.signals.result.connect(done)
        task.signals.error.connect(on_error or self.status.setText)
        self.pool.start(task)

    def _map_loaded(self, ok):
        self.map_ready = ok
        if ok:
            self._apply_style()
            self.draw_map(True)
        else:
            self.status.setText("地图加载失败：本软件接入境外 OpenStreetMap 地图服务，中国大陆暂不可用。")

    def _js(self, function, *args):
        if self.map_ready:
            self.map.page().runJavaScript(function + "(" + ",".join(json.dumps(a, ensure_ascii=False) for a in args) + ")")

    def draw_map(self, fit=False, preview=None):
        if preview is None:
            preview = self._previews.get(self._preview_target())
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
                 fit, not self.text_pending)

    def _single_coordinate(self):
        return Coordinate(float(self.latitude.text()), float(self.longitude.text()))

    def map_clicked(self, latitude, longitude):
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
        if self.text_pending or not 0 <= index < len(self.points):
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
        self._store_current_device_draft()
        self._update_action_state()

    def apply_text(self):
        try:
            self.points = parse_points(self.route_text.toPlainText())
            self.text_pending = False
            self._store_current_device_draft()
            self._update_action_state()
            self.draw_map(True)
            self.status.setText(f"已应用 {len(self.points)} 个路径点。")
        except ValueError as exc:
            self.status.setText(str(exc))

    def undo_point(self):
        if self.points:
            self.points.pop()
            self._sync_text()
            self.draw_map(True)

    def clear_route(self):
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
        points = parse_points(self.route_text.toPlainText()) if self.text_pending else self.points[:]
        plan = DynamicPlan(self.dynamic_mode.currentData(), self.preset.currentData(),
                           self.interval.value(), self.low_min.value() * 60 + self.low_sec.value(),
                           self.recovery.value())
        config = Configuration(self.name.text(), self._single_coordinate(), points,
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
        if self.runners or self._device_busy or self._refreshing:
            return
        self._refreshing = True
        self._update_action_state()

        def discover():
            found, errors = [], []
            harmony_attached = False
            developer_mode_required = []
            iphone_transports = {}
            for kind, lookup in (("ios", connected_devices_with_status), ("android", connected_android_devices),
                                 ("harmony", connected_harmony_devices)):
                try:
                    if kind == "ios":
                        iphones, developer_mode_required, iphone_transports = lookup()
                        found.extend((kind, identifier) for identifier in iphones)
                        continue
                    if kind == "harmony":
                        if not configure_hdc():
                            harmony_attached = harmony_usb_connected()
                            if harmony_attached:
                                errors.append("已接入华为 USB 设备，但未找到 hdc。")
                            continue
                    found.extend((kind, identifier) for identifier in lookup())
                except RuntimeError as exc:
                    errors.append(str(exc))
            return found, errors, harmony_attached, developer_mode_required, iphone_transports

        def finished(result):
            self._refreshing = False
            if not self.runners and not self._device_busy:
                found, errors, harmony_attached, required, transports = result
                direct = {udid: address for udid, address in self.direct_iphone_addresses.items()
                          if transports.get(udid) != "USB"}
                for udid, address in direct.items():
                    if ("ios", udid) not in found:
                        found.append(("ios", udid))
                    transports[udid] = address
                self._set_devices((found, errors, harmony_attached, required, transports, direct))
            self._update_action_state()

        def failed(message):
            self._refreshing = False
            self._update_action_state()
            if not self.runners and not self._device_busy:
                self.status.setText(message)

        self._task(discover, finished, "正在刷新已发现的设备…", failed)

    def _set_devices(self, result):
        devices, errors, harmony_attached, developer_mode_required, iphone_transports, direct_addresses = result
        self._usb_iphones = {udid for udid, transport in iphone_transports.items() if transport == "USB"}
        self.direct_iphone_addresses.clear()
        self.direct_iphone_addresses.update(direct_addresses)
        previous = self.device_combo.currentData()
        self.device_combo.clear()
        for kind, identifier in devices:
            label = ("iOS 设备 · " + identifier[-8:] +
                     (" · " + iphone_transports[identifier] if identifier in iphone_transports else "") +
                     (" · 请开启开发者模式" if identifier in developer_mode_required else "") if kind == "ios"
                     else "HarmonyOS 设备 · " + identifier if kind == "harmony"
                     else "Android 设备 · " + identifier)
            target = (kind, identifier)
            index = self._show_device(target, label)
            if target == previous:
                self.device_combo.setCurrentIndex(index)
        if self.device_combo.currentIndex() < 0 and self.device_combo.count():
            self.device_combo.setCurrentIndex(0)
        self._sync_route_devices()
        self._update_action_state()
        self.status.setText((f"找到 {len(devices)} 台设备。" if devices else "未找到设备。")
                            + (" " + "；".join(errors) if errors and not devices else ""))
        if developer_mode_required:
            self.status.setText("已尝试显示 iPhone 开发者模式开关。请在手机的设置 → 隐私与安全性 → 开发者模式中开启，并按提示重启确认。")
            guided = set(self.settings.get("developer_mode_guide_shown_udids", []))
            first = next((udid for udid in developer_mode_required if udid not in guided), None)
            if first:
                guided.add(first)
                self.settings["developer_mode_guide_shown_udids"] = sorted(guided)
                self._write_json(SETTINGS, self.settings)
                QMessageBox.information(
                    self, "在 iPhone 上开启开发者模式",
                    "已尝试显示 iPhone 的开发者模式开关。请在手机上：\n\n"
                    "1. 解锁手机，打开“设置 → 隐私与安全性 → 开发者模式”。\n"
                    "2. 打开开关并选择“重新启动”。\n"
                    "3. 重启后解锁，确认“打开开发者模式”，按提示输入锁屏密码。\n"
                    "4. 回到 AnyWay，点击“刷新”重新连接。",
                    QMessageBox.Ok)
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

    def _show_device(self, target, default_label):
        index = next((i for i in range(self.device_combo.count())
                      if self.device_combo.itemData(i) == target), -1)
        if index < 0:
            index = self.device_combo.count()
            self.device_combo.addItem(default_label, target)
        alias = self.device_aliases.get(":".join(target))
        self.device_combo.setItemText(index, f"{alias} · {default_label}" if alias else default_label)
        self.device_combo.setItemData(index, default_label, Qt.ItemDataRole.ToolTipRole)
        return index

    def rename_device(self):
        target = self.device_combo.currentData()
        if target:
            self._edit_device_name(target)

    def rename_recent_device(self):
        index = self.recent_combo.currentIndex()
        if index >= 0:
            self._edit_device_name(("ios", self.recent_ips[index]["udid"]))

    def _edit_device_name(self, target):
        key = ":".join(target)
        name, ok = QInputDialog.getText(self, "设备名称", "设备名称（留空恢复默认显示）",
                                        text=self.device_aliases.get(key, ""))
        if ok:
            if name.strip():
                self.device_aliases[key] = name.strip()
            else:
                self.device_aliases.pop(key, None)
            self._write_json(SETTINGS, self.settings)
            for index in range(self.device_combo.count()):
                if self.device_combo.itemData(index) == target:
                    self._show_device(target, self.device_combo.itemData(index, Qt.ItemDataRole.ToolTipRole))
                    break
            self._show_recent_ips(self.recent_combo.currentIndex())
            self._sync_route_devices()

    def _show_recent_ips(self, index=0):
        self.recent_combo.clear()
        for row in self.recent_ips:
            phone = self.device_aliases.get("ios:" + row["udid"], "iPhone · " + row["udid"][-8:])
            network = f'网络：{row["name"]} · ' if row["name"] else ""
            label = f'{phone} · {network}{row["address"]}'
            self.recent_combo.addItem(label)
            self.recent_combo.setItemData(self.recent_combo.count() - 1, label, Qt.ItemDataRole.ToolTipRole)
        self.recent_combo.setCurrentIndex(index)
        for widget in (self.recent_label, self.recent_combo, self.reconnect_button,
                       self.rename_recent_device_button, self.rename_ip_button):
            widget.setVisible(bool(self.recent_ips))

    def rename_recent_ip(self):
        index = self.recent_combo.currentIndex()
        if index < 0:
            return
        entry = self.recent_ips[index]
        name, ok = QInputDialog.getText(self, "网络名称", "网络名称（留空恢复默认显示）", text=entry["name"])
        if ok:
            entry["name"] = name.strip()
            self.settings["recent_ip_connections"] = self.recent_ips
            self._write_json(SETTINGS, self.settings)
            self._show_recent_ips(index)

    def reconnect_recent_ip(self):
        index = self.recent_combo.currentIndex()
        if index >= 0:
            entry = self.recent_ips[index]
            self.iphone_ip.setText(entry["address"])
            self._connect_ios_address(entry["address"], entry["udid"])

    def connect_ios_ip(self):
        self._connect_ios_address(self.iphone_ip.text().strip(), None)

    def _connect_ios_address(self, address, expected):
        if not address:
            self.status.setText("请输入 iPhone 的 Wi-Fi IPv4 地址。")
            return

        def connected(udid):
            self.recent_ips = remember_ip(self.recent_ips, address, udid)
            self.settings["recent_ip_connections"] = self.recent_ips
            self._show_recent_ips()
            self._write_json(SETTINGS, self.settings)
            self.direct_iphone_addresses[udid] = address
            target = ("ios", udid)
            label = f"iPhone · {udid[-8:]} · {address}"
            index = self._show_device(target, label)
            self.device_combo.setCurrentIndex(index)
            self._sync_route_devices()
            self.status.setText(f"已连接 {address}，定位服务可用。")

        def show_hotspot(message):
            answer = QMessageBox.question(
                self, "未能通过 IP 连接 iPhone",
                message + "\n\n要打开 Windows 移动热点设置吗？开启热点后，让 iPhone 加入该网络，再点击“刷新”。",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
            if answer == QMessageBox.Yes:
                QDesktopServices.openUrl(QUrl("ms-settings:network-mobilehotspot"))

        self._device_task(lambda: check_ip(address, expected), connected, "正在验证 iPhone 配对和定位服务…", show_hotspot)

    def prepare_ios_wireless(self):
        device = self.device_combo.currentData()
        if not device or device[0] != "ios" or device[1] not in self._usb_iphones:
            QMessageBox.information(self, "开启 iPhone 无线连接", "请先用 USB 连接并选中 iPhone。")
            return
        self._device_task(lambda: prepare_wireless(device[1]), self._wireless_prepared,
                          "正在为 iPhone 开启无线连接…")

    def _wireless_prepared(self, _result):
        self.status.setText("无线连接已准备好。拔掉数据线后，保持同一网络并点击刷新。")
        if self.settings.get("hide_wireless_guide", False):
            return
        dialog = QMessageBox(self)
        dialog.setWindowTitle("iPhone 无线连接已准备好")
        dialog.setIcon(QMessageBox.Information)
        dialog.setText("拔掉 USB 数据线后，选择以下任一种连接方式：\n\n"
                       "方案 1：让电脑和 iPhone 连接同一个私人局域网。\n"
                       "方案 2：在 iPhone 开启个人热点，让电脑连接该热点。\n\n"
                       "连接后点击“刷新”。校园网搜不到设备时，可在“目标设备”中输入 iPhone 的 Wi-Fi IPv4 地址直连。")
        skip = QCheckBox("勾选后不再显示此内容")
        dialog.setCheckBox(skip)
        dialog.setStandardButtons(QMessageBox.Ok)
        dialog.exec()
        if skip.isChecked():
            self.settings["hide_wireless_guide"] = True
            self._write_json(SETTINGS, self.settings)

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
        return self._backend(target), target[1]

    def _backend(self, target):
        kind, identifier = target
        if kind == "ios":
            if identifier not in self.ios_sessions:
                session = PhoneSession()
                session.direct_addresses = self.direct_iphone_addresses
                self.ios_sessions[identifier] = session
            return self.ios_sessions[identifier]
        return self.android_bridge if kind == "android" else self.harmony_bridge

    def set_point(self):
        if self.runners or self._device_busy:
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
        if self.runners or self._device_busy:
            return
        try:
            backend, identifier = self._target()
            self._device_task(lambda: backend.clear(identifier),
                              lambda _: self.status.setText("已清除模拟定位。"), "正在清除定位…")
        except ValueError as exc:
            self.status.setText(str(exc))

    def _sync_route_devices(self):
        menu = self.route_targets.menu()
        checked = {action.data() for action in menu.actions() if action.isChecked()}
        menu.clear()
        self.route_editor.blockSignals(True)
        self.route_editor.clear()
        self.route_editor.addItem("共用配置")
        for index in range(self.device_combo.count()):
            target = self.device_combo.itemData(index)
            label = self.device_combo.itemText(index)
            action = menu.addAction(label)
            action.setData(target)
            action.setCheckable(True)
            action.setChecked(target in checked)
            self.route_editor.addItem(label, target)
            if target == self._route_scope:
                self.route_editor.setCurrentIndex(self.route_editor.count() - 1)
        if self._route_scope and not self.route_editor.currentData():
            self.route_editor.addItem("已断开的设备", self._route_scope)
            self.route_editor.setCurrentIndex(self.route_editor.count() - 1)
        self.route_editor.blockSignals(False)

    def _switch_route_editor(self, _index):
        scope = self.route_editor.currentData()
        if scope == self._route_scope:
            return
        self._update_live_route()
        current = self._draft_data()
        if self._route_scope is None:
            self._shared_draft = current
        elif current != self._editor_baseline:
            self._device_drafts[self._route_scope] = current
        self._route_scope = scope
        draft = self._device_drafts.get(scope, self._shared_draft)
        self._loading_draft = True
        try:
            self._load_editor_draft(draft)
        finally:
            self._loading_draft = False
        self._editor_baseline = self._draft_data()
        self._last_live_draft = self._editor_baseline
        self._show_shared_button()
        self.draw_map(True)

    def _store_current_device_draft(self):
        if self._route_scope is not None and not self._loading_draft:
            self._store_device_draft(self._draft_data())

    def _store_device_draft(self, draft):
        if self._route_scope is not None and draft != self._editor_baseline:
            self._device_drafts[self._route_scope] = draft
            self._show_shared_button()

    def _show_shared_button(self):
        self.restore_shared_button.setVisible(self._route_scope in self._device_drafts)

    def _restore_shared_route(self):
        scope = self._route_scope
        self.route_editor.setCurrentIndex(0)
        self._device_drafts.pop(scope, None)
        if scope in self.runners:
            try:
                self.runners[scope].update(self._run_configuration(self._draft_data()))
            except ValueError:
                pass

    def _run_configuration(self, draft):
        points = [Coordinate(**point) for point in draft["points"]]
        if len(points) < 2 or route_length(points) < .001:
            raise ValueError("每台设备的路线至少需要两个不同的路径点。")
        plan = DynamicPlan(draft["dynamicMode"], draft["dynamicPreset"], draft["interval"],
                           draft["lowMinutes"] * 60 + draft["lowSeconds"], draft["recovery"])
        config = Configuration("路线", points[0], points, draft["speed"], draft["jitter"], draft["passes"],
                               draft["pathVariation"], draft["dynamicSpeed"], plan)
        config.validate()
        return config

    def _update_live_route(self):
        draft = self._draft_data()
        if draft == self._last_live_draft:
            return
        self._last_live_draft = draft
        self._store_device_draft(draft)
        if not self.runners:
            return
        try:
            config = self._run_configuration(draft)
        except ValueError:
            return
        for target, runner in self.runners.items():
            if target == self._route_scope or (self._route_scope is None and target not in self._device_drafts):
                runner.update(config)

    def start_route(self):
        if self.runners or self._device_busy:
            return
        try:
            targets = [action.data() for action in self.route_targets.menu().actions() if action.isChecked()]
            if not targets:
                self._target()
                targets = [self.device_combo.currentData()]
            current = self._draft_data()
            shared = current if self._route_scope is None else self._shared_draft
            configurations = {}
            for target in targets:
                draft = current if target == self._route_scope else self._device_drafts.get(target, shared)
                if draft["textPending"]:
                    raise ValueError("请先在对应路线中点击“应用到地图”，再开始模拟。")
                configurations[target] = self._run_configuration(draft)
            self._run_errors = []
            self._stopping = False
            seed = random.getrandbits(64)
            for index, (target, config) in enumerate(configurations.items()):
                runner = RouteRunner(self._backend(target), target, config,
                                     seed + index * 0x9E3779B97F4A7C15, index, len(targets))
                runner.signals.status.connect(self.status.setText)
                runner.signals.preview.connect(self._route_preview)
                runner.signals.finished.connect(self._route_finished)
                self.runners[target] = runner
            self._update_action_state()
            self.live_timer.start()
            for runner in self.runners.values():
                self.pool.start(runner)
        except ValueError as exc:
            self.status.setText(str(exc))

    def _preview_target(self):
        if self._route_scope is not None:
            return self._route_scope
        return next((target for target in self.runners if target not in self._device_drafts), None)

    def _route_preview(self, target, preview):
        self._previews[target] = preview
        if target == (self._preview_target()):
            self._js("updatePreview", [asdict(point) for point in preview])

    def _route_finished(self, target, error):
        self.runners.pop(target, None)
        self._previews.pop(target, None)
        if error:
            self._run_errors.append(error)
        if self.runners:
            if self._route_scope is None or target == self._route_scope:
                self.draw_map(False)
            return
        self.live_timer.stop()
        self._previews.clear()
        if self._run_errors:
            self.status.setText("；".join(self._run_errors))
        else:
            self.status.setText("路径模拟已停止。" if self._stopping else "路径模拟完成。")
        self._update_action_state()
        self.draw_map(False)

    def _update_action_state(self):
        idle = not self.runners and not self._device_busy
        has_device = self.device_combo.currentData() is not None
        has_place = self.selected_place is not None
        self.device_combo.setEnabled(idle)
        self.route_targets.setEnabled(idle and has_device)
        self.set_button.setEnabled(idle and has_device)
        self.clear_button.setEnabled(idle and has_device)
        self.start_button.setEnabled(idle and has_device)
        self.stop_button.setEnabled(bool(self.runners) and not self._stopping)
        self.rename_device_button.setEnabled(idle and has_device)
        self.recent_combo.setEnabled(idle)
        self.reconnect_button.setEnabled(idle)
        self.rename_recent_device_button.setEnabled(idle)
        self.rename_ip_button.setEnabled(idle)
        self.ip_button.setEnabled(idle)
        self.iphone_ip.setEnabled(idle)
        self.refresh_button.setEnabled(idle and not self._refreshing)
        target = self.device_combo.currentData()
        self.wireless_button.setEnabled(idle and bool(target and target[0] == "ios"
                                                      and target[1] in self._usb_iphones))
        self.place_point_button.setEnabled(has_place)
        self.place_route_button.setEnabled(has_place and not self.text_pending and len(self.points) < 10_000)
        self.undo_button.setEnabled(not self.text_pending and bool(self.points))
        self.clear_route_button.setEnabled(not self.text_pending and bool(self.points))
        self.apply_button.setEnabled(self.text_pending)

    def _device_task(self, fn, done, busy_text, on_error=None):
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
            if on_error:
                on_error(message)

        task = Task(fn)
        task.signals.result.connect(finished)
        task.signals.error.connect(failed)
        self.status.setText(busy_text)
        self.pool.start(task)

    def stop_route(self):
        if self.runners:
            self._stopping = True
            for runner in self.runners.values():
                runner.stop_event.set()
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

    def show_settings(self, expand_update=False):
        dialog = QDialog(self)
        dialog.setWindowTitle("设置")
        layout = QVBoxLayout(dialog)
        restore = QCheckBox("启动时恢复上次路线")
        restore.setChecked(self.settings.get("restore", True))
        auto = QCheckBox("启动时自动刷新设备")
        auto.setChecked(self.settings.get("auto_refresh", True))
        layout.addWidget(restore)
        layout.addWidget(auto)
        appearance = QComboBox()
        for title, key in (("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")):
            appearance.addItem(title, key)
        appearance.setCurrentIndex(max(0, appearance.findData(self.settings.get("appearance", "system"))))
        appearance.currentIndexChanged.connect(lambda: self._set_appearance(appearance.currentData()))
        layout.addWidget(QLabel("外观"))
        layout.addWidget(appearance)
        self.update_settings = UpdateSettings(current_version(), lambda: self.check_for_updates(manual=True),
                                              self._ignore_update)
        layout.addWidget(self.update_settings)
        self._refresh_update_settings()
        if expand_update:
            self.update_settings.toggle.setChecked(True)
        self._button("清除搜索历史", lambda: self.settings.update(history=[]), layout)
        self._button("清除路线记忆", self._clear_draft, layout)
        self._button("完成", dialog.accept, layout)
        dialog.exec()
        self.update_settings = None
        self.settings.update(restore=restore.isChecked(), auto_refresh=auto.isChecked())
        self._write_json(SETTINGS, self.settings)

    def _set_appearance(self, mode):
        self.settings["appearance"] = mode
        self._write_json(SETTINGS, self.settings)
        self._apply_style()

    def _show_update_details(self):
        self.update_banner.hide()
        self.show_settings(expand_update=True)

    def _refresh_update_settings(self):
        if self.update_settings:
            self.update_settings.render(self._update_result, self.settings.get("ignored_update_version", ""),
                                        self._update_check_running)

    def _ignore_update(self, result):
        if result and result.should_prompt(self.settings.get("ignored_update_version", "")):
            self.settings["ignored_update_version"] = result.latest
            self._write_json(SETTINGS, self.settings)
            self.update_banner.hide()
            self._refresh_update_settings()

    def check_for_updates(self, manual=False):
        if self._update_check_running:
            return
        self._update_check_running = True
        self._manual_update_check = manual
        self._refresh_update_settings()
        task = Task(check_update)
        task.signals.result.connect(self._update_checked)
        task.signals.error.connect(self._update_check_failed)
        self.pool.start(task)

    @Slot(object)
    def _update_checked(self, result: UpdateResult):
        manual = self._manual_update_check
        self._update_check_running = False
        if not result.error:
            if self._update_result and self._update_result.latest != result.latest:
                self.update_banner.hide()
            self._update_result = result
            if not manual and result.should_prompt(self.settings.get("ignored_update_version", "")):
                self.update_banner_text.setText(f"AnyWay {result.latest} 已发布")
                self.update_banner.show()
        self._refresh_update_settings()
        if manual and (result.error or not result.available):
            message = f"无法连接 GitHub：{result.error}" if result.error else f"当前已是最新版本（{result.current}）。"
            QMessageBox.information(self, "检查更新", message)

    def _update_check_failed(self, message):
        self._update_check_running = False
        self._refresh_update_settings()
        self.status.setText(f"检查更新失败：{message}")

    def _clear_draft(self):
        self._cleared_draft_snapshot = self._draft_data() if self._route_scope is None else self._shared_draft
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
            data = self._draft_data() if self._route_scope is None else self._shared_draft
            if not data or data == self._cleared_draft_snapshot:
                return
            self._cleared_draft_snapshot = None
            self._write_json(DRAFT, data)
        except OSError:
            pass

    def _load_draft(self):
        if not self.settings.get("restore", True):
            return
        data = self._read_json(DRAFT, {})
        if data:
            self._load_editor_draft(data)

    def _load_editor_draft(self, data):
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
        if self.runners:
            self._stopping = True
            for runner in self.runners.values():
                runner.stop_event.set()
            self.status.setText("正在停止路线并清除定位…")
        # Finish in-flight set/clear operations before clearing active mock providers.
        if not self.pool.waitForDone(5000):
            event.ignore()
            QMessageBox.information(self, "请稍候", "设备定位操作仍在进行，请稍后再关闭。")
            return
        self._save_draft()
        for session in self.ios_sessions.values():
            session.close()
        self.android_bridge.close()
        self.harmony_bridge.close()
        event.accept()


def main():
    migrate_legacy_data()
    app = QApplication(sys.argv)
    resource_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    app.setWindowIcon(QIcon(str(resource_root / "assets" / "app-icon.png")))
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())

