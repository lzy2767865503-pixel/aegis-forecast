#!/usr/bin/env python3
"""Fail when tracked files contain common private or secret material."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_SUFFIXES = {
    ".db",
    ".docx",
    ".key",
    ".log",
    ".p12",
    ".pdf",
    ".pem",
    ".sqlite",
}
PATTERNS = {
    "local macOS home path": re.compile(r"/Users/[A-Za-z0-9._-]+/"),
    "local Linux home path": re.compile(r"/home/[A-Za-z0-9._-]+/"),
    "email address": re.compile(
        r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
    ),
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(r"gh[opsu]_[A-Za-z0-9]{20,}"),
    "OpenAI key": re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{20,}"),
    "AWS access key": re.compile(r"AKIA[0-9A-Z]{16}"),
}


def tracked_files() -> list[Path]:
    """Return tracked and untracked release-candidate files, excluding ignores."""

    completed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
    )
    return [
        PROJECT_ROOT / value.decode("utf-8")
        for value in completed.stdout.split(b"\0")
        if value
    ]


def historical_blobs() -> list[tuple[str, str, str]]:
    """Return unique reachable text blobs as (object id, path, text)."""

    completed = subprocess.run(
        ["git", "rev-list", "--objects", "--all"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    objects: list[tuple[str, str]] = []
    seen: set[str] = set()
    for raw_line in completed.stdout.splitlines():
        object_id, separator, path = raw_line.partition(" ")
        if not separator or object_id in seen:
            continue
        seen.add(object_id)
        objects.append((object_id, path))

    # Query object type/size in one Git process. The previous one-process-per-
    # object implementation took minutes and could exhaust Windows CI process
    # pipes on repositories with ordinary history depth.
    metadata = subprocess.run(
        ["git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        cwd=PROJECT_ROOT,
        check=True,
        input="".join(f"{object_id}\n" for object_id, _ in objects),
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    eligible: list[tuple[str, str]] = []
    for (object_id, path), line in zip(objects, metadata, strict=True):
        fields = line.split()
        if len(fields) == 3 and fields[1] == "blob" and int(fields[2]) <= 2_000_000:
            eligible.append((object_id, path))

    blobs: list[tuple[str, str, str]] = []
    process = subprocess.Popen(
        ["git", "cat-file", "--batch"],
        cwd=PROJECT_ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert process.stdin is not None and process.stdout is not None
    try:
        for object_id, path in eligible:
            process.stdin.write(f"{object_id}\n".encode("ascii"))
            process.stdin.flush()
            header = process.stdout.readline().decode("ascii").strip().split()
            if len(header) != 3 or header[1] != "blob":
                raise RuntimeError(f"Unexpected git cat-file response for {object_id}")
            content = process.stdout.read(int(header[2]))
            if process.stdout.read(1) != b"\n":
                raise RuntimeError(f"Truncated git object response for {object_id}")
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                continue
            blobs.append((object_id, path, text))
    finally:
        process.stdin.close()
        process.wait(timeout=30)
    return blobs


def indexed_object_ids() -> set[str]:
    completed = subprocess.run(
        ["git", "ls-files", "-s", "-z"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
    )
    object_ids: set[str] = set()
    for record in completed.stdout.split(b"\0"):
        if not record:
            continue
        metadata, _, _ = record.partition(b"\t")
        fields = metadata.split()
        if len(fields) >= 2:
            object_ids.add(fields[1].decode("ascii"))
    return object_ids


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--history", action="store_true")
    args = parser.parse_args()
    findings: list[str] = []
    for path in tracked_files():
        relative = path.relative_to(PROJECT_ROOT)
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            findings.append(f"{relative}: forbidden private/runtime file type")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            # A tracked file deleted in the working tree remains in the index
            # until commit; it is not part of the release candidate bytes.
            continue
        except UnicodeDecodeError:
            continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                findings.append(f"{relative}:{line}: {label}")

    if args.history:
        current_objects = indexed_object_ids()
        for object_id, path, text in historical_blobs():
            if object_id in current_objects:
                continue
            suffix = Path(path).suffix.lower()
            if suffix in FORBIDDEN_SUFFIXES:
                findings.append(f"history:{object_id[:12]}:{path}: forbidden private/runtime file type")
                continue
            for label, pattern in PATTERNS.items():
                match = pattern.search(text)
                if match:
                    line = text.count("\n", 0, match.start()) + 1
                    findings.append(f"history:{object_id[:12]}:{path}:{line}: {label}")

    if findings:
        raise SystemExit(
            "Privacy scan failed:\n" + "\n".join(f"  - {item}" for item in findings)
        )
    scope = (
        "candidate files and reachable Git history"
        if args.history
        else "candidate files"
    )
    print(f"Privacy scan passed: {len(tracked_files())} {scope}")


if __name__ == "__main__":
    main()
