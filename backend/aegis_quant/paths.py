from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parent
BACKEND_ROOT = PACKAGE_ROOT.parent
APP_ROOT = BACKEND_ROOT.parent
WORKSPACE_ROOT = APP_ROOT.parent
CONFIG_ROOT = APP_ROOT / "config"
STORAGE_ROOT = APP_ROOT / "storage"
FRONTEND_DIST = APP_ROOT / "frontend" / "dist"
LEGACY_OUTPUTS = WORKSPACE_ROOT / "outputs"


def ensure_directories() -> None:
    for path in (
        STORAGE_ROOT,
        STORAGE_ROOT / "audit",
        STORAGE_ROOT / "universe",
        STORAGE_ROOT / "models",
        STORAGE_ROOT / "paper",
        STORAGE_ROOT / "experiments",
    ):
        path.mkdir(parents=True, exist_ok=True)
