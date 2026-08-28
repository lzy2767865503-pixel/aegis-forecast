from __future__ import annotations

import csv
import json
import os
import sqlite3
import subprocess
import tempfile
import threading
import unittest
import xml.etree.ElementTree as ET
from contextlib import closing
from http.client import HTTPConnection
from pathlib import Path
from aegis_quant.audit import AuditLedger
from aegis_quant.autonomy import AutonomyMonitor
from aegis_quant.environment import load_project_env
from aegis_quant.integrity import ScenarioIntegrityRegistry
from aegis_quant.nasdaq100_universe import load_universe_config
from aegis_quant.paths import DATA_ROOT_MARKER, clear_local_data, ensure_directories
from aegis_quant.privacy import PrivacyPreferences
from aegis_quant.server import (
    MAX_BODY_BYTES,
    AegisHandler,
    AegisHTTPServer,
    _process_is_alive,
    simulation_execution_enabled,
)
from aegis_quant.service import AegisService, DATA_MODE, DEMO_MODEL_ROOT, derive_scenario_metrics


class UniverseTests(unittest.TestCase):
    def test_nasdaq100_config_uses_unique_official_security_codes(self) -> None:
        config = load_universe_config()
        codes = [row["code"] for row in config["securities"]]
        self.assertGreaterEqual(len(codes), 90)
        self.assertLessEqual(len(codes), 110)
        self.assertEqual(len(codes), len(set(codes)))
        self.assertTrue(all(code.startswith("US.") for code in codes))
        self.assertEqual(config["index"], "NASDAQ-100")
        self.assertEqual(config["snapshot_date"], "2026-08-26")
        self.assertEqual(config["constituent_as_of"], "Aug 26, 2026")
        self.assertEqual(len(codes), 102)
        self.assertIn("US.SPCX", codes)
        self.assertNotIn("US.EA", codes)

    def test_store_profile_is_neutral_research_snapshot(self) -> None:
        path = Path(__file__).resolve().parents[1] / "config" / "store_model_config.json"
        config = json.loads(path.read_text(encoding="utf-8"))
        gates = config["gates"]
        self.assertEqual(config["strategy_profile"], "TECHNICAL_RESEARCH_SNAPSHOT")
        self.assertLess(float(gates["minimum_scenario_up_score"]), 0.60)
        self.assertTrue(gates["require_trend_confirmation"])
        self.assertTrue(gates["require_relative_strength_confirmation"])
        self.assertLessEqual(int(gates["maximum_names"]), 5)
        self.assertLessEqual(
            int(config["integrity"]["maximum_score_threshold"]),
            int(gates["default_score_threshold"]),
        )
        serialized = json.dumps(config).lower()
        for token in ("holding", "position", "take_profit", "stop_loss", "t_trading"):
            self.assertNotIn(token, serialized)

    def test_bundled_artifacts_are_synthetic_and_cover_the_demo_universe(self) -> None:
        manifest = json.loads(
            (DEMO_MODEL_ROOT / "demo_manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(DATA_MODE, "DETERMINISTIC_SYNTHETIC_SCENARIO")
        self.assertEqual(manifest["kind"], "DETERMINISTIC_SYNTHETIC_SCENARIO")
        self.assertFalse(manifest["containsBrokerData"])
        self.assertFalse(manifest["containsPersonalData"])
        self.assertFalse(manifest["containsMarketObservations"])
        self.assertFalse(manifest["containsTrainingOutput"])
        self.assertGreaterEqual(int(manifest["securityCount"]), 90)

    def test_all_scenario_metrics_are_recomputed_from_shipped_rows(self) -> None:
        with (DEMO_MODEL_ROOT / "illustrative_scenario_outcomes.csv").open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            rows = list(csv.DictReader(handle))
        derived = derive_scenario_metrics(rows)
        shipped = json.loads(
            (DEMO_MODEL_ROOT / "scenario_metrics.json").read_text(encoding="utf-8")
        )
        self.assertEqual(len(rows), 300)
        self.assertEqual(derived, shipped)
        self.assertEqual(sum(bucket["sample_count"] for bucket in derived["buckets"]), 300)


class AuditAndRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.database = Path(self.tempdir.name) / "test.db"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_hash_chain_detects_tampering(self) -> None:
        ledger = AuditLedger(self.database)
        ledger.append("TEST", "ONE", {"value": 1}, "trace-1")
        ledger.append("TEST", "TWO", {"value": 2}, "trace-2")
        self.assertTrue(ledger.verify()["valid"])
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    "UPDATE audit_events SET payload_json='{}' WHERE sequence=1"
                )
        self.assertFalse(ledger.verify()["valid"])

    def test_database_contexts_close_connections(self) -> None:
        ledger = AuditLedger(self.database)
        with ledger.connect() as audit_connection:
            self.assertEqual(
                audit_connection.execute("SELECT COUNT(*) FROM audit_events").fetchone()[0],
                0,
            )
        with self.assertRaises(sqlite3.ProgrammingError):
            audit_connection.execute("SELECT 1")

        registry = ScenarioIntegrityRegistry(self.database, audit=ledger)
        with registry.connect() as integrity_connection:
            self.assertEqual(
                integrity_connection.execute(
                    "SELECT COUNT(*) FROM scenario_integrity_checks"
                ).fetchone()[0],
                0,
            )
        with self.assertRaises(sqlite3.ProgrammingError):
            integrity_connection.execute("SELECT 1")

    def test_store_simulation_execution_cannot_be_enabled_by_environment(self) -> None:
        previous = os.environ.pop("AEGIS_ENABLE_SIMULATION_EXECUTION", None)
        try:
            self.assertFalse(simulation_execution_enabled())
            os.environ["AEGIS_ENABLE_SIMULATION_EXECUTION"] = "1"
            self.assertFalse(simulation_execution_enabled())
        finally:
            if previous is None:
                os.environ.pop("AEGIS_ENABLE_SIMULATION_EXECUTION", None)
            else:
                os.environ["AEGIS_ENABLE_SIMULATION_EXECUTION"] = previous

    def test_parent_process_probe_is_read_only_and_detects_current_process(self) -> None:
        self.assertTrue(_process_is_alive(os.getpid()))
        self.assertFalse(_process_is_alive(2_147_483_647))

    def test_dotenv_loader_is_safe_and_preserves_exported_values(self) -> None:
        preserved_key = "AEGIS_TEST_PRESERVED"
        loaded_key = "AEGIS_TEST_LOADED"
        quoted_key = "AEGIS_TEST_QUOTED"
        previous = {
            key: os.environ.get(key)
            for key in (preserved_key, loaded_key, quoted_key)
        }
        try:
            os.environ[preserved_key] = "from-process"
            os.environ.pop(loaded_key, None)
            os.environ.pop(quoted_key, None)
            with tempfile.TemporaryDirectory() as tempdir:
                env_path = Path(tempdir) / ".env"
                env_path.write_text(
                    "\n".join(
                        [
                            f"{preserved_key}=from-file",
                            f"export {loaded_key}=enabled # documented comment",
                            f'{quoted_key}="value with spaces" # quoted comment',
                        ]
                    )
                    + "\n",
                    encoding="utf-8",
                )
                loaded = load_project_env(env_path)

            self.assertEqual(os.environ[preserved_key], "from-process")
            self.assertEqual(os.environ[loaded_key], "enabled")
            self.assertEqual(os.environ[quoted_key], "value with spaces")
            self.assertNotIn(preserved_key, loaded)
            self.assertEqual(loaded[loaded_key], "enabled")
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_autonomy_heartbeat_is_persisted_without_a_browser(self) -> None:
        state_path = Path(self.tempdir.name) / "autonomy.json"
        monitor = AutonomyMonitor(state_path)
        snapshot = monitor.snapshot()
        persisted = json.loads(state_path.read_text(encoding="utf-8"))
        self.assertTrue(snapshot["healthy"])
        self.assertFalse(snapshot["schedulerRegistered"])
        self.assertFalse(snapshot["executionRegistered"])
        self.assertEqual(persisted["launchCount"], 1)

        monitor.record_heartbeat()
        heartbeat = monitor.snapshot()
        self.assertTrue(heartbeat["healthy"])
        self.assertFalse(snapshot["independence"]["requiresCodex"])
        self.assertTrue(snapshot["independence"]["requiresWindowsAwake"])
        self.assertNotIn("requiresOpenD", snapshot["independence"])
        self.assertEqual(snapshot["schedulerIntervalSeconds"], 0)

    def test_privacy_preferences_store_only_research_notice(self) -> None:
        path = Path(self.tempdir.name) / "settings" / "privacy.json"
        preferences = PrivacyPreferences(path)
        self.assertEqual(
            set(preferences.status()),
            {"researchNoticeAccepted", "policyVersion", "updatedAt"},
        )
        updated = preferences.update({"researchNoticeAccepted": True})
        self.assertTrue(updated["researchNoticeAccepted"])
        with self.assertRaises(ValueError):
            preferences.update({"brokerDataConsent": True})

    def test_local_data_delete_preserves_unrelated_sentinels(self) -> None:
        root = Path(self.tempdir.name) / "LocalState"
        binding = "TEST:local-data-delete-unit"
        ensure_directories(root, binding=binding)
        (root / "runtime" / "engine_state.json").write_text("{}", encoding="utf-8")
        (root / "operational.db").write_bytes(b"app-owned")
        (root / "keep-me.txt").write_text("sentinel", encoding="utf-8")
        (root / "unrelated-project").mkdir()
        (root / "unrelated-project" / "data.txt").write_text("keep", encoding="utf-8")

        result = clear_local_data(root, binding=binding)

        self.assertIn("runtime", result["removed"])
        self.assertIn("operational.db", result["removed"])
        self.assertEqual((root / "keep-me.txt").read_text(encoding="utf-8"), "sentinel")
        self.assertEqual(
            (root / "unrelated-project" / "data.txt").read_text(encoding="utf-8"),
            "keep",
        )
        self.assertTrue((root / "runtime").is_dir())
        self.assertTrue((root / DATA_ROOT_MARKER).is_file())

    def test_local_data_delete_refuses_an_unbound_root(self) -> None:
        root = Path(self.tempdir.name) / "unbound"
        (root / "runtime").mkdir(parents=True)
        with self.assertRaises(RuntimeError):
            clear_local_data(root, binding="TEST:unbound-unit")


class IntegrityTests(unittest.TestCase):
    def test_local_integrity_check_cannot_train_or_replace_models(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            database = Path(tempdir) / "integrity.db"
            registry = ScenarioIntegrityRegistry(database)
            result = registry.run_cycle()
            self.assertEqual(result["lastCheck"]["status"], "ILLUSTRATIVE_FILES_VERIFIED")
            self.assertFalse(result["replacementPolicy"]["trainsModels"])
            self.assertFalse(result["replacementPolicy"]["comparesModels"])
            self.assertFalse(result["replacementPolicy"]["automaticReplacement"])

class StorePackageBoundaryTests(unittest.TestCase):
    def test_store_spec_excludes_account_and_execution_modules(self) -> None:
        spec = (
            Path(__file__).resolve().parents[1]
            / "packaging"
            / "windows"
            / "aegis_backend.spec"
        ).read_text(encoding="utf-8")
        for name in (
            "moomoo",
            "futu",
            "aegis_quant.moomoo_gateway",
            "aegis_quant.pnl_ledger",
            "aegis_quant.t_trader",
            "aegis_quant.us_pipeline",
        ):
            self.assertIn(f'"{name}"', spec)
        self.assertIn("store_model_config.json", spec)
        self.assertNotIn('project_root / "config" / "model_config.json"', spec)
        self.assertNotIn("collect_data_files", spec)

    def test_store_candidate_has_only_neutral_read_only_configuration(self) -> None:
        root = Path(__file__).resolve().parents[1]
        self.assertFalse((root / "config" / "t_trading.json").exists())
        system = json.loads((root / "config" / "system.json").read_text(encoding="utf-8"))
        self.assertEqual(
            system["capability_boundary"],
            {
                "read_only_research": True,
                "external_connections": False,
                "background_tasks": False,
            },
        )
        system_text = json.dumps(system).lower()
        for token in ("broker", "account", "order", "position", "t_trading"):
            self.assertNotIn(token, system_text)

    def test_windows_workflow_keeps_candidate_bytes_private_and_sequential(self) -> None:
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/windows-store.yml").read_text(encoding="utf-8")
        self.assertEqual(
            workflow.count("runs-on: [self-hosted, windows, x64, wack-interactive]"), 1
        )
        self.assertNotIn("matrix:", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("python-version: 3.13.14", workflow)
        self.assertIn("Native QA round 1", workflow)
        self.assertIn("Native QA round 2", workflow)
        self.assertEqual(workflow.count("Strict WACK round"), 2)
        self.assertEqual(workflow.count("-WackRound"), 2)
        self.assertIn("prepare-store-handoff.ps1", workflow)
        self.assertEqual(workflow.count("actions/upload-artifact"), 1)
        self.assertIn("prepare-store-listing-screenshot.ps1", workflow)
        self.assertEqual(workflow.count("artifacts/store-listing-public/Quant-Scenario-Studio-Store-0"), 4)
        screenshot_upload = workflow.split("Upload only four exact-candidate Store listing PNGs", 1)[1]
        self.assertNotIn(".msix", screenshot_upload.lower())
        self.assertIn("-ValidatePublicOnly", workflow)
        self.assertLess(
            workflow.index("-ValidatePublicOnly"),
            workflow.index("Upload only four exact-candidate Store listing PNGs"),
        )
        self.assertIn("retain-private-store-handoff.ps1", workflow)
        self.assertIn("AEGIS_PRIVATE_STORE_HANDOFF_ROOT", workflow)
        self.assertNotIn(
            "artifacts/store-handoff/QuantScenarioStudio_1.5.0.0_x64_signed-dev.msix",
            workflow,
        )
        self.assertIn('AEGIS_MAIN_RULESET_ID: "21633557"', workflow)
        self.assertIn("AEGIS_STORE_IDENTITY_NAME", workflow)
        self.assertIn("AEGIS_STORE_PRODUCT_ID: 9NWTH4KJX5GW", workflow)
        self.assertIn("AEGIS_STORE_IDENTITY_NAME: ${{ vars.AEGIS_STORE_IDENTITY_NAME }}", workflow)
        self.assertIn("AEGIS_EXPECTED_STORE_IDENTITY_NAME: LAIZEYU.QuantScenarioStudiobyLAIZEYU", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertIn("github.actor == 'lzy2767865503-pixel'", workflow)
        self.assertIn("github.triggering_actor == 'lzy2767865503-pixel'", workflow)
        self.assertIn("GITHUB_TRIGGERING_ACTOR", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("AEGIS_APPROVED_WACK_FILE_VERSION", workflow)
        for protected_wack_value in (
            "AEGIS_APPROVED_WACK_SHA256",
            "AEGIS_APPROVED_WACK_SIGNER_SUBJECT",
            "AEGIS_APPROVED_WACK_SIGNER_THUMBPRINT",
            "AEGIS_APPROVED_WACK_TEST_COUNT",
            "AEGIS_APPROVED_WACK_TEST_INVENTORY_SHA256",
        ):
            self.assertIn(protected_wack_value, workflow)
        self.assertIn("Remove-Item -LiteralPath $ExactPath -DeleteKey", (root / "scripts/windows/remove-development-certificate.ps1").read_text(encoding="utf-8"))
        self.assertIn("postCleanupCngKeyFiles", workflow)
        self.assertIn("required_status_checks", workflow)
        self.assertIn("integration_id -ne 15368", workflow)
        self.assertIn("'verify (3.10)', 'verify (3.12)'", workflow)
        self.assertLess(
            workflow.index("Require trusted main, reserved Partner identity"),
            workflow.index("actions/setup-python@"),
        )
        runner_policy = (root / "scripts/windows/wack-runner-policy.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("[Environment]::UserInteractive", runner_policy)
        self.assertIn("WindowsBuiltInRole]::Administrator", runner_policy)
        manifest_root = ET.parse(
            root / "desktop/windows/AegisForecast/Package.appxmanifest"
        ).getroot()
        ns = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
        identity = manifest_root.find("m:Identity", ns)
        self.assertIsNotNone(identity)
        assert identity is not None
        self.assertEqual(identity.attrib["Name"], "LAIZEYU.QuantScenarioStudiobyLAIZEYU")
        self.assertEqual(
            identity.attrib["Publisher"],
            "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8",
        )
        self.assertEqual(
            manifest_root.findtext("m:Properties/m:PublisherDisplayName", namespaces=ns),
            "LAI ZEYU",
        )
        release = (root / ".github/workflows/windows-github-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            release,
        )
        self.assertIn(
            "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
            release,
        )
        self.assertNotIn(".msix", release.lower())
        self.assertEqual(release.count("Signed same-byte portable lifecycle round"), 2)
        self.assertIn("persist-credentials: false", release)
        self.assertIn("permissions:\n  contents: read", release)
        self.assertIn("build-private-unsigned:", release)
        self.assertIn("sign-private-no-checkout:", release)
        self.assertIn("verify-signed:", release)
        self.assertIn("publish-release:", release)
        build_job = release.split("  build-private-unsigned:", 1)[1].split(
            "  sign-private-no-checkout:", 1
        )[0]
        signer_job = release.split("  sign-private-no-checkout:", 1)[1].split(
            "  verify-signed:", 1
        )[0]
        self.assertNotIn("secrets.", build_job)
        self.assertNotIn("actions/upload-artifact", build_job)
        self.assertIn("retain-private-signing-handoff.ps1", build_job)
        self.assertNotIn("actions/checkout", signer_job)
        self.assertIn("ENVIRONMENT_ONLY_NO_ARGV", signer_job)
        self.assertIn("credentialsPassedInArgv", signer_job)
        self.assertIn("cngProviderBaselineRestored", signer_job)
        self.assertIn("privateKeyBaselineRestored", signer_job)
        self.assertIn("deleteKeyAttempted", signer_job)
        self.assertIn("deleteKeySucceeded", signer_job)
        self.assertIn("machineGuidSha256", signer_job)
        self.assertIn("signerRunnerName", signer_job)
        self.assertIn("signer-vault", signer_job)
        self.assertIn("[IO.Directory]::Move($IngressRun, $VaultClaiming)", signer_job)
        self.assertIn("[IO.FileShare]::Read", signer_job)
        self.assertIn("archiveEntryInventorySha256", signer_job)
        publisher = release.split("  publish-release:", 1)[1]
        self.assertNotIn("actions/checkout", publisher)
        self.assertIn("contents: write", publisher)
        self.assertIn("${{ github.token }}", release)
        self.assertNotIn("secrets.AEGIS_GITHUB_RELEASE_TOKEN", release)
        self.assertIn("<!-- aegis-publisher:${{ github.run_id }}:${{ github.run_attempt }} -->", release)
        self.assertIn('"$ApiBase/releases/$OwnedReleaseId"', release)
        self.assertIn("Restore-OwnedReleaseToPrivateDraft", release)
        self.assertIn("Exact-ID rollback immutable ownership proof failed", release)
        self.assertIn("OwnedReleaseNodeId", release)
        self.assertIn("one successful HTTP 201 response", publisher)
        self.assertIn("no Release lookup, adoption, PATCH, upload or", publisher)
        self.assertNotIn("$PossibleOwned", publisher)
        self.assertIn("Exact-ID asset upload", release)
        self.assertIn("-Phase 'postpublish'", release)
        self.assertIn("PE must have exactly one primary signer", publisher)
        self.assertIn("SHA-256/RFC3161 signature index 0", publisher)
        self.assertIn("1.3.6.1.5.5.7.3.8", publisher)
        self.assertIn('AEGIS_MAIN_RULESET_ID: "21633557"', release)
        self.assertIn("github.triggering_actor == 'lzy2767865503-pixel'", release)
        self.assertIn("GITHUB_TRIGGERING_ACTOR", release)
        self.assertIn("github.ref == 'refs/heads/main'", release)
        self.assertIn("Assert-TagOnProtectedMain", publisher)
        self.assertIn("Assert-RemoteAssets", publisher)
        self.assertGreaterEqual(release.count("required_status_checks"), 3)
        self.assertGreaterEqual(release.count("integration_id -ne 15368"), 3)
        self.assertGreaterEqual(release.count("verify (3.10)|verify (3.12)"), 3)

        hosted = (root / ".github/workflows/windows-hosted-candidate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("runs-on: windows-2025", hosted)
        self.assertIn("Build one MSIX and run two native lifecycle passes", hosted)
        self.assertIn("github.event.pull_request.head.sha || github.sha", hosted)
        for candidate_workflow in (workflow, hosted):
            self.assertIn("Microsoft Software Key Storage Provider", candidate_workflow)
            self.assertIn("-KeyProtection None", candidate_workflow)
            self.assertNotIn("-KeySpec ", candidate_workflow)
            self.assertIn("X509Store]::new('TrustedPeople', 'LocalMachine')", candidate_workflow)
            self.assertNotIn("-addstore Root", candidate_workflow)
            self.assertIn("Remove build-only trust before independent native QA", candidate_workflow)
        self.assertEqual(hosted.count("./scripts/windows/verify-native.ps1"), 2)
        self.assertIn("-QaRound 1", hosted)
        self.assertIn("-QaRound 2", hosted)
        self.assertIn("generate-hosted-candidate-evidence.ps1", hosted)
        self.assertIn("software binary or certificate", hosted)
        self.assertIn("retention-days: 1", hosted)
        self.assertEqual(hosted.count("actions/upload-artifact@"), 2)
        self.assertIn("Require exact protected main for a Partner Center artifact dispatch", hosted)
        self.assertIn("$Ruleset.PSObject.Properties['bypass_actors']", hosted)
        self.assertIn("$BypassActorCount -ne 0", hosted)
        self.assertIn("$RulesetUpdatedAt -ne 1787819788625", hosted)
        self.assertIn("prepare-hosted-store-upload.ps1", hosted)
        self.assertIn("aegis-partner-center-upload-${{ github.sha }}", hosted)
        self.assertIn("path: ${{ runner.temp }}/aegis-partner-center-upload", hosted)
        self.assertIn("UNSIGNED_FOR_PARTNER_CENTER", hosted)
        self.assertIn("'.sha256'", hosted)
        partner_upload = hosted.split(
            "Upload the exact protected-main unsigned Partner Center bundle for one day",
            1,
        )[1].split(
            "Remove the exact protected-main Partner Center upload staging",
            1,
        )[0]
        self.assertNotIn("signed-dev", partner_upload)
        self.assertNotIn(".cer", partner_upload.lower())
        self.assertNotIn(".pfx", partner_upload.lower())
        self.assertNotIn("contents: write", hosted)

        hosted_evidence = (
            root / "scripts/windows/generate-hosted-candidate-evidence.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("nativeQaPasses = 2", hosted_evidence)
        self.assertIn("independentLaunchNonces = 2", hosted_evidence)
        self.assertIn("softwareBinariesUploaded = $false", hosted_evidence)
        self.assertIn("developmentCertificateUploaded = $false", hosted_evidence)
        self.assertIn("packageAbsentAfterUninstall", hosted_evidence)
        self.assertIn("sidecarExitedViaParentWatchdog", hosted_evidence)
        hosted_upload = (
            root / "scripts/windows/prepare-hosted-store-upload.ps1"
        ).read_text(encoding="utf-8")
        for token in (
            "9NWTH4KJX5GW",
            "LAIZEYU.QuantScenarioStudiobyLAIZEYU",
            "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8",
            "ToLowerInvariant()",
            '$Languages.Count -ne 1 -or $Languages[0] -cne "zh-cn"',
            "Microsoft SPDX SBOM generation",
            "Microsoft SPDX SHA-256 sidecar does not match",
            '".sha256"',
            "staticValidationPasses = 2",
            "runtimeLifecyclePasses = 2",
            'submissionSignatureStatus = "UNSIGNED_FOR_PARTNER_CENTER"',
            'submissionStatus = "NOT_SUBMITTED"',
            'certificationStatus = "NOT_CERTIFIED"',
        ):
            self.assertIn(token, hosted_upload)
        self.assertNotIn("signedDevelopmentQaPackageFile -Destination", hosted_upload)

    def test_windows_scripts_fail_closed_and_embed_source_hash_once(self) -> None:
        root = Path(__file__).resolve().parents[1]
        policy_result = subprocess.run(
            ["pwsh", "-NoLogo", "-NoProfile", "-File", "scripts/windows/policy-selftest.ps1"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(policy_result.returncode, 0, policy_result.stdout + policy_result.stderr)
        self.assertIn("Behavioral policy self-test passed", policy_result.stdout)
        build = (root / "scripts/windows/build-msix.ps1").read_text(encoding="utf-8")
        self.assertIn('"-p:InformationalVersion=1.5.0+$SourceCommit"', build)
        self.assertIn('"-p:IncludeSourceRevisionInInformationalVersion=false"', build)
        self.assertIn('"LAIZEYU.QuantScenarioStudiobyLAIZEYU"', build)
        self.assertNotIn("__PARTNER_CENTER_IDENTITY_NAME__", build)
        self.assertIn("A5F91D0A-30C6-48EE-944F-B767FA872BE8", build)
        native = (root / "scripts/windows/verify-native.ps1").read_text(encoding="utf-8")
        self.assertIn("Fail-closed: a package with the candidate identity already exists", native)
        self.assertIn("sidecarExitedViaParentWatchdog", native)
        self.assertIn("packagedBackendHashManifestVerified", native)
        self.assertIn("-BackendRootPath (Join-Path $UnpackRoot", native)
        self.assertLess(native.index("DOM readiness nonce"), native.index('$OwnedProcesses["$ShellProcessId|'))
        self.assertIn("creationTimeUtcTicks", native)
        self.assertIn("Capture-NativeOwnedObjects", native)
        self.assertIn("Native QA verification/cleanup failures", native)
        self.assertIn("Get-ValidatedStoreScreenshot", native)
        self.assertIn("storeListingScreenshotPrivacyValidated", native)
        self.assertIn("storeListingScreenshotCount = 4", native)
        self.assertIn("1366x768 minimum dimensions", native)
        self.assertNotIn('| Remove-AppxPackage', native)
        self.assertNotIn('| Stop-Process', native)
        pass1 = (root / "scripts/windows/verify-pass1.ps1").read_text(encoding="utf-8")
        self.assertIn('$env:PYTHONUTF8 = "1"', pass1)
        self.assertIn('$env:PYTHONIOENCODING = "utf-8"', pass1)
        self.assertIn('value = $PreviousPythonUtf8', pass1)
        self.assertIn('value = $PreviousPythonIoEncoding', pass1)
        screenshot = (
            root / "scripts/windows/prepare-store-listing-screenshot.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("twice-QA/twice-WACK candidate lineage", screenshot)
        self.assertIn("metadata-bearing", screenshot)
        self.assertIn("Post-cleanup four-PNG", screenshot)
        self.assertIn("artifacts\\store-listing-public", screenshot)
        self.assertIn("four distinct exact-candidate views", screenshot)
        self.assertNotIn("docs/assets/dashboard-demo.png", screenshot)
        shell = (
            root / "desktop/windows/AegisForecast/MainWindow.xaml.cs"
        ).read_text(encoding="utf-8")
        self.assertIn("CapturePreviewAsync", shell)
        self.assertIn("AsRandomAccessStream", shell)
        self.assertIn("GetDpiForWindow(window) != 96", shell)
        self.assertIn("Browser.Width = storeScreenshotWidth", shell)
        self.assertIn("Browser.Height = storeScreenshotHeight", shell)
        self.assertIn("width != storeScreenshotWidth", shell)
        self.assertLess(
            shell.index("Browser.Width = storeScreenshotWidth"),
            shell.index("await Browser.CoreWebView2.CapturePreviewAsync"),
        )
        self.assertIn("storeListingScreenshotPrivacyValidated = true", shell)
        self.assertIn("screenshots.Count != 4", shell)
        wack = (root / "scripts/windows/verify-wack.ps1").read_text(encoding="utf-8")
        self.assertIn("powershell-transcript.log", wack)
        self.assertIn('Assert-CandidateBytes "completion"', wack)
        self.assertIn("Invoke-BoundedAppCert", wack)
        self.assertIn("Assert-AppCertTreeExited", wack)
        self.assertIn("Test-PathWithin $ProcessPath $PackageRecord.installLocation", wack)
        self.assertIn("Capture-WackReportOwnedLocation", wack)
        self.assertIn("CreatedAppCertRoots", wack)
        self.assertIn("Register-FreshAppCertRoot", wack)
        self.assertIn("approved AppCert executable is already running", wack)
        self.assertIn("creationTimeUtcTicks", wack)
        self.assertIn("WACK verification/cleanup failures", wack)
        self.assertIn("approvedWackFileVersion", wack)
        self.assertIn("appcertSha256", wack)
        self.assertIn("testInventorySha256", wack)
        self.assertIn("immediately before execution", wack)
        self.assertIn("[IO.FileShare]::Read", wack)
        self.assertNotIn("Preflight proved that none", wack)
        wack_policy = (root / "scripts/windows/wack-report-policy.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn('GetAttribute("LATEST_VERSION")', wack_policy)
        self.assertIn('GetAttribute("VERSION")', wack_policy)
        self.assertIn("WACK TEST INDEX and NAME values must each be unique", wack_policy)
        self.assertIn("conflicting direct STATUS/RESULT/OUTCOME", wack_policy)
        self.assertIn("testInventorySha256", wack_policy)
        cka_setup = (root / "scripts/windows/setup-esigner-cka.ps1").read_text(
            encoding="utf-8"
        )
        cka_cleanup = (root / "scripts/windows/cleanup-esigner-cka.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("repository-managed SSL.com CKA bootstrap is disabled", cka_setup)
        self.assertIn("ENVIRONMENT_ONLY_NO_ARGV", cka_setup)
        self.assertNotIn("ArgumentList", cka_setup)
        self.assertNotIn('"-user"', cka_setup)
        self.assertNotIn('"-pass"', cka_setup)
        self.assertNotIn('"-totp"', cka_setup)
        self.assertIn("repository-managed CKA cleanup is disabled", cka_cleanup)
        self.assertIn("DeleteKey", cka_cleanup)
        self.assertIn("CNG provider", cka_cleanup)
        self.assertIn("private-key", cka_cleanup)
        portable_lifecycle = (
            root / "scripts/windows/verify-github-portable-lifecycle.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("DataRootCreationAttempted", portable_lifecycle)
        archive_builder = (
            root / "scripts/windows/new-github-portable-archive.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("archive and checksum must not preexist", archive_builder)
        signing_handoff = (
            root / "scripts/windows/retain-private-signing-handoff.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("AegisGitHubSigningHandoff", signing_handoff)
        self.assertIn("DriveFormat -cne 'NTFS'", signing_handoff)
        self.assertIn("machineGuidSha256", signing_handoff)
        self.assertIn("githubArtifactUploaded = $false", signing_handoff)
        self.assertIn("build account SID must match and must not be a local Administrator", signing_handoff)
        self.assertIn("ingress", signing_handoff)
        self.assertIn("signer-vault", signing_handoff)
        portable_archive = (
            root / "scripts/windows/verify-portable-archive.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("implicit directory case collision", portable_archive)
        self.assertIn("full extraction node inventory differs", portable_archive)
        signature_policy = (root / "scripts/windows/verify-github-signatures.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("1.3.6.1.5.5.7.3.8", signature_policy)
        self.assertIn("exactly one SHA-256/RFC3161", signature_policy)
        trusted_sdk = (root / "scripts/windows/trusted-windows-sdk-tool.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Microsoft Corporation", trusted_sdk)
        self.assertIn("RevocationMode", trusted_sdk)
        self.assertIn("FileVersionRaw", trusted_sdk)
        self.assertIn("$Current = $Tool.Directory", trusted_sdk)
        self.assertIn("[StringComparison]::OrdinalIgnoreCase", trusted_sdk)
        self.assertIn("Assert-AegisValidAppPackageSignature", trusted_sdk)
        equivalence = (root / "scripts/windows/msix-payload-equivalence.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("payloadTreeSha256", equivalence)
        self.assertIn("AppxSignature.p7x", equivalence)
        self.assertIn("AppxMetadata/CodeIntegrity.cat", equivalence)
        self.assertIn("application/vnd.ms-appx.signature", equivalence)
        self.assertIn("application/vnd.ms-pkiseccat", equivalence)
        self.assertIn("must add exactly one signature mapping and one CodeIntegrity.cat mapping", equivalence)
        self.assertIn("SignTool changed an existing content-type mapping", equivalence)
        native_qa = (root / "scripts/windows/verify-native.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("ui_failure.json", native_qa)
        self.assertIn("malformed or unbound QA failure marker", native_qa)
        self.assertIn("Packaged app reported native QA failure", native_qa)
        self.assertIn("Get-CanonicalJsonTimestamp", native_qa)
        self.assertIn('[Text.Json.JsonValueKind]::String', native_qa)
        native_shell = (
            root / "desktop/windows/AegisForecast/MainWindow.xaml.cs"
        ).read_text(encoding="utf-8")
        self.assertIn("WriteQaFailureMarker", native_shell)
        self.assertIn("Normal Store users never have qa_expected.json", native_shell)
        handoff = (root / "scripts/windows/prepare-store-handoff.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("UNSIGNED_FOR_PARTNER_CENTER", handoff)
        self.assertIn("LOCAL_FIXED_NTFS_EXACT_ACL_PENDING_RETENTION", handoff)
        retention = (root / "scripts/windows/retain-private-store-handoff.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("LOCAL_FIXED_NTFS_EXACT_ACL", retention)
        self.assertIn("S-1-5-18", retention)
        self.assertIn("S-1-5-32-544", retention)
        self.assertIn("githubArtifactUploaded = $false", retention)
        self.assertIn('($RunLeaf + ".incomplete")', retention)
        self.assertIn("[IO.Directory]::Move($IncompleteRoot, $RunRoot)", retention)
        self.assertIn("retainedFiles = @($RetainedFileRows)", retention)
        backend_hashes = (root / "scripts/windows/backend-hashes.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("treeSha256", backend_hashes)
        self.assertIn("duplicate path", backend_hashes)
        lock = (root / "requirements-windows-build.lock.txt").read_text(encoding="utf-8")
        self.assertIn("--hash=sha256:", lock)
        self.assertIn("pip==26.2.1", lock)

    def test_store_service_is_fixed_to_bundled_synthetic_artifacts(self) -> None:
        previous = os.environ.get("AEGIS_MODEL_ROOT")
        try:
            os.environ["AEGIS_MODEL_ROOT"] = str(Path.cwd())
            self.assertEqual(DATA_MODE, "DETERMINISTIC_SYNTHETIC_SCENARIO")
            service_system = AegisService().status()["system"]
            self.assertEqual(service_system["offlineOnly"], True)
            for key in (
                "accountConnectorPackaged",
                "canPlaceOrders",
                "canPlaceSimulationOrders",
                "liveTradingAllowed",
            ):
                self.assertNotIn(key, service_system)
        finally:
            if previous is None:
                os.environ.pop("AEGIS_MODEL_ROOT", None)
            else:
                os.environ["AEGIS_MODEL_ROOT"] = previous


class LocalAPISecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.session_token = "s" * 48
        cls.csrf_token = "c" * 48
        AegisHandler.session_token = cls.session_token
        AegisHandler.csrf_token = cls.csrf_token
        AegisHandler.service = AegisService()
        cls.server = AegisHTTPServer(("127.0.0.1", 0), AegisHandler)
        cls.port = int(cls.server.server_address[1])
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], dict]:
        connection = HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = json.loads(response.read().decode("utf-8"))
        result = response.status, {key: value for key, value in response.getheaders()}, payload
        connection.close()
        return result

    def authenticated_headers(self, *, post: bool = False) -> dict[str, str]:
        headers = {"X-Aegis-Session": self.session_token}
        if post:
            headers.update(
                {
                    "X-Aegis-CSRF": self.csrf_token,
                    "Content-Type": "application/json",
                }
            )
        return headers

    def test_api_requires_session_and_sends_security_headers(self) -> None:
        status, headers, _ = self.request("GET", "/api/health")
        self.assertEqual(status, 401)
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertIn("default-src 'self'", headers["Content-Security-Policy"])

    def test_core_readiness_apis_return_real_scenario_data(self) -> None:
        for path in ("/api/health", "/api/status", "/api/signals?limit=1", "/api/universe?limit=1", "/api/data"):
            status, _, payload = self.request("GET", path, headers=self.authenticated_headers())
            self.assertEqual(status, 200, path)
            if path == "/api/health":
                self.assertTrue(payload["ok"])
                self.assertTrue(payload["storeReadOnly"])
                self.assertFalse(payload["executionEnabled"])
                self.assertEqual(payload["mode"], "DETERMINISTIC_SYNTHETIC_SCENARIO")
            elif path == "/api/status":
                self.assertEqual(payload["system"]["dataMode"], "DETERMINISTIC_SYNTHETIC_SCENARIO")
            elif path.startswith("/api/signals"):
                self.assertEqual(len(payload["items"]), 1)
            elif path.startswith("/api/universe"):
                self.assertEqual(len(payload["items"]), 1)
            elif path == "/api/data":
                self.assertEqual(payload["coverage"]["illustrativeOutcomeRows"], 300)

    def test_scenario_integrity_routes_replace_legacy_prediction_routes(self) -> None:
        status, _, payload = self.request("GET", "/api/integrity", headers=self.authenticated_headers())
        self.assertEqual(status, 200)
        self.assertFalse(payload["replacementPolicy"]["trainsModels"])
        for path in ("/api/predictions/refresh", "/api/learning", "/api/learning/run"):
            method = "POST" if path.endswith("run") or path.endswith("refresh") else "GET"
            status, _, _ = self.request(
                method,
                path,
                body=b"{}" if method == "POST" else None,
                headers=self.authenticated_headers(post=method == "POST"),
            )
            self.assertEqual(status, 404, path)

    def test_invalid_host_and_cross_origin_are_rejected(self) -> None:
        status, _, _ = self.request(
            "GET", "/api/health", headers={"Host": "evil.example"}
        )
        self.assertEqual(status, 421)
        status, _, _ = self.request(
            "GET", "/api/health", headers={"Host": "127.0.0.1:9"}
        )
        self.assertEqual(status, 421)
        status, _, _ = self.request(
            "GET",
            "/api/health",
            headers={**self.authenticated_headers(), "Origin": "https://evil.example"},
        )
        self.assertEqual(status, 403)

    def test_all_order_and_t_trader_routes_are_forbidden(self) -> None:
        paths = (
            "/api/moomoo/orders",
            "/api/moomoo/t-trading",
            "/api/t-trader/tick",
            "/api/scheduler/start",
            "/api/example/orders",
            "/api/moomoo/cancel-order",
            "/api/moomoo/modify_order",
            "/api/execution/start",
        )
        for method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
            for path in paths:
                status, _, payload = self.request(
                    method,
                    path,
                    body=None if method == "GET" else b"{}",
                    headers=(
                        self.authenticated_headers()
                        if method == "GET"
                        else self.authenticated_headers(post=True)
                    ),
                )
                self.assertEqual(status, 403, f"{method} {path}")
                self.assertTrue(payload["storeReadOnly"])

    def test_account_connector_and_financial_history_routes_do_not_exist(self) -> None:
        for path in (
            "/api/moomoo/status",
            "/api/moomoo/account",
            "/api/pnl/history",
        ):
            status, _, payload = self.request(
                "GET", path, headers=self.authenticated_headers()
            )
            self.assertEqual(status, 404, path)
            self.assertEqual(payload["error"], "not found")

    def test_post_requires_csrf_and_enforces_body_limit(self) -> None:
        status, _, _ = self.request(
            "POST",
            "/api/privacy",
            body=b"{}",
            headers={"X-Aegis-Session": self.session_token, "Content-Type": "application/json"},
        )
        self.assertEqual(status, 403)
        status, _, _ = self.request(
            "POST",
            "/api/privacy",
            body=b"x" * (MAX_BODY_BYTES + 1),
            headers=self.authenticated_headers(post=True),
        )
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
