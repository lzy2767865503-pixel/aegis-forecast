from __future__ import annotations

import argparse
import hmac
import importlib.util
import ipaddress
import json
import math
import mimetypes
import os
import secrets
import threading
import webbrowser
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .autonomy import AutonomyMonitor
from .paths import FRONTEND_DIST, ensure_directories
from .runtime_policy import (
    EXECUTION_FORBIDDEN_MESSAGE,
    STORE_EDITION,
    STORE_READ_ONLY,
    simulation_execution_enabled,
)
from .service import AegisService


MAX_BODY_BYTES = 64 * 1024
SESSION_COOKIE = "aegis_session"
BLOCKED_EXECUTION_SEGMENTS = {
    "execution",
    "scheduler",
    "t-trader",
    "trade",
    "trading",
    "t-trading",
}


class RequestBodyTooLarge(ValueError):
    pass


def _is_loopback_host(host: str) -> bool:
    value = host.strip().lower()
    if value == "localhost":
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False


def _is_execution_path(path: str) -> bool:
    if not path.startswith("/api/"):
        return False
    segments = {
        segment.lower().replace("_", "-")
        for segment in path.split("/")
        if segment
    }
    return bool(
        segments.intersection(BLOCKED_EXECUTION_SEGMENTS)
        or any("order" in segment for segment in segments)
    )


def _process_is_alive(process_id: int) -> bool:
    """Probe a parent process without sending it a signal or changing state."""

    if process_id <= 0:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        synchronize = 0x00100000
        wait_timeout = 0x00000102
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        handle = kernel32.OpenProcess(synchronize, False, process_id)
        if not handle:
            return False
        try:
            return kernel32.WaitForSingleObject(handle, 0) == wait_timeout
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(process_id, 0)
    except (OSError, ValueError):
        return False
    return True


class AegisHTTPServer(ThreadingHTTPServer):
    daemon_threads = True


class AegisHandler(BaseHTTPRequestHandler):
    # Assigned only inside ``serve``. Keeping this uninitialized makes the
    # packaged dependency-boundary command side-effect free.
    service: AegisService | None = None
    autonomy: AutonomyMonitor | None = None
    session_token = ""
    csrf_token = ""
    server_version = "AegisForecast/1.5"

    def log_message(self, format: str, *args: object) -> None:
        # Never log query strings because developer bootstrap URLs contain a
        # one-process session token.
        path = urlparse(self.path).path
        status = args[1] if len(args) > 1 else "-"
        print(f"[Aegis] {self.command} {path} {status}")

    def _security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; font-src 'self'; "
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        )

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
        self._security_headers()
        try:
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _host_allowed(self) -> bool:
        raw = self.headers.get("Host", "")
        try:
            parsed = urlparse(f"//{raw}")
            hostname = parsed.hostname or ""
            supplied_port = parsed.port
        except ValueError:
            return False
        actual_port = int(self.server.server_address[1])
        return _is_loopback_host(hostname) and supplied_port in {None, actual_port}

    def _allowed_origins(self) -> set[str]:
        port = int(self.server.server_address[1])
        return {
            f"http://127.0.0.1:{port}",
            f"http://localhost:{port}",
        }

    def _origin_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        return origin is None or origin in self._allowed_origins()

    def _session_authenticated(self) -> bool:
        supplied = self.headers.get("X-Aegis-Session", "")
        if supplied and hmac.compare_digest(supplied, self.session_token):
            return True
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except Exception:
            return False
        morsel = cookie.get(SESSION_COOKIE)
        return bool(
            morsel
            and hmac.compare_digest(str(morsel.value), self.session_token)
        )

    def _csrf_allowed(self) -> bool:
        supplied = self.headers.get("X-Aegis-CSRF", "")
        return bool(supplied and hmac.compare_digest(supplied, self.csrf_token))

    def _authorize(self, *, require_csrf: bool = False) -> bool:
        if not self._host_allowed():
            self._json({"ok": False, "error": "invalid host"}, HTTPStatus.MISDIRECTED_REQUEST)
            return False
        if not self._origin_allowed():
            self._json({"ok": False, "error": "cross-origin request rejected"}, HTTPStatus.FORBIDDEN)
            return False
        if not self._session_authenticated():
            self._json({"ok": False, "error": "session required"}, HTTPStatus.UNAUTHORIZED)
            return False
        if require_csrf and not self._csrf_allowed():
            self._json({"ok": False, "error": "CSRF token required"}, HTTPStatus.FORBIDDEN)
            return False
        return True

    def _bootstrap(self, parsed: object) -> bool:
        if parsed.path != "/":
            return False
        supplied = parse_qs(parsed.query).get("session", [""])[0]
        if not supplied or not hmac.compare_digest(supplied, self.session_token):
            return False
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", "/")
        self.send_header(
            "Set-Cookie",
            f"{SESSION_COOKIE}={self.session_token}; HttpOnly; SameSite=Strict; Path=/",
        )
        self.send_header("Cache-Control", "no-store")
        self._security_headers()
        self.end_headers()
        return True

    def _body(self) -> dict[str, object]:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise ValueError("Content-Type must be application/json")
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Content-Length is required")
        length = int(raw_length)
        if length < 0:
            raise ValueError("Invalid Content-Length")
        if length > MAX_BODY_BYTES:
            raise RequestBodyTooLarge("request body exceeds 64 KiB")
        if length == 0:
            return {}
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    @staticmethod
    def _bounded_int(query: dict[str, list[str]], name: str, default: int, maximum: int) -> int:
        value = int(query.get(name, [str(default)])[0])
        return max(1, min(value, maximum))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if not self._host_allowed():
            self._json({"ok": False, "error": "invalid host"}, HTTPStatus.MISDIRECTED_REQUEST)
            return
        if self._bootstrap(parsed):
            return
        if not self._authorize():
            return
        query = parse_qs(parsed.query)
        if _is_execution_path(parsed.path):
            self._json(
                {"ok": False, "error": EXECUTION_FORBIDDEN_MESSAGE, "storeReadOnly": True},
                HTTPStatus.FORBIDDEN,
            )
            return
        if self.service is None:
            self._json({"ok": False, "error": "service not initialized"}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        routes = {
            "/api/health": lambda: {
                "ok": True,
                "service": "Aegis Forecast",
                "edition": STORE_EDITION,
                "storeReadOnly": STORE_READ_ONLY,
                "mode": "DETERMINISTIC_SYNTHETIC_SCENARIO",
                "executionEnabled": simulation_execution_enabled(),
            },
            "/api/autonomy": lambda: self.autonomy.snapshot() if self.autonomy else {"engineState": "STARTING"},
            "/api/status": self.service.status,
            "/api/signals": lambda: self.service.signals(
                self._bounded_int(query, "limit", 100, 500)
            ),
            "/api/universe": lambda: self.service.universe(
                query.get("q", [""])[0][:128],
                self._bounded_int(query, "limit", 100, 500),
            ),
            "/api/integrity": self.service.integrity.status,
            "/api/audit": self.service.audit_events,
            "/api/performance": self.service.performance,
            "/api/data": self.service.data_status,
            "/api/factors": self.service.factor_status,
            "/api/privacy": self.service.privacy_status,
        }
        if parsed.path in routes:
            try:
                self._json(routes[parsed.path]())
            except (ValueError, TypeError) as exc:
                self._json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except Exception:
                self._json({"ok": False, "error": "request failed"}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if parsed.path.startswith("/api/"):
            self._json({"ok": False, "error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        self._static(parsed.path)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if not self._authorize(require_csrf=True):
            return
        if _is_execution_path(parsed.path):
            self._json(
                {"ok": False, "error": EXECUTION_FORBIDDEN_MESSAGE, "storeReadOnly": True},
                HTTPStatus.FORBIDDEN,
            )
            return
        if self.service is None:
            self._json({"ok": False, "error": "service not initialized"}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        try:
            payload = self._body()
            if parsed.path == "/api/scenario/verify":
                self._json(self.service.verify_scenario())
            elif parsed.path == "/api/integrity/run":
                self._json(self.service.integrity.run_cycle())
            elif parsed.path == "/api/privacy":
                self._json(self.service.update_privacy(payload))
            elif parsed.path == "/api/privacy/delete-local-data":
                self._json(self.service.delete_local_data(payload))
            elif parsed.path == "/api/universe/sync":
                self._json(
                    {"ok": False, "error": "Store 版使用随应用验证的只读证券清单"},
                    HTTPStatus.FORBIDDEN,
                )
            else:
                self._json({"ok": False, "error": "not found"}, HTTPStatus.NOT_FOUND)
        except RequestBodyTooLarge as exc:
            self._json({"ok": False, "error": str(exc)}, HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            self._json({"ok": False, "error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except PermissionError as exc:
            self._json({"ok": False, "error": str(exc)}, HTTPStatus.FORBIDDEN)
        except Exception:
            self._json({"ok": False, "error": "request failed"}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def _unsupported_mutation(self) -> None:
        parsed = urlparse(self.path)
        if not self._authorize(require_csrf=True):
            return
        if _is_execution_path(parsed.path):
            self._json(
                {"ok": False, "error": EXECUTION_FORBIDDEN_MESSAGE, "storeReadOnly": True},
                HTTPStatus.FORBIDDEN,
            )
            return
        self._json(
            {"ok": False, "error": "method not allowed"},
            HTTPStatus.METHOD_NOT_ALLOWED,
        )

    def do_DELETE(self) -> None:  # noqa: N802
        self._unsupported_mutation()

    def do_PATCH(self) -> None:  # noqa: N802
        self._unsupported_mutation()

    def do_PUT(self) -> None:  # noqa: N802
        self._unsupported_mutation()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._json({"ok": False, "error": "cross-origin requests are not supported"}, HTTPStatus.METHOD_NOT_ALLOWED)

    def _static(self, request_path: str) -> None:
        if not FRONTEND_DIST.exists():
            self._json({"error": "frontend is not built"}, HTTPStatus.SERVICE_UNAVAILABLE)
            return
        relative = request_path.lstrip("/") or "index.html"
        candidate = (FRONTEND_DIST / relative).resolve()
        frontend_root = FRONTEND_DIST.resolve()
        if frontend_root not in candidate.parents and candidate != frontend_root:
            self._json({"error": "invalid path"}, HTTPStatus.BAD_REQUEST)
            return
        if not candidate.is_file():
            candidate = FRONTEND_DIST / "index.html"
        content = candidate.read_bytes()
        if candidate.name == "index.html":
            content = content.replace(
                b"__AEGIS_CSRF_TOKEN__", self.csrf_token.encode("ascii")
            )
        mime, _ = mimetypes.guess_type(str(candidate))
        self.send_response(HTTPStatus.OK)
        self.send_header(
            "Content-Type",
            (mime or "application/octet-stream")
            + ("; charset=utf-8" if mime and mime.startswith("text/") else ""),
        )
        self.send_header("Content-Length", str(len(content)))
        self.send_header(
            "Cache-Control",
            "no-store" if candidate.name == "index.html" else "public, max-age=3600, immutable",
        )
        self._security_headers()
        self.end_headers()
        self.wfile.write(content)


def serve(
    host: str = "127.0.0.1",
    port: int = 8766,
    open_browser: bool = False,
    *,
    session_token: str | None = None,
    parent_pid: int | None = None,
) -> None:
    if not _is_loopback_host(host):
        raise ValueError("Aegis may only bind to a loopback interface")
    if parent_pid is not None and (parent_pid <= 0 or parent_pid == os.getpid()):
        raise ValueError("parent_pid must identify a separate live process")
    ensure_directories()
    token = session_token or os.environ.get("AEGIS_SESSION_TOKEN") or secrets.token_urlsafe(32)
    if len(token) < 32:
        raise ValueError("AEGIS_SESSION_TOKEN must contain at least 32 characters")
    csrf_token = os.environ.get("AEGIS_CSRF_TOKEN") or secrets.token_urlsafe(32)
    if len(csrf_token) < 32:
        raise ValueError("AEGIS_CSRF_TOKEN must contain at least 32 characters")
    AegisHandler.session_token = token
    AegisHandler.csrf_token = csrf_token
    AegisHandler.service = AegisService()
    autonomy = AutonomyMonitor()
    AegisHandler.autonomy = autonomy
    server = AegisHTTPServer((host, port), AegisHandler)
    actual_port = int(server.server_address[1])
    url = f"http://{host}:{actual_port}"
    heartbeat_stop = threading.Event()

    def run_heartbeat() -> None:
        autonomy.record_heartbeat()
        while not heartbeat_stop.wait(30):
            autonomy.record_heartbeat()

    threading.Thread(target=run_heartbeat, name="aegis-heartbeat", daemon=True).start()
    if parent_pid is not None:
        def monitor_parent() -> None:
            while not heartbeat_stop.wait(2):
                if not _process_is_alive(parent_pid):
                    server.shutdown()
                    return

        threading.Thread(
            target=monitor_parent,
            name="aegis-parent-watchdog",
            daemon=True,
        ).start()
    print(f"AEGIS_READY_URL={url}", flush=True)
    print("Edition: WINDOWS_STORE_READ_ONLY | REAL/LIVE/SIMULATION EXECUTION: DISABLED", flush=True)
    if open_browser:
        bootstrap_url = f"{url}/?session={token}"
        threading.Timer(1.0, lambda: webbrowser.open(bootstrap_url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        heartbeat_stop.set()
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Aegis Forecast Store sidecar")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--open", action="store_true")
    parser.add_argument("--parent-pid", type=int, default=None)
    parser.add_argument(
        "--check-packaged-imports",
        action="store_true",
        help="verify the Store package excludes account/execution modules",
    )
    args = parser.parse_args()
    if args.check_packaged_imports:
        forbidden = (
            "moomoo",
            "futu",
            "aegis_quant.moomoo_gateway",
            "aegis_quant.pnl_ledger",
            "aegis_quant.t_trader",
            "aegis_quant.us_pipeline",
        )
        present: list[str] = []
        for name in forbidden:
            try:
                if importlib.util.find_spec(name) is not None:
                    present.append(name)
            except (ImportError, ModuleNotFoundError, ValueError):
                continue
        if present:
            raise RuntimeError(f"Forbidden Store modules are packaged: {', '.join(present)}")
        print("PACKAGED_BOUNDARY_OK=no-account-sdk-no-execution-modules", flush=True)
        return
    serve(args.host, args.port, args.open, parent_pid=args.parent_pid)


if __name__ == "__main__":
    main()
