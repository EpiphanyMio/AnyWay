"""Bundled release notes shown once per installed product version."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import sys


@dataclass(frozen=True)
class ReleaseNotes:
    version: str
    highlights: tuple[str, ...]
    fixes: tuple[str, ...]


def load(current_version: str) -> ReleaseNotes | None:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    try:
        raw = json.loads((root / "RELEASE_NOTES.json").read_text(encoding="utf-8"))
        if raw["version"] != current_version or not raw["highlights"] or not raw["fixes"]:
            return None
        return ReleaseNotes(raw["version"], tuple(raw["highlights"]), tuple(raw["fixes"]))
    except (OSError, ValueError, KeyError, TypeError):
        return None
