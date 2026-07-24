import { Circle, RefreshCw } from 'lucide-react'

export default function Topbar({ status, busy, onRefresh }) {
  const asOf = status?.market?.asOf || '等待数据'
  const demo = Boolean(status?.system?.demoData)
  return (
    <header className="topbar">
      <div className="topbar-brand">Aegis Forecast</div>
      <div className="topbar-meta">
        <span>数据截至 {asOf}</span>
        <span><Circle className="status-dot" size={8} fill="currentColor" /> 量化引擎正常</span>
        <span>{demo ? '公开版 · 合成演示数据' : 'Moomoo · 美股模拟盘'}</span>
      </div>
      <button className="primary-button" onClick={onRefresh} disabled={busy || demo}>
        <RefreshCw className={busy ? 'spin' : ''} size={16} />
        {busy ? '刷新中' : demo ? '演示数据固定' : '刷新预测'}
      </button>
    </header>
  )
}
