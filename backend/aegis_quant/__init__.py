"""Aegis Forecast local quantitative research platform."""

from .environment import load_project_env


# Developer settings can configure read-only data sources, but the Store safety
# policy is compiled into ``runtime_policy`` and cannot be changed by ``.env``.
load_project_env()

__version__ = "1.5.0"
