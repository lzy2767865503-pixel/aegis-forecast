"""Compatibility surface for the removed T-Trader feature.

The Windows Store edition deliberately contains no scheduling, quote-selection
or order-construction implementation.  The class name is retained so older
internal callers fail closed with a clear policy error rather than importing a
legacy execution module.
"""

from __future__ import annotations

from typing import Any, Callable

from .audit import AuditLedger
from .moomoo_gateway import MoomooSimulationGateway
from .runtime_policy import STORE_EDITION, require_execution_allowed


class SimulationTTrader:
    """Non-executing Store compatibility stub."""

    def __init__(
        self,
        gateway: MoomooSimulationGateway,
        candidate_provider: Callable[[], list[dict[str, Any]]],
        audit: AuditLedger,
    ) -> None:
        # Retain references only for API compatibility.  No method reads them
        # before the immutable policy rejection.
        self.gateway = gateway
        self.candidate_provider = candidate_provider
        self.audit = audit

    @staticmethod
    def policy() -> dict[str, Any]:
        return {
            "enabled": False,
            "state": STORE_EDITION,
            "schedulerRegistered": False,
            "orderConstructionAvailable": False,
        }

    def update_policy(self, payload: dict[str, Any]) -> dict[str, Any]:
        del payload
        require_execution_allowed()

    def tick(self) -> dict[str, Any]:
        require_execution_allowed()
