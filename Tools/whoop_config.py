"""Machine-local settings: environment, then Config/Local.xcconfig, then
~/.config/whoop/local.xcconfig. Personal values never live in Git."""

from __future__ import annotations

import os
import re
from functools import cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
_LINE = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$")


@cache
def _file_settings() -> dict[str, str]:
    values: dict[str, str] = {}
    for path in (Path.home() / ".config/whoop/local.xcconfig", REPO_ROOT / "Config/Local.xcconfig"):
        try:
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            match = _LINE.match(line.split("//", 1)[0] if "://" not in line else line)
            if match and match.group(2):
                values[match.group(1)] = match.group(2)
    return values


def setting(key: str, default: str = "") -> str:
    return os.environ.get(key) or _file_settings().get(key) or default


def data_root() -> Path:
    return Path(setting("WHOOP_DATA_ROOT", str(Path.home() / "whoop-data"))).expanduser()
