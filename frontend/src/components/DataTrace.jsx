import { CheckCircle2, Database, Globe2, History } from 'lucide-react'

export default function DataTrace({ status, audit }) {
  const coverage = status?.coverage || {}
  const verification = audit?.verification || {}
  const rows = [
    [Globe2, 'Nasdaq-100成分证券', coverage.researchUniverse || 0],
    [Database, '说明性生成覆盖（证券）', coverage.coveredSecurities || 0],
    [History, '情景标签', coverage.scenarioLabel || '—'],
    [CheckCircle2, '说明性结果行', coverage.illustrativeOutcomeRows || 0],
    [CheckCircle2, '审计哈希链', verification.valid ? '有效' : '待检查'],
  ]
  return (
    <section className="panel trace-panel">
      <div className="panel-heading"><div><h2>生成数据与可追溯性</h2><p>稳定哈希生成；没有历史市场样本或性能结论</p></div></div>
      <div className="trace-list">
        {rows.map(([Icon, label, value]) => <div key={label}><Icon size={16} /><span>{label}</span><b>{typeof value === 'number' ? value.toLocaleString() : value}</b></div>)}
      </div>
    </section>
  )
}
