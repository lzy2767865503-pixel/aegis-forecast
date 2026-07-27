"""Load project-local environment settings without executing shell code."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV_PATH = PROJECT_ROOT / ".env"
_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _parse_value(raw_value: str, *, line_number: int) -> str:
    value = raw_value.strip()
    if not value:
        return ""

    if value[0] in {"'", '"'}:
        quote = value[0]
        escaped = False
        closing_index: int | None = None
        for index, character in enumerate(value[1:], start=1):
            if quote == '"' and character == "\\" and not escaped:
                escaped = True
                continue
            if character == quote and not escaped:
                closing_index = index
                break
            escaped = False

        if closing_index is None:
            raise ValueError(f"Unterminated quoted value in .env line {line_number}")
        trailing = value[closing_index + 1 :].strip()
        if trailing and not trailing.startswith("#"):
            raise ValueError(f"Unexpected content in .env line {line_number}")
        quoted_value = value[: closing_index + 1]

        if quote == "'":
            return quoted_value[1:-1]
        try:
            decoded = json.loads(quoted_value)
        except json.JSONDecodeError as error:
            raise ValueError(
                f"Invalid double-quoted value in .env line {line_number}"
            ) from error
        if not isinstance(decoded, str):
            raise ValueError(f"Invalid value in .env line {line_number}")
        return decoded

    # An inline comment starts only after whitespace, so values such as
    # https://example.test/#fragment remain intact.
    return re.split(r"\s+#", value, maxsplit=1)[0].rstrip()


def load_project_env(path: Path | None = None) -> dict[str, str]:
    """Load ``.env`` values while preserving variables exported by the caller.

    The parser accepts ``KEY=value`` and ``export KEY=value`` syntax. It never
    invokes a shell, performs command substitution, or expands other variables.
    """

    env_path = path or DEFAULT_ENV_PATH
    if not env_path.is_file():
        return {}

    loaded: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        env_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ValueError(f"Invalid .env assignment on line {line_number}")

        key, raw_value = line.split("=", 1)
        key = key.strip()
        if not _KEY_PATTERN.fullmatch(key):
            raise ValueError(f"Invalid .env key on line {line_number}")

        value = _parse_value(raw_value, line_number=line_number)
        if key not in os.environ:
            os.environ[key] = value
            loaded[key] = value
    return loaded
