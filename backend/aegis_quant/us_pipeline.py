from __future__ import annotations

import argparse
import json
import time
from datetime import date
from pathlib import Path
from typing import Any

import pandas as pd

from technical_model.backtest import run_walk_forward
from technical_model.data import load_json, source_ledger
from technical_model.features import build_feature_panel
from technical_model.report import export_support_files
from technical_model.scoring import score_panel

from .paths import CONFIG_ROOT, STORAGE_ROOT
from .nasdaq100_universe import load_universe_config, securities, sync_universe_config


MODEL_CONFIG = CONFIG_ROOT / "model_config.json"
OUTPUT_ROOT = STORAGE_ROOT / "models" / "nasdaq100"
HISTORY_ROOT = OUTPUT_ROOT / "history"


class OpenDDataError(RuntimeError):
    pass


def _public_securities() -> list[dict[str, Any]]:
    return [
        item for item in securities()
        if item.get("data_available", True) and str(item.get("code", "")).startswith("US.")
    ]


def _cache_path(code: str) -> Path:
    return HISTORY_ROOT / f"{code.replace('.', '_')}.csv"


def _load_cache(code: str) -> pd.DataFrame:
    path = _cache_path(code)
    if not path.exists():
        raise OpenDDataError(f"{code} 尚无本地历史行情缓存")
    frame = pd.read_csv(path, dtype={"code": str, "secid": str})
    frame["date"] = pd.to_datetime(frame["date"], errors="coerce")
    return frame.dropna(subset=["date", "open", "high", "low", "close", "volume"]).sort_values("date")


def _normalize_history(raw: pd.DataFrame, code: str, name: str) -> pd.DataFrame:
    if raw.empty:
        raise OpenDDataError(f"OpenD 未返回 {code} 的日线")
    frame = raw.copy()
    date_column = "time_key" if "time_key" in frame.columns else "date"
    frame["date"] = pd.to_datetime(frame[date_column], errors="coerce").dt.normalize()
    for column in ("open", "close", "high", "low", "volume"):
        frame[column] = pd.to_numeric(frame.get(column), errors="coerce")
    frame["amount"] = pd.to_numeric(frame.get("turnover", 0.0), errors="coerce").fillna(0.0)
    frame["turnover_pct"] = pd.to_numeric(frame.get("turnover_rate", 0.0), errors="coerce").fillna(0.0)
    previous_close = frame["close"].shift(1)
    frame["change"] = frame["close"] - previous_close
    frame["pct_change"] = frame["close"].pct_change(fill_method=None) * 100.0
    frame["amplitude_pct"] = (frame["high"] - frame["low"]) / previous_close.replace(0, pd.NA) * 100.0
    frame["code"] = code
    frame["name"] = name
    frame["secid"] = code
    frame["source_url"] = "moomoo://OpenD/request_history_kline"
    columns = [
        "date", "open", "close", "high", "low", "volume", "amount",
        "amplitude_pct", "pct_change", "change", "turnover_pct", "code",
        "name", "secid", "source_url",
    ]
    frame = frame[columns].dropna(subset=["date", "open", "close", "high", "low", "volume"])
    return frame.drop_duplicates(subset=["date"], keep="last").sort_values("date").reset_index(drop=True)


def _fetch_history(quote_context: Any, sdk: Any, code: str, name: str, start: str) -> pd.DataFrame:
    pages: list[pd.DataFrame] = []
    page_key = None
    while True:
        ret, data = -1, "请求尚未执行"
        next_page_key = None
        for attempt in range(1, 4):
            ret, data, next_page_key = quote_context.request_history_kline(
                code=code,
                start=start,
                end=date.today().isoformat(),
                ktype=sdk.KLType.K_DAY,
                autype=sdk.AuType.QFQ,
                max_count=1000,
                page_req_key=page_key,
            )
            if ret == sdk.RET_OK:
                break
            if attempt < 3:
                time.sleep(1.5 * attempt)
        if ret != sdk.RET_OK:
            raise OpenDDataError(f"{code} 历史行情请求失败：{data}")
        if hasattr(data, "empty") and not data.empty:
            pages.append(data)
        page_key = next_page_key
        time.sleep(0.55)
        if page_key is None:
            break
    if not pages:
        raise OpenDDataError(f"OpenD 未返回 {code} 的日线")
    return _normalize_history(pd.concat(pages, ignore_index=True), code, name)


def _histories(refresh: bool) -> tuple[dict[str, pd.DataFrame], list[str]]:
    import moomoo as sdk

    config = load_json(MODEL_CONFIG)
    benchmark = dict(config["benchmark"])
    securities = _public_securities()
    records = securities + [benchmark]
    start = str(config["data"]["lookback_start"])
    minimum_rows = int(config["data"]["minimum_rows"])
    histories: dict[str, pd.DataFrame] = {}
    errors: list[str] = []
    quote_context = None
    try:
        if refresh:
            quote_context = sdk.OpenQuoteContext(host="127.0.0.1", port=11111)
        for item in records:
            code = str(item["code"])
            name = str(item.get("name_en") or item.get("name") or code)
            try:
                should_refresh = refresh or not _cache_path(code).exists()
                if quote_context is not None and should_refresh:
                    cached = None
                    fetch_start = start
                    if _cache_path(code).exists():
                        cached = _load_cache(code)
                        latest_cached = pd.Timestamp(cached["date"].max())
                        fetch_start = max(
                            pd.Timestamp(start), latest_cached - pd.Timedelta(days=15)
                        ).date().isoformat()
                    fresh = _fetch_history(quote_context, sdk, code, name, fetch_start)
                    frame = (
                        pd.concat([cached, fresh], ignore_index=True)
                        .drop_duplicates(subset=["date"], keep="last")
                        .sort_values("date")
                        .reset_index(drop=True)
                        if cached is not None
                        else fresh
                    )
                    HISTORY_ROOT.mkdir(parents=True, exist_ok=True)
                    frame.to_csv(_cache_path(code), index=False)
                else:
                    frame = _load_cache(code)
                if len(frame) < minimum_rows:
                    raise OpenDDataError(f"{code} 只有 {len(frame)} 条日线，最低要求 {minimum_rows} 条")
                histories[code] = frame
            except Exception as exc:
                try:
                    cached = _load_cache(code)
                    if len(cached) < minimum_rows:
                        raise OpenDDataError(f"缓存只有 {len(cached)} 条日线")
                    histories[code] = cached
                    errors.append(f"{code} 在线刷新失败，已使用缓存：{exc}")
                except Exception as cache_exc:
                    errors.append(f"{code}: {exc}; 缓存不可用：{cache_exc}")
    finally:
        if quote_context is not None:
            quote_context.close()
    benchmark_code = str(benchmark["code"])
    if benchmark_code not in histories:
        raise OpenDDataError("QQQ基准行情不可用；" + "；".join(errors))
    public_codes = {str(item["code"]) for item in securities}
    if not public_codes.intersection(histories):
        raise OpenDDataError("Nasdaq-100成分证券均无可用行情；" + "；".join(errors))
    histories["_errors"] = pd.DataFrame({"error": errors})
    return histories, errors


def run(refresh: bool = True) -> dict[str, Any]:
    config = load_json(MODEL_CONFIG)
    universe_warnings: list[str] = []
    if refresh:
        try:
            sync_universe_config()
        except Exception as exc:
            universe_warnings.append(f"官方成分股同步失败，沿用本地清单：{exc}")
    histories, errors = _histories(refresh=refresh)
    errors = universe_warnings + errors
    ledger = source_ledger(histories)
    panel, _market = build_feature_panel(
        histories=histories,
        benchmark_code=str(config["benchmark"]["code"]),
        holding_days=int(config["forecast"]["holding_days"]),
        round_trip_cost_bps=float(config["forecast"]["round_trip_cost_bps"]),
    )
    scored = score_panel(panel=panel, config=config)
    result = run_walk_forward(scored=scored, config=config)
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    scored.to_csv(OUTPUT_ROOT / "feature_panel.csv", index=False)
    export_support_files(result=result, ledger=ledger, output_directory=OUTPUT_ROOT)
    if errors:
        pd.DataFrame({"error": errors}).to_csv(OUTPUT_ROOT / "data_errors.csv", index=False)
    elif (OUTPUT_ROOT / "data_errors.csv").exists():
        (OUTPUT_ROOT / "data_errors.csv").unlink()
    latest = result.latest
    universe = load_universe_config()
    return {
        "ok": True,
        "asOf": pd.Timestamp(latest["date"].max()).date().isoformat(),
        "marketState": str(latest["market_state"].iloc[0]),
        "rankingRows": int(len(latest)),
        "constituentSecurities": int(universe.get("constituent_security_count") or 0),
        "constituentAsOf": universe.get("constituent_as_of"),
        "selectedSignals": int(latest["selected_signal"].sum()),
        "ledgerRows": int(len(ledger)),
        "warnings": errors,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Aegis US Moomoo technical pipeline")
    parser.add_argument("--cached", action="store_true", help="只使用本地缓存")
    args = parser.parse_args()
    print(json.dumps(run(refresh=not args.cached), ensure_ascii=False))


if __name__ == "__main__":
    main()
