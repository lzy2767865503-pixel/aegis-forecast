import {
  BarChart3,
  Activity,
  BookOpenCheck,
  Database,
  FlaskConical,
  LayoutDashboard,
  ListChecks,
  MonitorUp,
  CircleDollarSign,
  ScanSearch,
} from 'lucide-react'

const items = [
  ['overview', '总览', LayoutDashboard],
  ['predictions', '预测排名', BarChart3],
  ['simulation', 'Moomoo模拟盘', MonitorUp],
  ['profit', '盈利记录', CircleDollarSign],
  ['autonomy', '自动运行', Activity],
  ['validation', '模型验证', ListChecks],
  ['factors', '因子研究', FlaskConical],
  ['data', '数据中心', Database],
  ['learning', '学习记录', BookOpenCheck],
  ['audit', '系统审计', ScanSearch],
]

export default function Sidebar({ active, onChange }) {
  return (
    <aside className="sidebar">
      <div className="brand-mark" aria-label="Aegis Forecast">AF</div>
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
        <strong>SIMULATION ONLY</strong>
        <span>真实盘永久锁定</span>
        <span>Built by LAI ZEYU</span>
      </div>
    </aside>
  )
}
