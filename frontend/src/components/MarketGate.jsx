import { Activity, BarChart3, Database, Gauge, ListChecks } from 'lucide-react'

export default function MarketGate({ status, performance }) {
  const market = status?.market || {}
  const coverage = status?.coverage || {}
  const state = market.state || 'NOT READY'
  const panic = state === 'PANIC' || state === 'RISK_OFF'
  const blocked = panic || state === 'NOT_READY'
  const checks = [
    [BarChart3, '纳指趋势', blocked ? '待数据' : '通过', !blocked],
    [Activity, '白名单宽度', blocked ? '待数据' : '观察', !blocked],
    [Gauge, '波动状态', panic ? '高风险' : blocked ? '待数据' : '正常', !blocked],
    [Database, '数据覆盖', `${(coverage.coveragePct || 0).toFixed(1)}%`, coverage.fullMarketReady],
    [ListChecks, '样本外精度', performance?.posture === 'MONITORING' ? '监控中' : '不足', performance?.posture === 'MONITORING'],
  ]
  return (
    <section className="panel market-gate">
      <div className="panel-heading"><div><h2>市场状态与模型闸门</h2><p>任一硬门失败，模型主动弃权</p></div></div>
      <div className={`regime-gauge ${blocked ? 'panic' : 'normal'}`}>
        <div className="regime-arc"><span>{state}</span></div>
      </div>
      <div className="gate-list">
        {checks.map(([Icon, label, value, passed]) => (
          <div className="gate-row" key={label}><Icon size={16} /><span>{label}</span><b className={passed ? 'positive' : 'negative'}>{value}</b></div>
        ))}
      </div>
      <div className={`gate-conclusion ${blocked ? 'blocked' : ''}`}>
        {state === 'NOT_READY' ? '等待 Moomoo 历史行情：当前不输出预测' : panic ? '市场门关闭：本期不输出高置信做多信号' : '市场门开放：仍需通过概率与样本门槛'}
      </div>
    </section>
  )
}
