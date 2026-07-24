from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from .paths import CONFIG_ROOT


def _load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


@lru_cache(maxsize=1)
def system_config() -> dict[str, Any]:
    return _load(CONFIG_ROOT / "system.json")


@lru_cache(maxsize=1)
def model_config() -> dict[str, Any]:
    return _load(CONFIG_ROOT / "model_config.json")
