from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parent
BACKEND_ROOT = PACKAGE_ROOT.parent
SOURCE_ROOT = BACKEND_ROOT.parent
APP_ROOT = SOURCE_ROOT
WORKSPACE_ROOT = SOURCE_ROOT.parent

# PyInstaller exposes bundled, immutable resources under ``_MEIPASS``. In a
# source checkout this remains the repository root.
RESOURCE_ROOT = Path(getattr(sys, "_MEIPASS", SOURCE_ROOT)).resolve()
CONFIG_ROOT = RESOURCE_ROOT / "config"
DEMO_ROOT = RESOURCE_ROOT / "demo_data"
FRONTEND_DIST = RESOURCE_ROOT / "frontend" / "dist"
LEGACY_OUTPUTS = WORKSPACE_ROOT / "outputs"
APP_OWNED_DIRECTORIES = frozenset({"experiments", "models", "runtime", "settings"})
APP_OWNED_FILES = frozenset(
    {"operational.db", "operational.db-shm", "operational.db-wal"}
)
DATA_ROOT_MARKER = ".quant-scenario-localstate.json"
DATA_ROOT_PRODUCT = "Quant Scenario Studio by LAI ZEYU"
DATA_ROOT_SCHEMA = 1


def _is_within(path: Path, parent: Path) -> bool:
    resolved = path.resolve()
    base = parent.resolve()
    return resolved == base or base in resolved.parents


def _validate_binding(root: Path, binding: str) -> None:
    if not binding:
        raise ValueError("AEGIS_DATA_ROOT_BINDING is required with AEGIS_DATA_ROOT")
    if binding.startswith("PFN:"):
        if sys.platform != "win32":
            raise ValueError("PFN data-root bindings are Windows-only")
        package_family = binding[4:]
        if not package_family or any(separator in package_family for separator in ("/", "\\")):
            raise ValueError("PFN data-root binding is invalid")
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            raise RuntimeError("LOCALAPPDATA is required for a PFN binding")
        expected = (Path(local_app_data) / "Packages" / package_family / "LocalState").resolve()
        if root.resolve() != expected:
            raise ValueError("AEGIS_DATA_ROOT does not match its PFN LocalState binding")
        return
    if binding.startswith("TEST:"):
        allowed_temp_roots = {
            Path(tempfile.gettempdir()).resolve(),
            *(
                Path(value).resolve()
                for name in ("RUNNER_TEMP", "TEMP", "TMP", "TMPDIR")
                if (value := os.environ.get(name))
            ),
        }
        if not any(_is_within(root, candidate) for candidate in allowed_temp_roots):
            raise ValueError("TEST data-root bindings must remain under an OS temporary directory")
        return
    if binding == "SOURCE_CHECKOUT" and root.resolve() == (SOURCE_ROOT / "storage").resolve():
        return
    if binding == "UNPACKAGED_WINDOWS":
        local_app_data = os.environ.get("LOCALAPPDATA")
        expected = (
            Path(local_app_data) / "AegisForecast" / "LocalState"
            if local_app_data
            else None
        )
        if expected is not None and root.resolve() == expected.resolve():
            return
    raise ValueError("Unsupported or mismatched AEGIS_DATA_ROOT_BINDING")


def _storage_root() -> tuple[Path, str]:
    configured = os.environ.get("AEGIS_DATA_ROOT")
    if configured:
        candidate = Path(configured).expanduser()
        if not candidate.is_absolute():
            raise ValueError("AEGIS_DATA_ROOT must be an absolute path")
        binding = os.environ.get("AEGIS_DATA_ROOT_BINDING", "")
        _validate_binding(candidate, binding)
        # Preserve the caller's lexical root until the safety check so a
        # symlinked LocalState root cannot disappear through early resolve().
        return candidate, binding

    if sys.platform == "win32":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            raise RuntimeError("LOCALAPPDATA is required on Windows")
        # This exact fallback is for explicitly unpackaged developer runs only.
        return (
            (Path(local_app_data) / "AegisForecast" / "LocalState").resolve(),
            "UNPACKAGED_WINDOWS",
        )

    return (SOURCE_ROOT / "storage").resolve(), "SOURCE_CHECKOUT"


STORAGE_ROOT, STORAGE_BINDING = _storage_root()


def _assert_safe_root(root: Path, binding: str) -> Path:
    requested = root.expanduser()
    if not requested.is_absolute():
        raise RuntimeError("Refusing a non-absolute data root")
    if requested.exists() and (
        requested.is_symlink()
        or (hasattr(requested, "is_junction") and requested.is_junction())
    ):
        raise RuntimeError("Refusing a symlinked or junction data root")
    target = requested.resolve()
    if target == Path(target.anchor) or target in {SOURCE_ROOT.resolve(), RESOURCE_ROOT}:
        raise RuntimeError("Refusing to use an unsafe data root")
    _validate_binding(target, binding)
    return target


def bind_data_root(root: Path | None = None, *, binding: str | None = None) -> Path:
    """Bind an exact safe root to this app using a persistent ownership marker."""

    requested = root or STORAGE_ROOT
    exact_binding = binding or (
        STORAGE_BINDING if requested.resolve() == STORAGE_ROOT.resolve() else ""
    )
    target = _assert_safe_root(requested, exact_binding)
    target.mkdir(parents=True, exist_ok=True)
    marker_path = target / DATA_ROOT_MARKER
    expected = {
        "schemaVersion": DATA_ROOT_SCHEMA,
        "product": DATA_ROOT_PRODUCT,
        "binding": exact_binding,
        "canonicalRoot": str(target),
    }
    if marker_path.exists():
        if marker_path.is_symlink():
            raise RuntimeError("Aegis LocalState ownership marker may not be a symlink")
        try:
            actual = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("Aegis LocalState ownership marker is unreadable") from exc
        if actual != expected:
            raise RuntimeError("Aegis LocalState ownership marker does not match this root")
    else:
        temporary = marker_path.with_name(f"{marker_path.name}.{os.getpid()}.tmp")
        if temporary.exists() or temporary.is_symlink():
            raise RuntimeError("Refusing a preexisting ownership-marker temporary path")
        try:
            with temporary.open("x", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(expected, ensure_ascii=False, indent=2, sort_keys=True)
                    + "\n"
                )
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(marker_path)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def ensure_directories(
    root: Path | None = None,
    *,
    binding: str | None = None,
) -> None:
    target = bind_data_root(root, binding=binding)
    for path in (
        target / "models",
        target / "experiments",
        target / "runtime",
        target / "settings",
    ):
        path.mkdir(parents=True, exist_ok=True)


def clear_local_data(
    data_root: Path | None = None,
    *,
    binding: str | None = None,
) -> dict[str, object]:
    """Delete only allowlisted app paths beneath a marker-bound data root."""

    requested = data_root or STORAGE_ROOT
    exact_binding = binding or (
        STORAGE_BINDING if requested.resolve() == STORAGE_ROOT.resolve() else ""
    )
    root = _assert_safe_root(requested, exact_binding)
    marker_path = root / DATA_ROOT_MARKER
    if marker_path.is_symlink() or not marker_path.is_file():
        raise RuntimeError("Refusing to clear an unbound data root")
    # Revalidate the full marker before any destructive operation.
    bind_data_root(root, binding=exact_binding)

    removed: list[str] = []
    candidates = [
        *(root / name for name in sorted(APP_OWNED_DIRECTORIES)),
        *(root / name for name in sorted(APP_OWNED_FILES)),
    ]
    for child in candidates:
        if not child.exists() and not child.is_symlink():
            continue
        resolved = child.resolve()
        if root not in resolved.parents:
            raise RuntimeError("Refusing to delete a path outside Aegis LocalState")
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink(missing_ok=True)
        removed.append(child.name)
    ensure_directories(root, binding=exact_binding)
    return {
        "ok": True,
        "removed": sorted(removed),
        "dataRootKind": "Marker-bound LocalState",
    }
