import { ChevronRight, Search } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'

function percent(value) {
  return value === null || value === undefined ? '—' : `${(value * 100).toFixed(1)}%`
}

export default function SignalTable({ signals = [], expanded = false, onSelect }) {
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)
  const pageSize = 25
  const filtered = useMemo(() => signals.filter((item) => (
    `${item.code}${item.name}${item.strategy}`.toLowerCase().includes(query.toLowerCase())
  )), [signals, query])
  const pageCount = Math.max(1, Math.ceil(filtered.length / pageSize))
  useEffect(() => setPage(1), [query, signals])
  const shown = expanded ? filtered.slice((page - 1) * pageSize, page * pageSize) : filtered.slice(0, 8)
  return (
    <section className={`panel signal-panel ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading">
        <div>
          <h2>{expanded ? '全部已覆盖股票' : '技术预测排名'}</h2>
          <p>概率不是承诺；按样本外校准概率与技术共振排序</p>
        </div>
        {expanded && (
          <div className="ranking-tools">
            <span>共{filtered.length}只 · 第{page}/{pageCount}页</span>
            <label className="search-box">
              <Search size={15} />
              <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索代码、名称或形态" />
            </label>
          </div>
        )}
      </div>
      <div className="table-scroll">
        <table>
          <thead>
            <tr><th>排名</th><th>代码 / 股票</th><th>技术形态</th><th>技术分</th><th>5日上涨概率</th><th>可行动概率</th><th>样本数</th><th>状态</th><th>详情</th></tr>
          </thead>
          <tbody>
            {shown.map((item) => (
              <tr key={item.code} onDoubleClick={() => onSelect?.(item)}>
                <td className="rank-cell">{item.rank}</td>
                <td><strong>{item.code}</strong><span className="subline">{item.name}</span></td>
                <td>{item.strategy}</td>
                <td>{item.technicalScore.toFixed(1)}</td>
                <td>{percent(item.probabilityUp)}</td>
                <td>{percent(item.probabilityAction)}</td>
                <td>{item.sampleCount || '—'}</td>
                <td><span className={`prediction-state ${item.selected ? 'selected' : 'abstain'}`}>{item.status}</span></td>
                <td><button className="row-action" onClick={() => onSelect?.(item)} aria-label={`查看${item.name}`}><ChevronRight size={16} /></button></td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan="9" className="empty-row">没有可展示的真实预测数据</td></tr>}
          </tbody>
        </table>
      </div>
      {expanded && pageCount > 1 && <div className="table-pagination"><button type="button" disabled={page <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>上一页</button><span>{(page - 1) * pageSize + 1}–{Math.min(page * pageSize, filtered.length)} / {filtered.length}</span><button type="button" disabled={page >= pageCount} onClick={() => setPage((value) => Math.min(pageCount, value + 1))}>下一页</button></div>}
    </section>
  )
}
