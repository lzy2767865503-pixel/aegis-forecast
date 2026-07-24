import { Cable, Circle, LockKeyhole } from 'lucide-react'

export default function BrokerPanel({ broker, expanded = false }) {
  const adapters = broker?.adapters || []
  return (
    <section className={`panel broker-panel ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading"><div><h2>券商与数据状态</h2><p>正规接口优先 · 禁止界面自动化下单</p></div><Cable size={18} /></div>
      <div className="adapter-list">
        {adapters.map((adapter) => (
          <article className="adapter-row" key={adapter.id}>
            <Circle size={9} fill="currentColor" className={`adapter-dot ${adapter.status.toLowerCase()}`} />
            <div><strong>{adapter.name}</strong><span>{adapter.capability}</span></div>
            <b>{adapter.status === 'CONNECTED' ? '已连接' : adapter.status === 'WAITING_AUTHORIZATION' ? '待授权' : '研究模式'}</b>
          </article>
        ))}
      </div>
      <div className="live-lock-row"><LockKeyhole size={16} /><span>真实资金通道</span><strong>代码层锁定</strong></div>
      {expanded && (
        <div className="broker-architecture">
          <div><strong>Mac研究节点</strong><span>数据、训练、回测、模拟、监控</span></div><i>→</i><div><strong>Windows执行节点</strong><span>未来QMT、二次风控、对账</span></div><i>→</i><div><strong>中信建投</strong><span>官方接口、报备后启用</span></div>
        </div>
      )}
    </section>
  )
}
