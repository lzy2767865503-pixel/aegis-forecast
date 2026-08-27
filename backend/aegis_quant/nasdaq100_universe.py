from __future__ import annotations

import json
import os
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import CONFIG_ROOT


OFFICIAL_NASDAQ100_URL = "https://api.nasdaq.com/api/quote/list-type/nasdaq100"
UNIVERSE_CONFIG = CONFIG_ROOT / "us_universe.json"


class NasdaqUniverseError(RuntimeError):
    pass


def _clean_company_name(value: Any) -> str:
    name = " ".join(str(value or "").split()).strip()
    suffix_patterns = (
        r"\s+\(DE\)\s+Common Stock.*$",
        r"\s+Class [A-Z]\s+Subordinate Voting Shares.*$",
        r"\s+Class [A-Z]\s+Common Stock.*$",
        r"\s+Series [A-Z]\s+Common Stock.*$",
        r"\s+Common Stock(?:\s+Class [A-Z])?.*$",
        r"\s+American Depositary Shares.*$",
        r"\s+New York Registry Shares.*$",
        r"\s+Ordinary Shares.*$",
        r"\s+Common Shares.*$",
    )
    for pattern in suffix_patterns:
        cleaned = re.sub(pattern, "", name, flags=re.IGNORECASE).strip()
        if cleaned != name:
            return cleaned
    return name


def _normalize_security(row: dict[str, Any]) -> dict[str, Any]:
    ticker = str(row.get("ticker") or row.get("symbol") or "").strip().upper()
    if not re.fullmatch(r"[A-Z][A-Z0-9.-]{0,9}", ticker):
        raise NasdaqUniverseError(f"Nasdaq返回了无效代码：{ticker!r}")
    official_name = " ".join(
        str(row.get("official_name") or row.get("companyName") or row.get("name") or ticker).split()
    )
    name = _clean_company_name(row.get("name") or official_name) or ticker
    return {
        "ticker": ticker,
        "code": f"US.{ticker}",
        "name": name,
        "name_en": name,
        "official_name": official_name,
        "group": "NASDAQ100",
        "research_included": bool(row.get("research_included", True)),
        "data_available": bool(row.get("data_available", True)),
    }


def load_universe_config(path: Path = UNIVERSE_CONFIG) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    normalized = [_normalize_security(row) for row in config.get("securities") or []]
    config["securities"] = normalized
    config["constituent_security_count"] = len(normalized)
    return config


def securities(path: Path = UNIVERSE_CONFIG) -> list[dict[str, Any]]:
    return list(load_universe_config(path).get("securities") or [])


def fetch_official_nasdaq100() -> dict[str, Any]:
    request = urllib.request.Request(
        OFFICIAL_NASDAQ100_URL,
        headers={
            "User-Agent": "Mozilla/5.0 AegisForecast/1.2",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://www.nasdaq.com",
            "Referer": "https://www.nasdaq.com/",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except Exception as exc:
        raise NasdaqUniverseError(f"Nasdaq官方成分股接口不可用：{exc}") from exc
    data = payload.get("data") or {}
    rows = ((data.get("data") or {}).get("rows") or [])
    normalized = [_normalize_security(row) for row in rows]
    codes = [row["code"] for row in normalized]
    if not 90 <= len(normalized) <= 110:
        raise NasdaqUniverseError(f"Nasdaq成分证券数量异常：{len(normalized)}")
    if len(codes) != len(set(codes)):
        raise NasdaqUniverseError("Nasdaq官方成分股出现重复代码")
    as_of = str(data.get("date") or (data.get("data") or {}).get("asOf") or "")
    try:
        snapshot_date = datetime.strptime(as_of, "%b %d, %Y").date().isoformat()
    except ValueError:
        snapshot_date = ""
    return {
        "market": "US",
        "index": "NASDAQ-100",
        "index_symbol": "NDX",
        "benchmark": "US.QQQ",
        "prediction_horizon_days": 5,
        "product_mode": "WINDOWS_STORE_READ_ONLY",
        "official_source": OFFICIAL_NASDAQ100_URL,
        "constituent_as_of": as_of,
        "snapshot_date": snapshot_date,
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "constituent_company_count": 100,
        "constituent_security_count": len(normalized),
        "ranking_method": "AEGIS_TECHNICAL_RESEARCH_SNAPSHOT",
        "securities": normalized,
    }


def sync_universe_config(path: Path = UNIVERSE_CONFIG) -> dict[str, Any]:
    config = fetch_official_nasdaq100()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)
    return config
