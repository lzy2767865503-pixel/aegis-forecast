export default function FactorBars({ factors, compact = false }) {
  const items = factors?.items || []
  return (
    <section className={`panel factor-panel ${compact ? 'compact' : ''}`}>
      <div className="panel-heading"><div><h2>因子研究</h2><p>所有因子均来自价格、成交量与市场相对强弱</p></div></div>
      <div className="factor-list">
        {items.map((item) => (
          <div className="factor-row" key={item.name}>
            <div><strong>{item.name}</strong><span>{item.description}</span></div>
            <div className="factor-track"><i style={{ width: `${item.average || 0}%` }} /></div>
            <b>{item.average == null ? '—' : item.average.toFixed(1)}</b>
            <em>权重 {(item.weight * 100).toFixed(0)}%</em>
          </div>
        ))}
      </div>
    </section>
  )
}
