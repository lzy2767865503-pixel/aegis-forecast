"""Non-overridable safety policy for the Microsoft Store edition.

This module deliberately does not read environment variables or configuration
files.  The Windows Store v1 build is a research-only product: no runtime flag,
local file, HTTP request, or broker state may enable order execution.
"""

from __future__ import annotations


STORE_EDITION = "WINDOWS_STORE_READ_ONLY"
STORE_READ_ONLY = True
LIVE_TRADING_ALLOWED = False
SIMULATION_EXECUTION_ALLOWED = False

EXECUTION_FORBIDDEN_MESSAGE = (
    "Windows Store 只读版仅提供研究功能，不包含交易或自动执行模块"
)


def simulation_execution_enabled() -> bool:
    """Return the immutable Store capability instead of consulting the process."""

    return SIMULATION_EXECUTION_ALLOWED


def require_execution_allowed() -> None:
    """Fail closed at service/gateway boundaries even outside the HTTP server."""

    raise PermissionError(EXECUTION_FORBIDDEN_MESSAGE)
