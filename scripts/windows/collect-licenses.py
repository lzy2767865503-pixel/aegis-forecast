#!/usr/bin/env python3
"""Collect license evidence for every runtime component shipped in the Store MSIX."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import shutil
import sys
from pathlib import Path


PYTHON_DISTRIBUTIONS = ("pyinstaller",)
NODE_PACKAGES = ("react", "react-dom", "scheduler", "lucide-react")
LICENSE_MARKERS = ("license", "copying", "notice", "authors")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_name(value: str) -> str:
    return "".join(character if character.isalnum() or character in "._-" else "_" for character in value)


def copy_unique(source: Path, destination: Path, prefix: str = "") -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    base = safe_name(f"{prefix}{source.name}")
    target = destination / base
    if target.exists() and target.read_bytes() != source.read_bytes():
        target = destination / f"{target.stem}-{digest(source)[:12]}{target.suffix}"
    shutil.copy2(source, target)
    return target


def collect_python(output: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for name in PYTHON_DISTRIBUTIONS:
        distribution = importlib.metadata.distribution(name)
        destination = output / "Python" / safe_name(name)
        copied: list[Path] = []
        for relative in distribution.files or ():
            parts = [part.lower() for part in Path(relative).parts]
            filename = parts[-1] if parts else ""
            if not any(marker in filename for marker in LICENSE_MARKERS) and "licenses" not in parts:
                continue
            source = Path(distribution.locate_file(relative)).resolve()
            if source.is_file():
                copied.append(copy_unique(source, destination))
        metadata_text = distribution.read_text("METADATA") or ""
        destination.mkdir(parents=True, exist_ok=True)
        metadata_path = destination / "PACKAGE-METADATA.txt"
        metadata_path.write_text(metadata_text, encoding="utf-8")
        if not copied:
            raise RuntimeError(f"No license file found for Python distribution {name}")
        records.append(
            {
                "ecosystem": "python",
                "name": name,
                "version": distribution.version,
                "files": [str(path.relative_to(output)).replace("\\", "/") for path in copied + [metadata_path]],
            }
        )

    runtime_candidates = (
        Path(sys.base_prefix) / "LICENSE.txt",
        Path(sys.base_prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "LICENSE.txt",
        Path(sys.base_prefix) / "Lib" / "LICENSE.txt",
        Path(sys.prefix) / "LICENSE.txt",
        Path(sys.executable).resolve().parent / "LICENSE.txt",
    )
    runtime_license = next((path for path in runtime_candidates if path.is_file()), None)
    if runtime_license is None:
        raise RuntimeError("The Python runtime LICENSE.txt was not found")
    copied_runtime = copy_unique(runtime_license, output / "Python" / "CPython")
    records.append(
        {
            "ecosystem": "python-runtime",
            "name": "CPython",
            "version": sys.version.split()[0],
            "files": [str(copied_runtime.relative_to(output)).replace("\\", "/")],
        }
    )
    return records


def collect_node(project_root: Path, output: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    modules = project_root / "frontend" / "node_modules"
    for name in NODE_PACKAGES:
        direct = modules / name
        if direct.exists():
            package = direct.resolve()
        else:
            candidates = sorted((modules / ".pnpm").glob(f"{name}@*/node_modules/{name}"))
            if len(candidates) != 1:
                raise RuntimeError(f"Expected one pnpm runtime package for {name}, got {len(candidates)}")
            package = candidates[0].resolve()
        package_json = package / "package.json"
        if not package_json.is_file():
            raise RuntimeError(f"Node runtime package is missing: {name}")
        metadata = json.loads(package_json.read_text(encoding="utf-8"))
        destination = output / "Frontend" / safe_name(name)
        copied = [
            copy_unique(path, destination)
            for path in sorted(package.iterdir())
            if path.is_file() and any(marker in path.name.lower() for marker in LICENSE_MARKERS)
        ]
        copied.append(copy_unique(package_json, destination))
        if len(copied) == 1:
            raise RuntimeError(f"No license file found for Node runtime package {name}")
        records.append(
            {
                "ecosystem": "node",
                "name": name,
                "version": metadata.get("version", "unknown"),
                "declaredLicense": metadata.get("license", "unknown"),
                "files": [str(path.relative_to(output)).replace("\\", "/") for path in copied],
            }
        )
    return records


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    project_root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == Path(output.anchor):
        raise RuntimeError("Refusing an unsafe legal-output root")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    records = collect_python(output)
    records.extend(collect_node(project_root, output))
    files = sorted(path for path in output.rglob("*") if path.is_file())
    manifest = {
        "product": "Quant Scenario Studio by LAI ZEYU",
        "author": "LAI ZEYU（来泽宇）",
        "components": records,
        "files": [
            {
                "path": str(path.relative_to(output)).replace("\\", "/"),
                "sha256": digest(path),
                "size": path.stat().st_size,
            }
            for path in files
        ],
    }
    (output / "RUNTIME_LICENSE_MANIFEST.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Collected runtime legal evidence for {len(records)} components")


if __name__ == "__main__":
    main()
