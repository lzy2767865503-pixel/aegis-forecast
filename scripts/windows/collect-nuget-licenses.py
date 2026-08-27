#!/usr/bin/env python3
"""Collect NuGet license declarations and bundled license texts from the lock file."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path


MARKERS = ("license", "copying", "notice", "authors")


def safe_name(value: str) -> str:
    return "".join(character if character.isalnum() or character in "._-" else "_" for character in value)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--nuget-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text(encoding="utf-8-sig"))
    packages: dict[str, str] = {}
    for target in lock.get("dependencies", {}).values():
        for name, details in target.items():
            if details.get("type") in {"Direct", "Transitive"}:
                packages[name] = details["resolved"]
    if not packages:
        raise RuntimeError("NuGet lock contains no resolved packages")

    output = args.output.resolve()
    if output == Path(output.anchor):
        raise RuntimeError("Refusing an unsafe NuGet legal-output root")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    records: list[dict[str, object]] = []
    for name, version in sorted(packages.items(), key=lambda item: item[0].lower()):
        package_root = args.nuget_root / name.lower() / version.lower()
        if not package_root.is_dir():
            raise RuntimeError(f"Restored NuGet package is missing: {name} {version}")
        destination = output / safe_name(f"{name}-{version}")
        destination.mkdir()
        nuspecs = sorted(package_root.glob("*.nuspec"))
        if len(nuspecs) != 1:
            raise RuntimeError(f"Expected one nuspec for {name} {version}, got {len(nuspecs)}")
        copied: list[Path] = []
        for source in sorted(path for path in package_root.rglob("*") if path.is_file()):
            if source == nuspecs[0] or any(marker in source.name.lower() for marker in MARKERS):
                target = destination / safe_name(source.name)
                if target.exists() and target.read_bytes() != source.read_bytes():
                    target = destination / f"{target.stem}-{sha256(source)[:12]}{target.suffix}"
                shutil.copy2(source, target)
                copied.append(target)

        root = ET.parse(nuspecs[0]).getroot()
        metadata = next((element for element in root.iter() if element.tag.rsplit("}", 1)[-1] == "metadata"), None)
        license_values: list[str] = []
        if metadata is not None:
            for child in metadata:
                local = child.tag.rsplit("}", 1)[-1]
                if local in {"license", "licenseUrl", "projectUrl", "copyright"} and (child.text or "").strip():
                    license_values.append(f"{local}: {(child.text or '').strip()}")
        if not license_values:
            raise RuntimeError(
                f"NuGet package has no non-empty upstream license declaration: {name} {version}"
            )
        declaration = destination / "UPSTREAM-LICENSE-DECLARATION.txt"
        declaration.write_text("\n".join(license_values) + "\n", encoding="utf-8")
        copied.append(declaration)
        empty_files = [path.name for path in copied if path.stat().st_size <= 0]
        if empty_files:
            raise RuntimeError(
                f"NuGet legal evidence contains empty files for {name} {version}: {empty_files}"
            )
        records.append(
            {
                "ecosystem": "nuget",
                "name": name,
                "version": version,
                "files": [str(path.relative_to(output)).replace("\\", "/") for path in copied],
            }
        )

    manifest = {
        "product": "Quant Scenario Studio by LAI ZEYU",
        "author": "LAI ZEYU（来泽宇）",
        "components": records,
        "files": [
            {
                "path": str(path.relative_to(output)).replace("\\", "/"),
                "sha256": sha256(path),
                "size": path.stat().st_size,
            }
            for path in sorted(path for path in output.rglob("*") if path.is_file())
        ],
    }
    (output / "NUGET_LICENSE_MANIFEST.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Collected NuGet legal evidence for {len(records)} locked packages")


if __name__ == "__main__":
    main()
