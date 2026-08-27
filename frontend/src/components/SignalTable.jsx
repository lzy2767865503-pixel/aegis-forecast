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
          <h2>{expanded ? '2026-08-26 快照研究样本' : '合成技术研究排名'}</h2>
          <p>所有分数与参考值均由稳定哈希生成，不是市场观测或预测</p>
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
            <tr><th>排名</th><th>代码 / 证券</th><th>说明性形态</th><th>生成技术分</th><th>说明性上行分数</th><th>说明性形态分数</th><th>生成结果行</th><th>情景状态</th><th>详情</th></tr>
          </thead>
          <tbody>
            {shown.map((item) => (
              <tr key={item.code} onDoubleClick={() => onSelect?.(item)}>
                <td className="rank-cell">{item.rank}</td>
                <td><strong>{item.code}</strong><span className="subline">{item.name}</span></td>
                <td>{item.strategy}</td>
                <td>{item.technicalScore.toFixed(1)}</td>
                <td>{percent(item.scenarioUpScore)}</td>
                <td>{percent(item.scenarioPatternScore)}</td>
                <td>{item.illustrativeOutcomeRows || '—'}</td>
                <td><span className={`prediction-state ${item.selected ? 'selected' : 'abstain'}`}>{item.status}</span></td>
                <td><button className="row-action" onClick={() => onSelect?.(item)} aria-label={`查看${item.name}`}><ChevronRight size={16} /></button></td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan="9" className="empty-row">没有可展示的合成研究样本</td></tr>}
          </tbody>
        </table>
      </div>
      {expanded && pageCount > 1 && <div className="table-pagination"><button type="button" disabled={page <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>上一页</button><span>{(page - 1) * pageSize + 1}–{Math.min(page * pageSize, filtered.length)} / {filtered.length}</span><button type="button" disabled={page >= pageCount} onClick={() => setPage((value) => Math.min(pageCount, value + 1))}>下一页</button></div>}
    </section>
  )
}
