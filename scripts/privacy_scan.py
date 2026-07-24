#!/usr/bin/env python3
"""Fail when tracked files contain common private or secret material."""

from __future__ import annotations

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
    completed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
    )
    return [
        PROJECT_ROOT / value.decode("utf-8")
        for value in completed.stdout.split(b"\0")
        if value
    ]


def main() -> None:
    findings: list[str] = []
    for path in tracked_files():
        relative = path.relative_to(PROJECT_ROOT)
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            findings.append(f"{relative}: forbidden private/runtime file type")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                findings.append(f"{relative}:{line}: {label}")

    if findings:
        raise SystemExit(
            "Privacy scan failed:\n" + "\n".join(f"  - {item}" for item in findings)
        )
    print(f"Privacy scan passed: {len(tracked_files())} tracked files")


if __name__ == "__main__":
    main()
