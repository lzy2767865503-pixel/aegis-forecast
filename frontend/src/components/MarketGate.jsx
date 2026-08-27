import { Activity, BarChart3, Database, Gauge, ListChecks } from 'lucide-react'

export default function MarketGate({ status, performance }) {
  const scenario = status?.scenario || {}
  const coverage = status?.coverage || {}
  const state = scenario.state || 'NOT READY'
  const blocked = state === 'NOT_READY'
  const checks = [
    [BarChart3, '生成标签', blocked ? '待文件' : '已载入', !blocked],
    [Activity, '说明性选择规则', blocked ? '待文件' : '可复现', !blocked],
    [Gauge, '生成变化维度', blocked ? '待文件' : '说明性', !blocked],
    [Database, '情景证券覆盖', `${(coverage.coveragePct || 0).toFixed(1)}%`, coverage.fullScenarioReady],
    [ListChecks, '逐行指标重算', performance?.posture === 'ILLUSTRATIVE_ONLY' ? '一致' : '待检查', performance?.posture === 'ILLUSTRATIVE_ONLY'],
  ]
  return (
    <section className="panel market-gate">
      <div className="panel-heading"><div><h2>说明性情景规则</h2><p>稳定哈希生成，仅演示透明筛选逻辑</p></div></div>
      <div className={`regime-gauge ${blocked ? 'panic' : 'normal'}`}>
        <div className="regime-arc"><span>{state}</span></div>
      </div>
      <div className="gate-list">
        {checks.map(([Icon, label, value, passed]) => (
          <div className="gate-row" key={label}><Icon size={16} /><span>{label}</span><b className={passed ? 'positive' : 'negative'}>{value}</b></div>
        ))}
      </div>
      <div className={`gate-conclusion ${blocked ? 'blocked' : ''}`}>
        {state === 'NOT_READY' ? '说明性生成文件尚未就绪' : '情景规则可复现；不代表市场判断或行动建议'}
      </div>
    </section>
  )
}
