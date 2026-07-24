import { X } from 'lucide-react'

function pct(value) {
  return value === null || value === undefined ? '—' : `${(value * 100).toFixed(1)}%`
}

function price(value) {
  return value === null || value === undefined ? '—' : Number(value).toFixed(3).replace(/0+$/, '').replace(/\.$/, '')
}

export default function SignalDrawer({ signal, onClose }) {
  if (!signal) return null
  const buy = signal.buyPlan || {}
  const sell = signal.sellPlan || {}
  const tPlan = signal.tStrategy || {}
  return (
    <div className="drawer-backdrop" onClick={onClose}>
      <aside className="signal-drawer" role="dialog" aria-modal="true" aria-labelledby="signal-drawer-title" onClick={(event) => event.stopPropagation()}>
        <button className="drawer-close" aria-label="关闭详情" onClick={onClose}><X size={18} /></button>
        <span className="drawer-code">{signal.code} · {signal.date}</span>
        <h2 id="signal-drawer-title">{signal.name}</h2>
        <p>{signal.strategy} · 市场状态 {signal.marketState}</p>
        <div className="drawer-score"><strong>{signal.technicalScore.toFixed(1)}</strong><span>综合技术分</span></div>
        <dl className="drawer-details">
          <div><dt>5日上涨概率</dt><dd>{pct(signal.probabilityUp)}</dd></div>
          <div><dt>可行动概率</dt><dd>{pct(signal.probabilityAction)}</dd></div>
          <div><dt>校准样本</dt><dd>{signal.sampleCount || '—'}</dd></div>
          <div><dt>ATR波动</dt><dd>{signal.atrPct?.toFixed(2)}%</dd></div>
          <div><dt>最新收盘</dt><dd>{signal.close || '—'}</dd></div>
          <div><dt>确认价</dt><dd>{signal.triggerPrice || '—'}</dd></div>
          <div><dt>支撑位</dt><dd>{signal.supportPrice || '—'}</dd></div>
          <div><dt>失效位</dt><dd>{signal.invalidPrice || '—'}</dd></div>
        </dl>
        <div className="trade-plan-stack">
          <section className="trade-plan-card buy-plan">
            <div><h3>买入计划</h3><span>{buy.state === 'BUY_TRIGGERED' ? '已触发' : buy.state === 'WAIT_BREAKOUT' ? '等待触发' : '仅观察'}</span></div>
            <dl><div><dt>突破买入</dt><dd>{price(buy.breakoutEntry)}</dd></div><div><dt>回踩买区</dt><dd>{price(buy.pullbackZoneLow)} – {price(buy.pullbackZoneHigh)}</dd></div></dl>
            <p>{buy.condition || '等待技术触发条件'}</p>
          </section>
          <section className="trade-plan-card sell-plan">
            <div><h3>卖出计划</h3><span>硬规则</span></div>
            <dl><div><dt>硬止损</dt><dd>{price(sell.hardStop)}</dd></div><div><dt>止盈一</dt><dd>{price(sell.takeProfit1)}</dd></div><div><dt>止盈二</dt><dd>{price(sell.takeProfit2)}</dd></div><div><dt>时间止损</dt><dd>{sell.timeStopTradingDays || 5}个交易日</dd></div></dl>
            <p>第一目标减仓1/2；剩余仓位用 {sell.trailingStopAtr || 1.5} ATR 移动止损。</p>
          </section>
          <section className="trade-plan-card t-plan">
            <div><h3>单股做 T 计划</h3><span>{tPlan.enabled ? '已启用' : '候选外'}</span></div>
            <dl><div><dt>买入触发</dt><dd>≤ {price(tPlan.buyAtOrBelow)}</dd></div><div><dt>卖出触发</dt><dd>≥ {price(tPlan.sellAtOrAbove)}</dd></div><div><dt>做T止损</dt><dd>{price(tPlan.hardStop)}</dd></div><div><dt>每轮仓位</dt><dd>{pct(tPlan.positionFractionPerRound)}</dd></div></dl>
            <p>{tPlan.rule || '先买后卖，不裸卖空。'}</p>
          </section>
        </div>
        <div className="factor-mini-grid">
          {Object.entries(signal.factors || {}).map(([name, value]) => (
            <div key={name}><span>{name}</span><b>{value.toFixed(1)}</b><i><em style={{ width: `${value}%` }} /></i></div>
          ))}
        </div>
        <div className="drawer-reasons"><h3>{signal.selected ? '通过原因' : '弃权原因'}</h3>{signal.rejectionReasons.map((reason) => <span key={reason}>{reason}</span>)}</div>
        <div className="drawer-notice">买卖价位与做T区间由每只股的ATR和技术结构单独计算；当前仅用于 Moomoo 模拟盘，不构成投资建议。</div>
      </aside>
    </div>
  )
}
