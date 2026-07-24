from __future__ import annotations

import argparse
import json
import math
import mimetypes
import os
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .autonomy import AutonomyMonitor
from .paths import FRONTEND_DIST, ensure_directories
from .service import AegisService


def simulation_execution_enabled() -> bool:
    return os.environ.get("AEGIS_ENABLE_SIMULATION_EXECUTION", "0").strip().lower() in {
        "1",
        "true",
        "yes",
    }


class AegisHandler(BaseHTTPRequestHandler):
    service = AegisService()
    autonomy: AutonomyMonitor | None = None
    server_version = "AegisA/0.1"

    def log_message(self, format: str, *args: object) -> None:
        print("[Aegis]", format % args)

    def _json(self, payload: object, status: int = 200) -> None:
        def clean(value: object) -> object:
            if isinstance(value, float) and not math.isfinite(value):
                return None
            if isinstance(value, dict):
                return {key: clean(item) for key, item in value.items()}
            if isinstance(value, (list, tuple)):
                return [clean(item) for item in value]
            return value

        body = json.dumps(clean(payload), ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        try:
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        routes = {
            "/api/health": lambda: {
                "ok": True,
                "service": "Aegis Forecast",
                "mode": "NASDAQ100_SIMULATION",
                "executionEnabled": simulation_execution_enabled(),
            },
            "/api/autonomy": lambda: self.autonomy.snapshot() if self.autonomy else {"engineState": "STARTING"},
            "/api/status": self.service.status,
            "/api/signals": lambda: self.service.signals(
                int(query.get("limit", [100])[0])
            ),
            "/api/universe": lambda: self.service.universe(
                query.get("q", [""])[0], int(query.get("limit", [100])[0])
            ),
            "/api/learning": self.service.learning.status,
            "/api/audit": self.service.audit_events,
            "/api/performance": self.service.performance,
            "/api/pnl/history": self.service.pnl_history,
            "/api/data": self.service.data_status,
            "/api/factors": self.service.factor_status,
            "/api/moomoo/status": self.service.moomoo.status,
            "/api/moomoo/account": self.service.moomoo_account,
        }
        if parsed.path in routes:
            try:
                self._json(routes[parsed.path]())
            except Exception as exc:
                self._json({"ok": False, "error": str(exc)}, 500)
            return
        self._static(parsed.path)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        try:
            payload = self._body()
            if parsed.path == "/api/universe/sync":
                self._json(self.service.sync_universe())
            elif parsed.path == "/api/predictions/refresh":
                self._json(self.service.refresh_predictions())
            elif parsed.path == "/api/learning/run":
                self._json(self.service.learning.run_cycle())
            elif parsed.path == "/api/moomoo/orders":
                self._json(self.service.moomoo.submit_order(payload))
            elif parsed.path == "/api/moomoo/t-trading":
                self._json(self.service.update_t_trading(payload))
            else:
                self._json({"error": "not found"}, 404)
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self._json({"ok": False, "error": str(exc)}, 400)
        except Exception as exc:
            self._json({"ok": False, "error": str(exc)}, 500)

    def _static(self, request_path: str) -> None:
        if not FRONTEND_DIST.exists():
            self._json({"error": "frontend is not built"}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        relative = request_path.lstrip("/") or "index.html"
        candidate = (FRONTEND_DIST / relative).resolve()
        if FRONTEND_DIST.resolve() not in candidate.parents and candidate != FRONTEND_DIST.resolve():
            self._json({"error": "invalid path"}, 400)
            return
        if not candidate.is_file():
            candidate = FRONTEND_DIST / "index.html"
        content = candidate.read_bytes()
        mime, _ = mimetypes.guess_type(str(candidate))
        self.send_response(200)
        self.send_header("Content-Type", (mime or "application/octet-stream") + ("; charset=utf-8" if mime and mime.startswith("text/") else ""))
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-cache" if candidate.name == "index.html" else "public, max-age=3600")
        self.end_headers()
        self.wfile.write(content)


def serve(host: str = "127.0.0.1", port: int = 8766, open_browser: bool = False) -> None:
    ensure_directories()
    url = f"http://{host}:{port}"
    server = ThreadingHTTPServer((host, port), AegisHandler)
    scheduler_stop = threading.Event()
    autonomy = AutonomyMonitor()
    AegisHandler.autonomy = autonomy

    def run_heartbeat() -> None:
        autonomy.record_heartbeat()
        while not scheduler_stop.wait(30):
            autonomy.record_heartbeat()

    def run_scheduler() -> None:
        while not scheduler_stop.wait(30):
            try:
                result = AegisHandler.service.run_t_trading_tick()
                autonomy.record_tick(result)
                if result.get("action") not in {"SKIP", None}:
                    print(f"[Aegis] T scheduler: {result.get('action')}")
            except Exception as exc:
                autonomy.record_error(exc)
                print(f"[Aegis] T scheduler deferred: {exc}")

    heartbeat_thread = threading.Thread(target=run_heartbeat, name="aegis-heartbeat", daemon=True)
    heartbeat_thread.start()
    if simulation_execution_enabled():
        scheduler_thread = threading.Thread(
            target=run_scheduler,
            name="aegis-t-scheduler",
            daemon=True,
        )
        scheduler_thread.start()
    print(f"Aegis Forecast running at {url}")
    print("Mode: NASDAQ100_SIMULATION | Live trading: PERMANENTLY DISABLED")
    print(
        "Simulation execution: "
        + ("ENABLED" if simulation_execution_enabled() else "DISABLED (safe default)")
    )
    if open_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        scheduler_stop.set()
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local Aegis A workstation")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    serve(args.host, args.port, args.open)


if __name__ == "__main__":
    main()
