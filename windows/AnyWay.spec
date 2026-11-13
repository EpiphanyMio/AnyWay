# -*- mode: python ; coding: utf-8 -*-
"""One shared runtime for the windowed UI and the piped iPhone bridge."""

from PyInstaller.utils.hooks import collect_data_files, collect_submodules


assets = [
    ("anyway/map.html", "anyway"),
    ("anyway/qwebchannel.js", "anyway"),
    ("anyway/vendor", "anyway/vendor"),
    ("anyway/iphone_bridge.py", "anyway"),
    ("../assets/app-icon.png", "assets"),
    ("../VERSION", "."),
]
for name in ("combo_arrow", "spin_up_arrow", "down_arrow_disabled",
             "spin_up_arrow_disabled", "combo_arrow_dark", "spin_up_arrow_dark",
             "down_arrow_disabled_dark", "spin_up_arrow_disabled_dark"):
    assets.append((f"anyway/{name}.svg", "anyway"))

analysis = Analysis(
    ["launcher.py"],
    pathex=["."],
    binaries=[],
    datas=assets + collect_data_files("pymobiledevice3") + collect_data_files("pytun_pmd3"),
    hiddenimports=collect_submodules("pymobiledevice3") + collect_submodules("pytun_pmd3"),
    hookspath=[],
    runtime_hooks=["scripts/pyi_rth_qt_dll.py"],
    excludes=["IPython", "matplotlib", "pytest", "PySide6.QtWebEngineQuick",
              "PySide6.QtQuick", "PySide6.QtQml", "PySide6.QtDesigner"],
)
archive = PYZ(analysis.pure)

gui = EXE(
    archive, analysis.scripts, [],
    exclude_binaries=True,
    name="AnyWay",
    console=False,
    icon="../assets/app-icon.ico",
    contents_directory="runtime",
)
bridge = EXE(
    archive, analysis.scripts, [],
    exclude_binaries=True,
    name="AnyWayBridge",
    console=True,
    icon="../assets/app-icon.ico",
    contents_directory="runtime",
)
COLLECT(gui, bridge, analysis.binaries, analysis.datas, name="AnyWay")
