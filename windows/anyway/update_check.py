"""Check the latest published AnyWay release without blocking startup on network errors."""
from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen

RELEASE_API = "https://api.github.com/repos/EpiphanyMio/AnyWay/releases/latest"
RELEASES_URL = "https://github.com/EpiphanyMio/AnyWay/releases"
_VERSION = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


@dataclass(frozen=True)
class UpdateResult:
    current: str
    latest: str | None
    release_url: str
    error: str | None = None

    @property
    def required(self) -> bool:
        current = parse_version(self.current)
        latest = parse_version(self.latest or "")
        return current is not None and latest is not None and latest > current


def parse_version(value: str) -> tuple[int, int, int] | None:
    match = _VERSION.fullmatch(value)
    return tuple(map(int, match.groups())) if match else None


def current_version() -> str:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    return (root / "VERSION").read_text(encoding="utf-8").strip()


def check_update(version: str | None = None) -> UpdateResult:
    current = version or current_version()
    try:
        request = Request(RELEASE_API, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "AnyWay-update-checker/0.1",
        })
        with urlopen(request, timeout=10) as response:
            release = json.load(response)
        tag = release["tag_name"]
        if parse_version(tag) is None:
            raise ValueError("发布版本号格式无效")
        return UpdateResult(current, tag.removeprefix("v"),
                            f"{RELEASES_URL}/tag/{tag}")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return UpdateResult(current, None, RELEASES_URL, str(exc))
