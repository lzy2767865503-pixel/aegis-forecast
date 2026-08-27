#!/usr/bin/env python3
"""Fail a release when required bilingual authorship attribution drifts."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
AUTHOR = "LAI ZEYU（来泽宇）"
REQUIRED: dict[str, tuple[str, ...]] = {
    "README.md": (AUTHOR,),
    "SECURITY.md": (AUTHOR,),
    "THIRD_PARTY_NOTICES.md": (AUTHOR,),
    "pyproject.toml": (AUTHOR,),
    "frontend/package.json": (AUTHOR,),
    "frontend/index.html": (AUTHOR,),
    "frontend/src/views/SecondaryViews.jsx": (
        "export function AboutView",
        f"作者与发布者：<strong>{AUTHOR}</strong>",
    ),
    "desktop/windows/AegisForecast/Package.appxmanifest": (
        "<PublisherDisplayName>LAI ZEYU</PublisherDisplayName>",
    ),
    "desktop/windows/AegisForecast/MainWindow.xaml": (AUTHOR,),
    "desktop/windows/AegisForecast/MainWindow.xaml.cs": (
        "CapturePreviewAsync",
        "storeListingScreenshotPrivacyValidated = true",
    ),
    "desktop/windows/AegisForecast/AegisForecast.csproj": (
        f"<Authors>{AUTHOR}</Authors>",
        "<Company>LAI ZEYU</Company>",
        f"<Copyright>Copyright © 2026 {AUTHOR}</Copyright>",
    ),
    "docs/windows/STORE_LISTING.md": (
        "## English Store listing",
        "## 中文商店文案",
        AUTHOR,
    ),
    "docs/windows/PRIVACY_POLICY.md": (AUTHOR,),
    "docs/windows/CERTIFICATION_NOTES.md": (AUTHOR,),
    "docs/windows/RELEASE_CHECKLIST.md": (AUTHOR,),
    "docs/windows/LOCAL_VALIDATION.md": (AUTHOR,),
    "docs/windows/TWO_PASS_QA.md": (AUTHOR,),
    "docs/windows/PARTNER_CENTER_RUNBOOK.md": (AUTHOR,),
    "desktop/windows/AegisForecast/Assets/README.md": (AUTHOR,),
    "scripts/windows/generate-release-metadata.ps1": (AUTHOR,),
    "scripts/windows/backend-hashes.ps1": (AUTHOR,),
    "desktop/windows/AegisForecast/packages.lock.json": (
        '"Microsoft.WindowsAppSDK"',
        '"Microsoft.Web.WebView2"',
    ),
    "config/store_model_config.json": (
        '"strategy_profile": "TECHNICAL_RESEARCH_SNAPSHOT"',
        '"method": "stable-sha256-v1"',
        '"metrics_derived_from_shipped_rows": true',
    ),
}


def main() -> None:
    missing: list[str] = []
    for relative, tokens in REQUIRED.items():
        path = PROJECT_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            missing.append(f"{relative}: unavailable ({exc})")
            continue
        for token in tokens:
            if token not in text:
                missing.append(f"{relative}: missing {token!r}")
    store_copy = (PROJECT_ROOT / "docs/windows/STORE_LISTING.md").read_text(encoding="utf-8")
    try:
        english = store_copy.split("## English Store listing", 1)[1].split(
            "## 中文商店文案", 1
        )[0]
        chinese = store_copy.split("## 中文商店文案", 1)[1]
    except IndexError:
        missing.append("docs/windows/STORE_LISTING.md: EN/ZH sections are malformed")
    else:
        if AUTHOR not in english:
            missing.append("docs/windows/STORE_LISTING.md: English section missing exact author")
        if AUTHOR not in chinese:
            missing.append("docs/windows/STORE_LISTING.md: Chinese section missing exact author")

    manifest_path = PROJECT_ROOT / "desktop/windows/AegisForecast/Package.appxmanifest"
    try:
        manifest = ET.parse(manifest_path).getroot()
        namespace = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
        publisher = manifest.findtext("m:Properties/m:PublisherDisplayName", namespaces=namespace)
        identity = manifest.find("m:Identity", namespace)
        languages = {
            str(element.attrib.get("Language", "")).lower()
            for element in manifest.findall("m:Resources/m:Resource", namespace)
        }
        if publisher != "LAI ZEYU":
            missing.append(f"Package.appxmanifest: PublisherDisplayName must be exact 'LAI ZEYU', got {publisher!r}")
        if identity is None or identity.attrib.get("Publisher") != "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8":
            missing.append("Package.appxmanifest: technical Publisher must be this Partner Center account's exact value")
        if identity is None or identity.attrib.get("Name") != "LAIZEYU.QuantScenarioStudiobyLAIZEYU":
            missing.append("Package.appxmanifest: production Identity Name must match Store ID 9NWTH4KJX5GW")
        if languages != {"zh-cn"}:
            missing.append(f"Package.appxmanifest: Store v1 must declare only zh-cn, got {sorted(languages)}")
    except (ET.ParseError, OSError) as exc:
        missing.append(f"Package.appxmanifest: cannot parse identity ({exc})")

    keyword_section = store_copy.split("## Keywords", 1)[-1].split("## Required declarations", 1)[0]
    keywords = re.findall(r"`([^`]+)`", keyword_section)
    if len(keywords) != 7:
        missing.append(f"docs/windows/STORE_LISTING.md: expected exactly 7 keywords, got {len(keywords)}")
    if any(len(keyword) > 40 for keyword in keywords):
        missing.append("docs/windows/STORE_LISTING.md: every keyword must be at most 40 characters")
    if len({word.lower() for keyword in keywords for word in keyword.split()}) > 21:
        missing.append("docs/windows/STORE_LISTING.md: keywords exceed 21 unique words")

    spec_text = (PROJECT_ROOT / "packaging/windows/aegis_backend.spec").read_text(encoding="utf-8")
    if "store_model_config.json" not in spec_text or 'project_root / "config" / "model_config.json"' in spec_text:
        missing.append("packaging/windows/aegis_backend.spec: Store-only neutral model config boundary is invalid")
    if (PROJECT_ROOT / "config/t_trading.json").exists():
        missing.append("config/t_trading.json: execution configuration must not exist in the Store candidate")

    for legacy_name in (
        "backtest_summary.json",
        "source_ledger.csv",
        "walk_forward_predictions.csv",
    ):
        if (PROJECT_ROOT / "demo_data" / legacy_name).exists():
            missing.append(f"demo_data/{legacy_name}: legacy performance-claim artifact must not exist")

    workflow_text = (PROJECT_ROOT / ".github/workflows/windows-store.yml").read_text(encoding="utf-8")
    if workflow_text.count("runs-on: [self-hosted, windows, x64, wack-interactive]") != 1 or "matrix:" in workflow_text:
        missing.append("windows-store.yml: QA1, QA2, WACK1 and WACK2 must run sequentially in one active-interactive Windows job")
    if workflow_text.count("-WackRound") != 2:
        missing.append("windows-store.yml: exact same QA bytes must pass two complete WACK rounds")
    if "artifacts/public-evidence" in workflow_text or "artifacts/store-handoff/QuantScenarioStudio_1.5.0.0_x64_signed-dev.msix" in workflow_text:
        missing.append("windows-store.yml: signed QA/evidence bytes must not enter the private Store handoff")
    for token in (
        "AEGIS_STORE_PRODUCT_ID: 9NWTH4KJX5GW",
        "AEGIS_STORE_IDENTITY_NAME: ${{ vars.AEGIS_STORE_IDENTITY_NAME }}",
        "AEGIS_EXPECTED_STORE_IDENTITY_NAME: LAIZEYU.QuantScenarioStudiobyLAIZEYU",
        "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8",
        "wack-runner-policy.ps1",
        "prepare-store-handoff.ps1",
        "retain-private-store-handoff.ps1",
        "prepare-store-listing-screenshot.ps1",
        "-ValidatePublicOnly",
        "artifacts/store-listing-public/Quant-Scenario-Studio-Store-01-Home.png",
        "artifacts/store-listing-public/Quant-Scenario-Studio-Store-02-Scenarios.png",
        "artifacts/store-listing-public/Quant-Scenario-Studio-Store-03-Privacy.png",
        "artifacts/store-listing-public/Quant-Scenario-Studio-Store-04-About.png",
        "AEGIS_PRIVATE_STORE_HANDOFF_ROOT",
        "GITHUB_TRIGGERING_ACTOR",
    ):
        if token not in workflow_text:
            missing.append(f"windows-store.yml: missing strict technical identity/interactive token {token!r}")
    if workflow_text.count("actions/upload-artifact") != 1:
        missing.append("windows-store.yml: exactly one upload action is allowed, for four exact Store PNGs only")
    screenshot_upload = workflow_text.split(
        "Upload only four exact-candidate Store listing PNGs", 1
    )[-1].split("Remove the exact public screenshot staging", 1)[0]
    if ".msix" in screenshot_upload.lower() or "*" in screenshot_upload:
        missing.append("windows-store.yml: screenshot upload paths must be four exact PNGs and contain no package/wildcard")
    if "docs/assets/dashboard-demo.png" not in store_copy or "must never be submitted" not in store_copy:
        missing.append("docs/windows/STORE_LISTING.md: concept dashboard must be disclaimed as non-Store evidence")

    release_workflow = (PROJECT_ROOT / ".github/workflows/windows-github-release.yml").read_text(encoding="utf-8")
    for token in (
        "verify-github-signatures.ps1",
        "build-private-unsigned:",
        "retain-private-signing-handoff.ps1",
        "sign-private-no-checkout:",
        "ENVIRONMENT_ONLY_NO_ARGV",
        "credentialsPassedInArgv",
        "cngProviderBaselineRestored",
        "privateKeyBaselineRestored",
        "deleteKeyAttempted",
        "Signed same-byte portable lifecycle round 1",
        "Signed same-byte portable lifecycle round 2",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
        "<!-- aegis-publisher:${{ github.run_id }}:${{ github.run_attempt }} -->",
        "Restore-OwnedReleaseToPrivateDraft",
        "Exact-ID rollback immutable ownership proof failed",
        "publish-release:",
        "GITHUB_TRIGGERING_ACTOR",
    ):
        if token not in release_workflow:
            missing.append(f"windows-github-release.yml: missing trusted release token {token!r}")
    publisher = release_workflow.split("  publish-release:", 1)[-1]
    if ".msix" in release_workflow.lower() or "actions/checkout" in publisher or "secrets.AEGIS_GITHUB_RELEASE_TOKEN" in release_workflow:
        missing.append("windows-github-release.yml: no-checkout isolated publisher must expose only the tested portable ZIP/checksum and ephemeral job token")
    build_job = release_workflow.split("  build-private-unsigned:", 1)[-1].split("  sign-private-no-checkout:", 1)[0]
    signer_job = release_workflow.split("  sign-private-no-checkout:", 1)[-1].split("  verify-signed:", 1)[0]
    if "secrets." in build_job or "actions/upload-artifact" in build_job:
        missing.append("windows-github-release.yml: checkout/build job must receive no signer secret and upload no unsigned artifact")
    if "actions/checkout" in signer_job or "$PossibleOwned" in publisher:
        missing.append("windows-github-release.yml: signer must remain no-checkout and publisher must never adopt an ambiguous Release")

    truth_surface_paths = (
        PROJECT_ROOT / "frontend/src",
        PROJECT_ROOT / "README.md",
        PROJECT_ROOT / "docs/MODEL_CARD.md",
        PROJECT_ROOT / "docs/SELF_LEARNING.md",
        PROJECT_ROOT / "docs/windows/STORE_LISTING.md",
    )
    false_claim_tokens = (
        "walk-forward",
        "walk forward",
        "Walk-Forward",
        "Purged Walk",
        "504个交易日",
        "20bp",
        "样本外命中率",
        "样本外有效",
        "历史日线覆盖",
    )
    truth_files: list[Path] = []
    for path in truth_surface_paths:
        truth_files.extend(path.rglob("*")) if path.is_dir() else truth_files.append(path)
    for path in truth_files:
        if not path.is_file() or path.suffix not in {".md", ".js", ".jsx", ".html"}:
            continue
        text = path.read_text(encoding="utf-8")
        for token in false_claim_tokens:
            if token.lower() in text.lower():
                missing.append(f"{path.relative_to(PROJECT_ROOT)}: unsupported methodology claim {token!r}")

    universe_text = (PROJECT_ROOT / "config/us_universe.json").read_text(encoding="utf-8")
    for token in ('"snapshot_date": "2026-08-26"', '"ticker": "SPCX"'):
        if token not in universe_text:
            missing.append(f"config/us_universe.json: missing official snapshot token {token!r}")
    if '"ticker": "EA"' in universe_text:
        missing.append("config/us_universe.json: stale EA constituent remains")

    user_surface_paths = (
        PROJECT_ROOT / "frontend/src",
        PROJECT_ROOT / "README.md",
        PROJECT_ROOT / "docs/windows/STORE_LISTING.md",
        PROJECT_ROOT / "docs/windows/PRIVACY_POLICY.md",
    )
    forbidden_surface_tokens = (
        "Moomoo",
        "OpenD",
        "买入计划",
        "卖出计划",
        "止盈一",
        "每轮仓位",
        "单股做 T",
        "Nasdaq-100当前成分",
    )
    files: list[Path] = []
    for path in user_surface_paths:
        files.extend(path.rglob("*")) if path.is_dir() else files.append(path)
    for path in files:
        if not path.is_file() or path.suffix not in {".md", ".js", ".jsx", ".html"}:
            continue
        text = path.read_text(encoding="utf-8")
        for token in forbidden_surface_tokens:
            if token in text:
                missing.append(f"{path.relative_to(PROJECT_ROOT)}: forbidden Store surface token {token!r}")
    if missing:
        raise SystemExit("Attribution gate failed:\n  - " + "\n  - ".join(missing))
    print(f"Attribution gate passed: {AUTHOR} present in {len(REQUIRED)} required surfaces")


if __name__ == "__main__":
    main()
