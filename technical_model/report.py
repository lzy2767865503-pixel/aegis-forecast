from __future__ import annotations

import html
import json
from pathlib import Path
from typing import Mapping, Optional

import numpy as np
import pandas as pd

from .backtest import BacktestResult


def _fmt_number(value: object, decimals: int = 2, suffix: str = "") -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "--"
    if np.isnan(number) or np.isinf(number):
        return "--" if np.isnan(number) else "∞"
    return ("%.*f" % (decimals, number)) + suffix


def _fmt_pct(value: object, decimals: int = 1) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "--"
    if np.isnan(number):
        return "--"
    return ("%.*f%%" % (decimals, 100.0 * number))


def _status_reason(row: pd.Series) -> str:
    if bool(row.get("selected_signal", False)):
        return "高置信信号"
    if not bool(row.get("market_trade_allowed", False)):
        return "市场状态闸门关闭"
    if not bool(row.get("tradable_universe", False)):
        return "流动性/可交易性未通过"
    if not bool(row.get("base_candidate", False)):
        if int(row.get("confirmation_count", 0)) < 4:
            return "共振不足"
        if not bool(row.get("pattern_breakout", False) or row.get("pattern_pullback", False)):
            return "形态未触发"
        return "基础门槛未通过"
    if float(row.get("technical_score", 0)) < float(row.get("walk_forward_threshold", 100)):
        return "低于滚动阈值"
    if float(row.get("p_up", 0)) < 0.60:
        return "经验上涨率不足"
    return "仅相对排名"


def _ranking_rows(frame: pd.DataFrame, limit: int = 10) -> str:
    rows = []
    for _, row in frame.head(limit).iterrows():
        selected = bool(row.get("selected_signal", False))
        badge = '<span class="badge signal">信号</span>' if selected else '<span class="badge watch">观察</span>'
        rows.append(
            "<tr>"
            "<td>%s</td><td><strong>%s %s</strong></td>"
            "<td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
            "<td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
            "</tr>"
            % (
                badge,
                html.escape(str(row["name"])),
                html.escape(str(row["code"])),
                _fmt_number(row["close"], 2),
                _fmt_number(row["technical_score"], 1),
                _fmt_pct(row.get("p_up"), 1),
                _fmt_pct(row.get("p_action"), 1),
                html.escape(str(row.get("archetype", "--"))),
                _fmt_number(row.get("trigger_level"), 2),
                _fmt_number(row.get("invalid_level"), 2),
                html.escape(_status_reason(row)),
            )
        )
    return "".join(rows)


def _factor_cards(frame: pd.DataFrame, limit: int = 5) -> str:
    cards = []
    for _, row in frame.head(limit).iterrows():
        bars = []
        factors = [
            ("趋势", "factor_trend"),
            ("动量", "factor_momentum"),
            ("相对强弱", "factor_relative_strength"),
            ("量价", "factor_volume_price"),
            ("结构", "factor_structure"),
            ("风险质量", "factor_risk_quality"),
        ]
        for label, key in factors:
            value = float(row.get(key, 0.0))
            bars.append(
                '<div class="factor"><span>%s</span><div><i style="width:%.1f%%"></i></div><b>%.0f</b></div>'
                % (label, max(0.0, min(100.0, value)), value)
            )
        cards.append(
            '<article class="factor-card"><h3>%s <small>%s</small></h3><p>技术分 %.1f · RSI %.1f · 5日超额 %s</p>%s</article>'
            % (
                html.escape(str(row["name"])),
                html.escape(str(row["code"])),
                float(row["technical_score"]),
                float(row["rsi14"]),
                _fmt_pct(row["rs5"], 1),
                "".join(bars),
            )
        )
    return "".join(cards)


def _regime_table(regimes: pd.DataFrame) -> str:
    if regimes.empty:
        return '<p class="muted">尚无足够的样本外信号。</p>'
    rows = []
    for _, row in regimes.iterrows():
        rows.append(
            "<tr><td>%s</td><td>%d</td><td>%s</td><td>%s</td><td>%s</td></tr>"
            % (
                html.escape(str(row["market_state"])),
                int(row["signals"]),
                _fmt_pct(row["precision_up"]),
                _fmt_pct(row["precision_action"]),
                _fmt_pct(row["average_return"]),
            )
        )
    return "".join(rows)


def render_html_report(
    result: BacktestResult,
    market: pd.DataFrame,
    ledger: pd.DataFrame,
    config: Mapping[str, object],
    output_path: Path,
    data_errors: Optional[pd.DataFrame] = None,
) -> Path:
    latest = result.latest.copy()
    latest_date = pd.Timestamp(latest["date"].max())
    current_market = market[market["date"].eq(latest_date)].iloc[-1]
    selected_count = int(latest["selected_signal"].sum())
    market_state = str(current_market["market_state"])
    threshold = float(latest["walk_forward_threshold"].iloc[0])
    metrics = result.metrics
    evaluated_count = int(metrics.get("evaluated_signal_count", 0))
    minimum_statistical_sample = int(config["validation"]["minimum_training_signals"])
    statistically_insufficient = evaluated_count < minimum_statistical_sample
    headline = (
        "本期有 %d 只高置信技术信号" % selected_count
        if selected_count
        else "本期弃权：无高置信做多信号"
    )
    market_note = {
        "RISK_ON": "风险偏好：允许顺势筛选。",
        "NEUTRAL": "中性市场：只接受更强的共振。",
        "RISK_OFF": "风险规避：暂停新做多信号。",
        "PANIC": "恐慌状态：模型主动空仓，不因超卖强行抢反弹。",
    }.get(market_state, "")
    if selected_count:
        ranking = latest.sort_values(["selected_signal", "ranking_value"], ascending=[False, False])
    else:
        ranking = latest.sort_values("technical_score", ascending=False)
    factor_view = latest.sort_values("technical_score", ascending=False)
    errors_count = int(len(data_errors)) if data_errors is not None else 0
    source_url = html.escape(str(ledger["source_url"].iloc[0])) if not ledger.empty else "#"

    precision_display = "--" if statistically_insufficient else _fmt_pct(metrics.get("precision_up"))
    lcb_display = "--" if statistically_insufficient else _fmt_pct(metrics.get("precision_lcb_95"))
    action_display = "--" if statistically_insufficient else _fmt_pct(metrics.get("precision_action"))
    lift_display = "--" if statistically_insufficient else _fmt_number(metrics.get("lift_vs_baseline"), 2, "x")
    return_display = "--" if statistically_insufficient else _fmt_pct(metrics.get("average_net_return"))
    brier_display = "--" if statistically_insufficient else _fmt_number(metrics.get("brier_score"), 3)
    sample_label = "样本外信号数（不足）" if statistically_insufficient else "样本外信号数"

    document = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,">
<title>%s</title>
<style>
:root{--ink:#15253b;--muted:#64748b;--line:#dce3ea;--paper:#f4f7fa;--card:#fff;--blue:#1f5d91;--teal:#0f766e;--red:#b42318;--amber:#9a6700}
*{box-sizing:border-box}body{margin:0;background:var(--paper);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;color:var(--ink);line-height:1.55}
main{max-width:1180px;margin:0 auto;padding:34px 22px 70px}.eyebrow{font-size:12px;letter-spacing:.12em;color:var(--blue);font-weight:700;text-transform:uppercase}
h1{font-size:34px;line-height:1.2;margin:8px 0 8px}h2{font-size:22px;margin:34px 0 14px}h3{margin:0 0 4px;font-size:17px}small,.muted{color:var(--muted)}
.hero{background:linear-gradient(135deg,#102a43,#1f5d91);color:#fff;border-radius:18px;padding:28px 30px;box-shadow:0 12px 28px rgba(15,35,55,.18)}.hero p{margin:8px 0;color:#d7e6f3}.hero .headline{font-size:25px;font-weight:750;color:#fff}
.tiles{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin:16px 0}.tile,.card,.factor-card{background:var(--card);border:1px solid var(--line);border-radius:13px;padding:16px}.tile b{display:block;font-size:24px}.tile span{font-size:12px;color:var(--muted)}
.callout{border-left:4px solid var(--amber);background:#fff8e6;border-radius:8px;padding:13px 16px;margin:16px 0}.callout.risk{border-color:var(--red);background:#fff1f0}
.table-wrap{overflow:auto;background:#fff;border:1px solid var(--line);border-radius:12px}table{width:100%%;border-collapse:collapse;min-width:950px}th,td{padding:12px 11px;border-bottom:1px solid var(--line);text-align:left;font-size:13px;white-space:nowrap}th{background:#edf3f8;color:#40556d;position:sticky;top:0}tr:last-child td{border-bottom:0}
.badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:700}.badge.signal{background:#dff5ef;color:#076b5d}.badge.watch{background:#edf1f5;color:#596579}
.factor-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}.factor-card p{margin:0 0 12px;color:var(--muted);font-size:13px}.factor{display:grid;grid-template-columns:74px 1fr 30px;gap:8px;align-items:center;font-size:12px;margin:7px 0}.factor div{height:7px;background:#e8eef4;border-radius:99px;overflow:hidden}.factor i{display:block;height:100%%;background:linear-gradient(90deg,var(--teal),#37a99a);border-radius:99px}.factor b{text-align:right}
.method{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.method .card b{display:block;color:var(--blue);margin-bottom:5px}.source{font-size:12px;word-break:break-all}.footer{margin-top:30px;color:var(--muted);font-size:12px}
@media(max-width:900px){.tiles{grid-template-columns:repeat(2,1fr)}.factor-grid,.method{grid-template-columns:1fr}h1{font-size:28px}.hero{padding:23px}}
</style></head><body><main>
<section class="hero"><div class="eyebrow">Pure Technical · Precision First · %s</div><h1>%s</h1><div class="headline">%s</div><p>%s 滚动技术阈值 %.1f；高置信名单最多5只，允许0只。</p></section>
<section class="tiles">
<div class="tile"><span>当前市场状态</span><b>%s</b></div>
<div class="tile"><span>高置信信号</span><b>%d</b></div>
    <div class="tile"><span>样本外上涨命中率</span><b>%s</b></div>
<div class="tile"><span>股票池基准上涨率</span><b>%s</b></div>
    <div class="tile"><span>%s</span><b>%s</b></div>
</section>
<div class="callout %s"><strong>%s</strong><br>%s</div>
<h2>当前高置信信号与相对排名</h2>
<p class="muted">“观察”只是股票池内相对技术强弱，不是交易信号。突破位是确认位；失效位按收盘判断。</p>
<div class="table-wrap"><table><thead><tr><th>状态</th><th>股票</th><th>收盘</th><th>技术分</th><th>P(上涨)</th><th>P(可交易)</th><th>形态</th><th>确认位</th><th>失效位</th><th>未入选原因</th></tr></thead><tbody>%s</tbody></table></div>
<h2>因子共振拆解</h2><div class="factor-grid">%s</div>
<h2>滚动样本外验证</h2>
<section class="tiles">
<div class="tile"><span>95%% Wilson下界</span><b>%s</b></div>
<div class="tile"><span>可交易标签命中率</span><b>%s</b></div>
<div class="tile"><span>Lift vs 股票池</span><b>%s</b></div>
<div class="tile"><span>平均5日净收益</span><b>%s</b></div>
<div class="tile"><span>Brier Score</span><b>%s</b></div>
</section>
<div class="table-wrap"><table><thead><tr><th>市场状态</th><th>信号数</th><th>上涨命中率</th><th>可交易命中率</th><th>平均净收益</th></tr></thead><tbody>%s</tbody></table></div>
<div class="callout"><strong>正确解读：</strong>这些是按时间滚动产生的研究级样本外结果，不是保证未来命中率。若信号数或置信下界不足，模型应继续影子运行，不应视为完成上线验收。</div>
<h2>模型结构</h2><div class="method">
<div class="card"><b>1. 六类纯技术因子</b>趋势、动量、相对强弱、量价、价格结构、波动与流动性。不使用财报、估值、新闻或概念标签。</div>
<div class="card"><b>2. 只做顺势形态</b>第一版只接受“放量突破”和“趋势回踩再启动”，不做纯超跌抄底。</div>
<div class="card"><b>3. 精度优先与弃权</b>市场状态、滚动阈值、技术共振、经验概率四层闸门同时通过才输出，不为凑数强选。</div>
</div>
<h2>数据与局限</h2>
<div class="card"><ul>
<li>行情来自东方财富日K线接口，技术计算使用前复权价格，数据截止 %s。<a href="%s">数据链路样例</a></li>
<li>回测使用今日观察池，存在生存者偏差；前复权因子不是完整的点时数据。因此目前是研究级，不是生产决策级。</li>
<li>日线回测以信号后次日开盘近似成交，无法完整重建一字板、停牌与盘中排队。正式上线需换用点时复权、历史证券状态和分钟数据。</li>
<li>本次数据失败记录 %d 条。任何缺数据股票都不应被默认为弱势，而应标记为不可评估。</li>
</ul></div>
<p class="footer">%s · 版本 %s · 本报告是技术面候选研究工具，不是保证收益的投资建议。</p>
</main></body></html>""" % (
        html.escape(str(config["model_name"])),
        latest_date.date().isoformat(),
        "A股纯技术面高置信分析模型",
        headline,
        market_note,
        threshold,
        market_state,
        selected_count,
        precision_display,
        _fmt_pct(metrics.get("baseline_up_rate")),
        sample_label,
        str(metrics.get("evaluated_signal_count", 0)),
        "risk" if market_state in {"RISK_OFF", "PANIC"} else "",
        html.escape(market_note),
        "当前技术排名仍保留，但不会被标记为高置信交易信号。"
        if selected_count == 0
        else "信号仅在下一交易日可成交时有效。",
        _ranking_rows(ranking, 10),
        _factor_cards(factor_view, 5),
        lcb_display,
        action_display,
        lift_display,
        return_display,
        brier_display,
        _regime_table(result.regime_metrics),
        latest_date.date().isoformat(),
        source_url,
        errors_count,
        html.escape(str(config["model_name"])),
        html.escape(str(config["version"])),
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(document, encoding="utf-8")
    return output_path


def export_support_files(
    result: BacktestResult,
    ledger: pd.DataFrame,
    output_directory: Path,
) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    result.latest.to_csv(output_directory / "latest_rankings.csv", index=False)
    if not result.predictions.empty:
        result.predictions.to_csv(output_directory / "walk_forward_predictions.csv", index=False)
    result.thresholds.to_csv(output_directory / "threshold_history.csv", index=False)
    result.regime_metrics.to_csv(output_directory / "regime_metrics.csv", index=False)
    ledger.to_csv(output_directory / "source_ledger.csv", index=False)
    with (output_directory / "backtest_summary.json").open("w", encoding="utf-8") as handle:
        json.dump(result.metrics, handle, ensure_ascii=False, indent=2, allow_nan=True)
