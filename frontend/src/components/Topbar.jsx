import { Circle, RefreshCw } from 'lucide-react'

export default function Topbar({ status, busy, onRefresh }) {
  const asOf = status?.scenario?.asOf || '等待数据'
  return (
    <header className="topbar">
      <div className="topbar-brand">Quant Scenario Studio <small>by LAI ZEYU（来泽宇）</small></div>
      <div className="topbar-meta">
        <span>情景标签 {asOf}</span>
        <span><Circle className="status-dot" size={8} fill="currentColor" /> 只读研究引擎正常</span>
        <span>离线 · 确定性合成演示 · 非真实行情</span>
      </div>
      <button className="primary-button" onClick={onRefresh} disabled={busy}>
        <RefreshCw className={busy ? 'spin' : ''} size={16} />
        {busy ? '校验中' : '校验演示快照'}
      </button>
    </header>
  )
}
