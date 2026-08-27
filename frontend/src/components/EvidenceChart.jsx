function points(buckets, width = 430, height = 135) {
  if (!buckets?.length) return ''
  return buckets.map((item, index) => {
    const x = 18 + (index / Math.max(buckets.length - 1, 1)) * (width - 36)
    const y = height - 15 - item.illustrativeFrequency * (height - 30)
    return `${index ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

export default function EvidenceChart({ performance, expanded = false }) {
  const metrics = performance?.metrics || {}
  const buckets = performance?.scenarioBuckets || []
  return (
    <section className={`panel evidence-panel ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading"><div><h2>说明性样本一致性</h2><p>{performance?.method || '稳定哈希生成与逐行重算'}</p></div><span className="posture">{performance?.posture || 'NOT READY'}</span></div>
      <div className="evidence-body">
        <div className="evidence-number"><small>随包说明性结果行</small><strong>{metrics.sample_count || 0}</strong><span>{performance?.message || '等待一致性检查'}</span></div>
        <div className="calibration-chart">
          <div className="chart-caption">生成分数与生成结果频率分桶对照（非市场校准）</div>
          <svg viewBox="0 0 430 135" role="img" aria-label="说明性生成分数与说明性生成结果频率图">
            {[25, 65, 105].map((y) => <line key={y} x1="18" y1={y} x2="412" y2={y} className="chart-grid" />)}
            <line x1="18" y1="120" x2="412" y2="15" className="ideal-line" />
            <path d={points(buckets)} className="chart-line" />
            {buckets.map((item, index) => {
              const x = 18 + (index / Math.max(buckets.length - 1, 1)) * 394
              const y = 120 - item.illustrativeFrequency * 105
              return <circle key={item.bucket} cx={x} cy={y} r="3.5" className="chart-point" />
            })}
          </svg>
          {!buckets.length && <div className="chart-empty">说明性生成行尚未载入</div>}
        </div>
      </div>
      <div className="chart-metrics">
        <span><small>生成上行分数均值</small><strong>{metrics.mean_scenario_up_score == null ? '—' : `${(metrics.mean_scenario_up_score * 100).toFixed(1)}%`}</strong></span>
        <span><small>生成结果上行频率</small><strong>{metrics.overall_illustrative_up_frequency == null ? '—' : `${(metrics.overall_illustrative_up_frequency * 100).toFixed(1)}%`}</strong></span>
        <span><small>被选情景生成频率</small><strong>{metrics.selected_illustrative_up_frequency == null ? '—' : `${(metrics.selected_illustrative_up_frequency * 100).toFixed(1)}%`}</strong></span>
        <span><small>说明性 Brier 一致性值</small><strong>{metrics.illustrative_brier_score == null ? '—' : Number(metrics.illustrative_brier_score).toFixed(3)}</strong></span>
      </div>
    </section>
  )
}
