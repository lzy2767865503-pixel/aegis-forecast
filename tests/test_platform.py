from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from aegis_quant.audit import AuditLedger
from aegis_quant.autonomy import AutonomyMonitor
from aegis_quant.environment import load_project_env
from aegis_quant.learning import LearningRegistry
from aegis_quant.moomoo_gateway import GatewayConfig, MoomooSimulationGateway
from aegis_quant.nasdaq100_universe import load_universe_config
from aegis_quant.pnl_ledger import PnLLedger
from aegis_quant.server import simulation_execution_enabled
from aegis_quant.service import DATA_MODE, DEMO_MODEL_ROOT
from aegis_quant.t_trader import SimulationTTrader


class UniverseTests(unittest.TestCase):
    def test_nasdaq100_config_uses_unique_official_security_codes(self) -> None:
        config = load_universe_config()
        codes = [row["code"] for row in config["securities"]]
        self.assertGreaterEqual(len(codes), 90)
        self.assertLessEqual(len(codes), 110)
        self.assertEqual(len(codes), len(set(codes)))
        self.assertTrue(all(code.startswith("US.") for code in codes))
        self.assertEqual(config["index"], "NASDAQ-100")

    def test_aggressive_profile_keeps_directional_and_position_guards(self) -> None:
        path = Path(__file__).resolve().parents[1] / "config" / "model_config.json"
        config = json.loads(path.read_text(encoding="utf-8"))
        gates = config["gates"]
        self.assertEqual(config["strategy_profile"], "AGGRESSIVE_SIMULATION")
        self.assertLess(float(gates["minimum_p_up"]), 0.60)
        self.assertTrue(gates["require_trend_confirmation"])
        self.assertTrue(gates["require_relative_strength_confirmation"])
        self.assertLessEqual(int(gates["maximum_names"]), 5)
        self.assertLessEqual(
            int(config["validation"]["maximum_score_threshold"]),
            int(gates["default_score_threshold"]),
        )

    def test_bundled_artifacts_are_synthetic_and_cover_the_demo_universe(self) -> None:
        manifest = json.loads(
            (DEMO_MODEL_ROOT / "demo_manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(DATA_MODE, "DEMO")
        self.assertEqual(manifest["kind"], "DETERMINISTIC_SYNTHETIC_DEMO")
        self.assertFalse(manifest["containsBrokerData"])
        self.assertFalse(manifest["containsPersonalData"])
        self.assertGreaterEqual(int(manifest["securityCount"]), 90)


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
        with sqlite3.connect(self.database) as connection:
            connection.execute(
                "UPDATE audit_events SET payload_json='{}' WHERE sequence=1"
            )
        self.assertFalse(ledger.verify()["valid"])

    def test_simulation_execution_is_opt_in(self) -> None:
        previous = os.environ.pop("AEGIS_ENABLE_SIMULATION_EXECUTION", None)
        try:
            self.assertFalse(simulation_execution_enabled())
            os.environ["AEGIS_ENABLE_SIMULATION_EXECUTION"] = "1"
            self.assertTrue(simulation_execution_enabled())
        finally:
            if previous is None:
                os.environ.pop("AEGIS_ENABLE_SIMULATION_EXECUTION", None)
            else:
                os.environ["AEGIS_ENABLE_SIMULATION_EXECUTION"] = previous

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
        monitor.record_tick({"action": "SKIP", "reason": "NO_STOCK_IN_T_BUY_ZONE"})
        snapshot = monitor.snapshot()
        persisted = json.loads(state_path.read_text(encoding="utf-8"))
        self.assertTrue(snapshot["healthy"])
        self.assertEqual(snapshot["lastDecision"], "NO_STOCK_IN_T_BUY_ZONE")
        self.assertEqual(snapshot["schedulerTicksProcess"], 1)
        self.assertEqual(persisted["schedulerTicksLifetime"], 1)

        previous_decision = snapshot["lastDecisionAt"]
        monitor.record_heartbeat()
        heartbeat = monitor.snapshot()
        self.assertEqual(heartbeat["lastDecisionAt"], previous_decision)
        self.assertTrue(heartbeat["healthy"])
        self.assertFalse(snapshot["independence"]["requiresCodex"])
        self.assertTrue(snapshot["independence"]["requiresMacAwake"])

    def test_pnl_ledger_rolls_daily_weekly_monthly_and_yearly_profit(self) -> None:
        ledger = PnLLedger(self.database)

        def account(total_assets: float, today_pnl: float) -> dict:
            return {
                "connected": True,
                "funds": {
                    "totalAssets": total_assets,
                    "cash": 500,
                    "marketValue": total_assets - 500,
                    "todayPnl": today_pnl,
                },
            }

        first = datetime(2026, 7, 20, 16, 0, tzinfo=timezone.utc)
        second = datetime(2026, 7, 21, 16, 0, tzinfo=timezone.utc)
        ledger.record(account(101_000, 1_000), captured_at=first, minimum_interval_seconds=0)
        ledger.record(account(101_500, 500), captured_at=second, minimum_interval_seconds=0)
        history = ledger.history(as_of=second)

        self.assertEqual(history["periods"]["day"]["profit"], 500.0)
        self.assertEqual(history["periods"]["week"]["profit"], 1_500.0)
        self.assertEqual(history["periods"]["month"]["profit"], 1_500.0)
        self.assertEqual(history["periods"]["year"]["profit"], 1_500.0)
        self.assertEqual(history["snapshotCount"], 2)
        self.assertEqual(history["daily"][0]["date"], "2026-07-21")


class LearningTests(unittest.TestCase):
    def test_learning_cycle_cannot_promote_itself(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            database = Path(tempdir) / "learning.db"
            registry = LearningRegistry(database)
            result = registry.run_cycle()
            self.assertFalse(result["promotionGate"]["eligible"])
            self.assertFalse(result["promotionGate"]["liveAutoPromotion"])

class MoomooSimulationBoundaryTests(unittest.TestCase):
    def test_real_environment_is_permanently_rejected(self) -> None:
        with self.assertRaises(PermissionError):
            MoomooSimulationGateway.assert_simulation_environment("REAL")

    def test_fixed_us_whitelist_is_enforced_before_broker_access(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            ledger = AuditLedger(Path(tempdir) / "moomoo.db")
            gateway = MoomooSimulationGateway(
                allowed_codes={"US.AAPL"},
                config=GatewayConfig(host="127.0.0.1", port=9),
                audit=ledger,
            )
            with self.assertRaises(ValueError):
                gateway.submit_order(
                    {"environment": "SIMULATE", "code": "US.IBM", "side": "BUY", "quantity": 1, "price": 1}
                )

    def test_gateway_whitelist_can_follow_index_reconstitution(self) -> None:
        gateway = MoomooSimulationGateway(allowed_codes={"US.AAPL"})
        gateway.set_allowed_codes({"US.AAPL", "US.NVDA", "US.META"})
        self.assertEqual(gateway.allowed_codes, {"US.AAPL", "US.NVDA", "US.META"})

    def test_moomoo_market_authorization_formats_are_normalized(self) -> None:
        self.assertTrue(MoomooSimulationGateway._has_us_authorization(["US", "HK"]))
        self.assertTrue(MoomooSimulationGateway._has_us_authorization("['US']"))
        self.assertTrue(MoomooSimulationGateway._has_us_authorization("TrdMarket.US"))
        self.assertFalse(MoomooSimulationGateway._has_us_authorization(["HK", "MY"]))

    def test_order_statistics_are_derived_from_broker_order_fields(self) -> None:
        statistics = MoomooSimulationGateway._order_statistics(
            [
                {"trd_side": "BUY", "order_status": "FILLED_ALL", "qty": 1, "dealt_qty": 1, "dealt_avg_price": 100},
                {"trd_side": "SELL", "order_status": "CANCELLED_ALL", "qty": 1, "dealt_qty": 0, "dealt_avg_price": 0},
            ]
        )
        self.assertEqual(statistics["submittedOrders"], 2)
        self.assertEqual(statistics["filledOrders"], 1)
        self.assertEqual(statistics["cancelledOrRejectedOrders"], 1)
        self.assertEqual(statistics["turnover"], 100.0)

    def test_t_trader_tracks_only_its_own_filled_round_trip_inventory(self) -> None:
        code, quantity = SimulationTTrader._automation_position(
            [
                {"code": "US.AAPL", "side": "SELL", "dealtQuantity": 1},
                {"code": "US.AAPL", "side": "BUY", "dealtQuantity": 2},
            ]
        )
        self.assertEqual(code, "US.AAPL")
        self.assertEqual(quantity, 1)

    def test_t_trader_only_buys_selected_stock_inside_its_atr_zone(self) -> None:
        class Gateway:
            allowed_codes = {"US.CSX", "US.MSFT"}

            @staticmethod
            def quote_snapshot(codes):
                prices = {"US.CSX": 49.5, "US.MSFT": 100.0}
                return [
                    {
                        "code": code,
                        "lastPrice": prices[code],
                        "averagePrice": prices[code],
                        "previousClose": prices[code],
                        "suspended": False,
                    }
                    for code in codes
                ]

        candidates = [
            {
                "code": "US.CSX", "selected": True, "technicalScore": 70,
                "probabilityUp": 0.56,
                "tStrategy": {"enabled": True, "buyAtOrBelow": 50, "hardStop": 48},
            },
            {
                "code": "US.MSFT", "selected": False, "technicalScore": 90,
                "probabilityUp": 0.70,
                "tStrategy": {"enabled": False, "buyAtOrBelow": 101, "hardStop": 95},
            },
        ]
        with tempfile.TemporaryDirectory() as tempdir:
            trader = SimulationTTrader(
                Gateway(), lambda: candidates, AuditLedger(Path(tempdir) / "t.db")
            )
            ranked = trader._ranked_snapshots()
        self.assertEqual([row["code"] for row in ranked], ["US.CSX"])

    def test_t_trader_sells_when_stock_reaches_its_atr_sell_zone(self) -> None:
        class Gateway:
            allowed_codes = {"US.CSX"}

            def __init__(self):
                self.submitted = None

            @staticmethod
            def account_snapshot():
                return {
                    "orders": [
                        {
                            "code": "US.CSX", "side": "BUY", "status": "FILLED_ALL",
                            "quantity": 1, "dealtQuantity": 1,
                            "remark": "AEGIS_T_CADENCE_TEST", "createdAt": "2026-07-20 09:45:00",
                        }
                    ]
                }

            @staticmethod
            def quote_snapshot(codes):
                return [{"code": codes[0], "lastPrice": 51, "marketState": "AFTERNOON"}]

            def submit_order(self, order):
                self.submitted = order
                return {**order, "traceId": "t-exit", "status": "SUBMITTED"}

        gateway = Gateway()
        candidate = {
            "code": "US.CSX", "selected": True,
            "tStrategy": {"enabled": True, "buyAtOrBelow": 49, "sellAtOrAbove": 50, "hardStop": 47},
        }
        with tempfile.TemporaryDirectory() as tempdir:
            trader = SimulationTTrader(
                gateway, lambda: [candidate], AuditLedger(Path(tempdir) / "t.db")
            )
            enabled_policy = {**trader.policy(), "enabled": True}
            with patch.object(trader, "policy", return_value=enabled_policy):
                result = trader.tick()
        self.assertEqual(result["action"], "CONDITIONAL_EXIT")
        self.assertEqual(gateway.submitted["side"], "SELL")

    def test_flat_account_builds_five_name_full_exposure_core(self) -> None:
        class Gateway:
            allowed_codes = {f"US.T{i}" for i in range(1, 6)}

            def __init__(self):
                self.submitted = []

            @staticmethod
            def account_snapshot():
                return {
                    "funds": {
                        "totalAssets": 100_000,
                        "availableFunds": 100_000,
                        "marketValue": 0,
                    },
                    "positions": [],
                    "orders": [],
                }

            @staticmethod
            def quote_snapshot(codes):
                return [
                    {
                        "code": code,
                        "lastPrice": 100,
                        "askPrice": 100,
                        "marketState": "AFTERNOON",
                        "suspended": False,
                    }
                    for code in codes
                ]

            def submit_order(self, order):
                self.submitted.append(order)
                return {**order, "traceId": f"core-{len(self.submitted)}", "status": "SUBMITTED"}

        gateway = Gateway()
        candidates = [
            {
                "code": f"US.T{i}",
                "selected": True,
                "tStrategy": {"enabled": True, "buyAtOrBelow": 100, "hardStop": 90},
            }
            for i in range(1, 6)
        ]
        with tempfile.TemporaryDirectory() as tempdir:
            trader = SimulationTTrader(
                gateway, lambda: candidates, AuditLedger(Path(tempdir) / "t.db")
            )
            enabled_policy = {**trader.policy(), "enabled": True}
            with patch.object(trader, "policy", return_value=enabled_policy):
                result = trader.tick()
        self.assertEqual(result["action"], "FULL_EXPOSURE_ENTRY")
        self.assertEqual(len(gateway.submitted), 5)
        self.assertTrue(all(order["side"] == "BUY" for order in gateway.submitted))
        self.assertGreaterEqual(sum(order["quantity"] * 100 for order in gateway.submitted), 99_000)
        self.assertEqual(result["targetExposurePct"], 100.0)


if __name__ == "__main__":
    unittest.main()
