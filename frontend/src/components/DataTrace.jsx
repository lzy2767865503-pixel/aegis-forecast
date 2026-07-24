import { CheckCircle2, Database, Globe2, History } from 'lucide-react'

export default function DataTrace({ status, audit }) {
  const coverage = status?.coverage || {}
  const verification = audit?.verification || {}
  const rows = [
    [Globe2, 'Nasdaq-100成分证券', coverage.researchUniverse || 0],
    [Database, '历史日线覆盖（股票）', coverage.coveredSecurities || 0],
    [History, '最新数据日期', coverage.latestDate || '—'],
    [CheckCircle2, '数据源账本（完整）', coverage.sourceLedgerRows || 0],
    [CheckCircle2, '审计哈希链', verification.valid ? '有效' : '待检查'],
  ]
  return (
    <section className="panel trace-panel">
      <div className="panel-heading"><div><h2>数据与可追溯性</h2><p>覆盖不足时不伪造量化结论</p></div></div>
      <div className="trace-list">
        {rows.map(([Icon, label, value]) => <div key={label}><Icon size={16} /><span>{label}</span><b>{typeof value === 'number' ? value.toLocaleString() : value}</b></div>)}
      </div>
    </section>
  )
}
