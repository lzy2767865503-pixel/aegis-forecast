import {
  BarChart3,
  BookOpenCheck,
  Database,
  FlaskConical,
  LayoutDashboard,
  ListChecks,
  ScanSearch,
  ShieldCheck,
  Info,
} from 'lucide-react'

const items = [
  ['overview', '总览', LayoutDashboard],
  ['scenarios', '情景排名', BarChart3],
  ['consistency', '一致性核对', ListChecks],
  ['factors', '说明性因子', FlaskConical],
  ['data', '数据中心', Database],
  ['integrity', '完整性记录', BookOpenCheck],
  ['audit', '系统审计', ScanSearch],
  ['privacy', '隐私与数据', ShieldCheck],
  ['about', '关于', Info],
]

export default function Sidebar({ active, onChange }) {
  return (
    <aside className="sidebar">
      <div className="brand-mark" aria-label="Quant Scenario Studio by LAI ZEYU（来泽宇）">QS</div>
      <nav className="side-nav" aria-label="主导航">
        {items.map(([id, label, Icon]) => (
          <button
            key={id}
            aria-label={label}
            aria-current={active === id ? 'page' : undefined}
            className={`side-nav-item ${active === id ? 'active' : ''}`}
            onClick={() => onChange(id)}
          >
            <Icon size={19} strokeWidth={1.65} />
            <span>{label}</span>
          </button>
        ))}
      </nav>
      <div className="sidebar-scope">
        <strong>ILLUSTRATIVE ONLY</strong>
        <span>离线稳定哈希情景</span>
        <span>Built by LAI ZEYU（来泽宇）</span>
      </div>
    </aside>
  )
}
