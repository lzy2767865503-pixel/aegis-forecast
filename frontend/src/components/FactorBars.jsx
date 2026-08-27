export default function FactorBars({ factors, compact = false }) {
  const items = factors?.items || []
  return (
    <section className={`panel factor-panel ${compact ? 'compact' : ''}`}>
      <div className="panel-heading"><div><h2>说明性因子维度</h2><p>全部数值由稳定哈希生成，不来自价格、成交量或训练数据</p></div></div>
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
