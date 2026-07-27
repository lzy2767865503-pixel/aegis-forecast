"""Aegis A local quantitative research and paper-trading platform."""

from .environment import load_project_env


# Load project-local defaults before importing modules that read os.environ.
# Existing process variables always win, and the parser never executes shell
# expressions from the file.
load_project_env()

__version__ = "1.4.0"
