import { AlertTriangle, CheckCircle2, Gauge, LockKeyhole, OctagonX } from 'lucide-react'

export default function RiskConsole({ risk, onKillSwitch }) {
  if (!risk) return <section className="panel skeleton-panel" />
  const exposure = Math.round((risk.grossExposure || 0) * 100)
  return (
    <section className="panel risk-console">
      <div className="panel-heading compact"><div><h2>风险控制台</h2><p>独立于策略的硬风控</p></div><Gauge size={18} /></div>
      <div className="risk-gauge-row">
        <div className="radial-gauge" style={{ '--gauge': `${Math.min(exposure, 100) * 3.6}deg` }}>
          <div><strong>{exposure.toFixed(1)}%</strong><span>当前暴露</span></div>
        </div>
        <div className="risk-budget">
          <span>风险预算上限 <strong>{(risk.grossExposureLimit * 100).toFixed(0)}%</strong></span>
          <span>最大回撤阈值 <strong>{(risk.drawdownLimit * 100).toFixed(0)}%</strong></span>
          <span>今日委托 <strong>{risk.ordersToday}/{risk.ordersPerDayLimit}</strong></span>
        </div>
      </div>
      <div className="control-list">
        {risk.controls.map((control) => (
          <div className="control-row" key={control.name}>
            {control.status === 'LOCKED' ? <LockKeyhole size={15} /> : <CheckCircle2 size={15} />}
            <div><strong>{control.name}</strong><span>{control.detail}</span></div>
            <b className={control.status === 'LOCKED' ? 'locked' : 'enabled'}>{control.status === 'LOCKED' ? '锁定' : '正常'}</b>
          </div>
        ))}
      </div>
      <button className={`kill-switch ${risk.killSwitch ? 'active' : ''}`} onClick={() => onKillSwitch(!risk.killSwitch)}>
        {risk.killSwitch ? <AlertTriangle size={17} /> : <OctagonX size={17} />}
        {risk.killSwitch ? '解除紧急停止' : '启动紧急停止'}
      </button>
    </section>
  )
}
