from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path
from typing import Dict, Iterable, Mapping, Optional
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import pandas as pd


EASTMONEY_ENDPOINT = "https://push2his.eastmoney.com/api/qt/stock/kline/get"
FIELDS = [
    "date",
    "open",
    "close",
    "high",
    "low",
    "volume",
    "amount",
    "amplitude_pct",
    "pct_change",
    "change",
    "turnover_pct",
]


class MarketDataError(RuntimeError):
    """Raised when market data cannot be downloaded or validated."""


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_watchlist(path: Path) -> pd.DataFrame:
    frame = pd.read_csv(path, dtype={"code": str, "secid": str})
    required = {"code", "name", "secid"}
    missing = required.difference(frame.columns)
    if missing:
        raise ValueError("watchlist is missing columns: %s" % sorted(missing))
    if frame["code"].duplicated().any():
        duplicates = frame.loc[frame["code"].duplicated(), "code"].tolist()
        raise ValueError("watchlist contains duplicate codes: %s" % duplicates)
    return frame[list(required)].copy()[["code", "name", "secid"]]


def _request_json(url: str, timeout: int = 20, retries: int = 1) -> dict:
    last_error: Optional[Exception] = None
    for attempt in range(retries):
        try:
            request = Request(
                url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                    "Accept": "application/json,text/plain,*/*",
                    "Referer": "https://quote.eastmoney.com/",
                },
            )
            with urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as exc:  # network errors vary by Python build
            last_error = exc
            if attempt + 1 < retries:
                time.sleep(0.5 * (attempt + 1))
    curl_path = shutil.which("curl")
    if curl_path:
        try:
            completed = subprocess.run(
                [
                    curl_path,
                    "-fsSL",
                    "--retry",
                    "2",
                    "--retry-delay",
                    "1",
                    "--max-time",
                    str(timeout + 5),
                    "-A",
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                    "-e",
                    "https://quote.eastmoney.com/",
                    url,
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=timeout + 10,
            )
            return json.loads(completed.stdout)
        except Exception as curl_error:
            last_error = curl_error
    raise MarketDataError("market-data request failed: %s" % last_error)


def build_eastmoney_url(secid: str, limit: int = 1800) -> str:
    params = {
        "secid": secid,
        "fields1": "f1,f2,f3,f4,f5,f6",
        "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61",
        "klt": 101,
        "fqt": 1,
        "beg": 0,
        "end": 20500000,
        "lmt": int(limit),
    }
    return EASTMONEY_ENDPOINT + "?" + urlencode(params)


def fetch_daily_history(secid: str, code: str, name: str, limit: int = 1800) -> pd.DataFrame:
    url = build_eastmoney_url(secid=secid, limit=limit)
    payload = _request_json(url)
    data = payload.get("data") or {}
    rows = data.get("klines") or []
    if not rows:
        raise MarketDataError("no k-line rows returned for %s %s" % (code, name))

    parsed = [row.split(",") for row in rows]
    frame = pd.DataFrame(parsed, columns=FIELDS)
    frame["date"] = pd.to_datetime(frame["date"], errors="coerce")
    for column in FIELDS[1:]:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    frame = frame.dropna(subset=["date", "open", "high", "low", "close", "volume"])
    frame = frame.drop_duplicates(subset=["date"], keep="last").sort_values("date")
    frame["code"] = str(code)
    frame["name"] = str(name)
    frame["secid"] = str(secid)
    frame["source_url"] = url
    if frame.empty:
        raise MarketDataError("all returned rows were invalid for %s %s" % (code, name))
    return frame.reset_index(drop=True)


def _cache_path(cache_directory: Path, code: str) -> Path:
    return cache_directory / (str(code) + ".csv")


def save_cache(frame: pd.DataFrame, cache_directory: Path, code: str) -> Path:
    cache_directory.mkdir(parents=True, exist_ok=True)
    path = _cache_path(cache_directory, code)
    frame.to_csv(path, index=False)
    return path


def load_cache(cache_directory: Path, code: str) -> pd.DataFrame:
    path = _cache_path(cache_directory, code)
    if not path.exists():
        raise MarketDataError("cache not found for %s" % code)
    frame = pd.read_csv(path, dtype={"code": str, "secid": str})
    frame["date"] = pd.to_datetime(frame["date"], errors="coerce")
    return frame.dropna(subset=["date"]).sort_values("date").reset_index(drop=True)


def obtain_history(
    meta: Mapping[str, str],
    cache_directory: Path,
    limit: int,
    refresh: bool = False,
    offline: bool = False,
) -> pd.DataFrame:
    code = str(meta["code"])
    if offline:
        return load_cache(cache_directory, code)
    if not refresh:
        try:
            cached = load_cache(cache_directory, code)
            if not cached.empty and cached["date"].max().date() >= pd.Timestamp.today().date():
                return cached
        except MarketDataError:
            pass
    try:
        frame = fetch_daily_history(
            secid=str(meta["secid"]), code=code, name=str(meta["name"]), limit=limit
        )
        save_cache(frame, cache_directory, code)
        return frame
    except Exception as download_error:
        try:
            return load_cache(cache_directory, code)
        except MarketDataError as cache_error:
            raise MarketDataError(
                "%s; cache fallback failed: %s" % (download_error, cache_error)
            ) from download_error


def fetch_universe(
    watchlist: pd.DataFrame,
    benchmark: Mapping[str, str],
    cache_directory: Path,
    limit: int = 1800,
    minimum_rows: int = 180,
    refresh: bool = False,
    offline: bool = False,
) -> Dict[str, pd.DataFrame]:
    records = watchlist.to_dict("records") + [dict(benchmark)]
    histories: Dict[str, pd.DataFrame] = {}
    errors = []
    for meta in records:
        code = str(meta["code"])
        try:
            frame = obtain_history(
                meta=meta,
                cache_directory=cache_directory,
                limit=limit,
                refresh=refresh,
                offline=offline,
            )
            if len(frame) < minimum_rows:
                raise MarketDataError(
                    "%s has %d rows; minimum is %d" % (code, len(frame), minimum_rows)
                )
            histories[code] = frame
        except Exception as exc:
            errors.append("%s %s: %s" % (code, meta.get("name", ""), exc))
    if str(benchmark["code"]) not in histories:
        raise MarketDataError("benchmark history is required; errors: %s" % "; ".join(errors))
    if not histories or len(histories) == 1:
        raise MarketDataError("no stock history available; errors: %s" % "; ".join(errors))
    histories["_errors"] = pd.DataFrame({"error": errors})
    return histories


def source_ledger(histories: Mapping[str, pd.DataFrame]) -> pd.DataFrame:
    rows = []
    for code, frame in histories.items():
        if code.startswith("_") or frame.empty:
            continue
        rows.append(
            {
                "code": code,
                "name": str(frame["name"].iloc[-1]),
                "first_date": frame["date"].min().date().isoformat(),
                "last_date": frame["date"].max().date().isoformat(),
                "rows": int(len(frame)),
                "adjustment": "qfq",
                "source_url": str(frame["source_url"].iloc[-1]),
            }
        )
    return pd.DataFrame(rows).sort_values("code").reset_index(drop=True)
