"""Per-user settings location and one-time migration from the old folder."""

import os
from pathlib import Path
import shutil


APP_DIR = Path(os.getenv("APPDATA") or Path.home() / ".config") / "AnyWay"
SETTINGS = APP_DIR / "settings.json"
DRAFT = APP_DIR / "draft.json"


def migrate_legacy_data(app_dir: Path = APP_DIR) -> None:
    old_dir = app_dir.parent / "WindowsLocationSimulator"
    if old_dir.is_dir() and not app_dir.exists():
        old_dir.rename(app_dir)
        return
    for name in ("settings.json", "draft.json"):
        source = old_dir / name
        target = app_dir / name
        if source.is_file() and not target.exists():
            app_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


def recent_ip_connections(settings):
    rows = settings.get("recent_ip_connections", [settings.get("direct_iphone")])
    return [{"address": row["address"], "udid": row["udid"], "name": row.get("name", "")}
            for row in rows if isinstance(row, dict) and row.get("address") and row.get("udid")]


def remember_ip(entries, address, udid):
    previous = next((row for row in entries if row["address"] == address and row["udid"] == udid), None)
    entry = previous or {"address": address, "udid": udid, "name": ""}
    return [entry] + [row for row in entries if (row["address"], row["udid"]) != (address, udid)]
