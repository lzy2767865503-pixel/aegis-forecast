function points(calibration, width = 430, height = 135) {
  if (!calibration?.length) return ''
  return calibration.map((item, index) => {
    const x = 18 + (index / Math.max(calibration.length - 1, 1)) * (width - 36)
    const y = height - 15 - item.actual * (height - 30)
    return `${index ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

export default function EvidenceChart({ performance, expanded = false }) {
  const metrics = performance?.metrics || {}
  const calibration = performance?.calibration || []
  const evaluated = metrics.evaluated_signal_count || 0
  return (
    <section className={`panel evidence-panel ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading"><div><h2>样本外验证</h2><p>{performance?.method || '滚动训练与标签隔离'}</p></div><span className="posture">{performance?.posture || 'NOT READY'}</span></div>
      <div className="evidence-body">
        <div className="evidence-number"><small>已评估高置信信号</small><strong>{evaluated}</strong><span>{performance?.message || '等待证据'}</span></div>
        <div className="calibration-chart">
          <div className="chart-caption">校准曲线（5日上涨概率）</div>
          <svg viewBox="0 0 430 135" role="img" aria-label="预测概率与实际频率校准图">
            {[25, 65, 105].map((y) => <line key={y} x1="18" y1={y} x2="412" y2={y} className="chart-grid" />)}
            <line x1="18" y1="120" x2="412" y2="15" className="ideal-line" />
            <path d={points(calibration)} className="chart-line" />
            {calibration.map((item, index) => {
              const x = 18 + (index / Math.max(calibration.length - 1, 1)) * 394
              const y = 120 - item.actual * 105
              return <circle key={item.bucket} cx={x} cy={y} r="3.5" className="chart-point" />
            })}
          </svg>
          {!calibration.length && <div className="chart-empty">暂无足够校准样本</div>}
        </div>
      </div>
      <div className="chart-metrics">
        <span><small>基准上涨率</small><strong>{metrics.baseline_up_rate == null ? '—' : `${(metrics.baseline_up_rate * 100).toFixed(1)}%`}</strong></span>
        <span><small>样本外命中率</small><strong>{evaluated < 30 || metrics.precision_up == null ? '证据不足' : `${(metrics.precision_up * 100).toFixed(1)}%`}</strong></span>
        <span><small>平均净收益</small><strong>{metrics.average_net_return == null ? '—' : `${(metrics.average_net_return * 100).toFixed(2)}%`}</strong></span>
        <span><small>Brier Score</small><strong>{metrics.brier_score == null ? '—' : Number(metrics.brier_score).toFixed(3)}</strong></span>
      </div>
    </section>
  )
}
