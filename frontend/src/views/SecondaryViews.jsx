import { useMemo, useState } from 'react'
import { AlertTriangle, CalendarDays, CheckCircle2, Clock3, Database, LockKeyhole, RefreshCw, Server, ShieldCheck, TrendingUp, WalletCards } from 'lucide-react'
import EvidenceChart from '../components/EvidenceChart'
import FactorBars from '../components/FactorBars'
import LearningConsole from '../components/LearningConsole'
import SignalTable from '../components/SignalTable'

function ViewFrame({ title, subtitle, children }) {
  return <><div className="page-heading"><div><h1>{title}</h1><p>{subtitle}</p></div><div className="mode-label">SIMULATION ONLY</div></div><div className="view-stack">{children}</div></>
}

export function PredictionsView({ signals, onSelect }) {
  return <ViewFrame title="Nasdaq-100预测排名" subtitle="进攻型纯技术面模型：更早确认趋势，提高出手频率；仍保留硬风控"><SignalTable signals={signals?.items} expanded onSelect={onSelect} /></ViewFrame>
}

function duration(seconds) {
  const value = Number(seconds || 0)
  if (value < 60) return `${Math.floor(value)}秒`
  if (value < 3600) return `${Math.floor(value / 60)}分钟`
  const hours = Math.floor(value / 3600)
  const minutes = Math.floor((value % 3600) / 60)
  return `${hours}小时 ${minutes}分`
}

function localTime(value) {
  if (!value) return '—'
  return new Date(value).toLocaleString('zh-CN', { hour12: false })
}

export function AutonomyView({ autonomy, moomoo, account }) {
  const active = Boolean(autonomy?.healthy)
  const independence = autonomy?.independence || {}
  return (
    <ViewFrame title="自动运行中心" subtitle="用心跳和真实决策证据证明：离开Codex和浏览器后，后台仍在运行">
      <section className={`panel autonomy-hero ${active ? 'active' : 'degraded'}`}>
        <div className="autonomy-state"><i /><div><span>后台引擎</span><strong>{active ? 'ACTIVE · 正在自主运行' : 'DEGRADED · 需要检查'}</strong><small>{autonomy?.boundaryMessage || '等待心跳证据'}</small></div></div>
        <div className="autonomy-kpis">
          <article><span>进程运行时间</span><strong>{duration(autonomy?.uptimeSeconds)}</strong><small>PID {autonomy?.processId || '—'}</small></article>
          <article><span>最近心跳</span><strong>{duration(autonomy?.heartbeatAgeSeconds)}前</strong><small>每{autonomy?.schedulerIntervalSeconds || 30}秒；决策超时会自愈</small></article>
          <article><span>本进程决策轮次</span><strong>{autonomy?.schedulerTicksProcess || 0}</strong><small>累计 {autonomy?.schedulerTicksLifetime || 0}</small></article>
          <article><span>守护重启计数</span><strong>{autonomy?.restartCount || 0}</strong><small>异常时自动拉起</small></article>
          <article><span>下次全量刷新</span><strong>{localTime(autonomy?.nextDailyRefreshLocal)}</strong><small>工作日 05:30 MYT</small></article>
        </div>
      </section>

      <div className="autonomy-grid">
        <section className="panel autonomy-components">
          <div className="panel-heading"><div><h2>常驻组件</h2><p>不需要打开网页，也不需要Codex在场</p></div></div>
          <div className="component-status-list">
            <div><i className={active ? 'ok' : 'bad'} /><span>量化服务进程</span><b>{active ? '运行中' : '异常'}</b></div>
            <div><i className={active ? 'ok' : 'bad'} /><span>30秒策略调度器</span><b>{active ? '运行中' : '心跳超时'}</b></div>
            <div><i className={moomoo?.connected ? 'ok' : 'bad'} /><span>Moomoo OpenD</span><b>{moomoo?.connected ? '模拟盘已授权' : '等待登录'}</b></div>
            <div><i className="ok" /><span>服务健康守护</span><b>{independence.serverSelfHealing ? '60秒自恢复' : '未启用'}</b></div>
            <div><i className="ok" /><span>OpenD健康守护</span><b>{independence.openDSelfHealing ? '60秒自恢复' : '未启用'}</b></div>
          </div>
        </section>

        <section className="panel autonomy-decision">
          <div className="panel-heading"><div><h2>最后一次真实决策</h2><p>来自后台调度器，不是界面演示</p></div><span>{autonomy?.lastDecision || 'STARTING'}</span></div>
          <div className="last-decision-body"><strong>{autonomy?.lastDecisionText || '等待第一轮决策'}</strong><span>决策时间 {localTime(autonomy?.lastDecisionAt)}</span><span>最后成功心跳 {localTime(autonomy?.lastSuccessfulTickAt)}</span><span>当日自动成交 {account?.tTrading?.filledOrdersToday || 0} / {account?.tTrading?.targetFilledOrdersPerDay || 5}</span></div>
        </section>
      </div>

      <section className="panel autonomy-boundary">
        <LockKeyhole size={22} /><div><strong>这是真实边界，不粉饰</strong><span>它已经不依赖Codex和浏览器，但仍是本地系统：Mac关机、睡眠或用户退出登录时不会运行。要做到电脑关机仍运行，必须把引擎和OpenD部署到可持24小时运行的云端主机。</span></div>
      </section>
    </ViewFrame>
  )
}

function usd(value) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2 }).format(Number(value || 0))
}

function signedUsd(value) {
  const number = Number(value || 0)
  return `${number > 0 ? '+' : ''}${usd(number)}`
}

function signedPct(value) {
  const number = Number(value || 0)
  return `${number > 0 ? '+' : ''}${number.toFixed(3)}%`
}

function ProfitBars({ daily }) {
  const rows = [...(daily || [])].slice(0, 30).reverse()
  const maximum = Math.max(1, ...rows.map((row) => Math.abs(Number(row.profit || 0))))
  return (
    <div className="profit-chart" aria-label="每日盈利柱状图">
      <div className="profit-zero-line" />
      {rows.length ? rows.map((row) => {
        const value = Number(row.profit || 0)
        const height = Math.max(2, Math.abs(value) / maximum * 46)
        return <div className="profit-column" key={row.date} title={`${row.date} ${signedUsd(value)}`}><i className={value >= 0 ? 'gain' : 'loss'} style={{ height: `${height}%` }} /><span>{row.date.slice(5)}</span></div>
      }) : <div className="profit-chart-empty">等待第一条账户净值记录</div>}
    </div>
  )
}

export function ProfitView({ pnl, account }) {
  const periods = pnl?.periods || {}
  const cards = [periods.day, periods.week, periods.month, periods.year].filter(Boolean)
  const funds = account?.funds || {}
  return (
    <ViewFrame title="盈利记录" subtitle="以Moomoo模拟账户总资产为唯一净值来源 · 美东交易日口径">
      <section className="panel profit-hero">
        <div className="profit-account"><div><span>当前账户净值</span><strong>{usd(funds.totalAssets || periods.day?.endingAssets)}</strong><small>最新记录 {localTime(pnl?.latestSnapshotAt)}</small></div><TrendingUp size={27} /></div>
        <div className="profit-periods">{cards.map((period) => <article key={period.label}><span>{period.label}盈利</span><strong className={Number(period.profit || 0) >= 0 ? 'positive' : 'negative'}>{signedUsd(period.profit)}</strong><small className={Number(period.returnPct || 0) >= 0 ? 'positive' : 'negative'}>{signedPct(period.returnPct)} · {period.tradingDays}个记录日</small>{period.partialCoverage && <em>从启用日开始</em>}</article>)}</div>
      </section>

      <div className="profit-grid">
        <section className="panel profit-trend-panel">
          <div className="panel-heading"><div><h2>每日盈利趋势</h2><p>最近30个记录日；中线以上为盈利，中线以下为亏损</p></div><CalendarDays size={18} /></div>
          <ProfitBars daily={pnl?.daily} />
        </section>
        <section className="panel profit-method-panel">
          <div className="panel-heading"><div><h2>记录状态</h2><p>后台运行时持续保存，不需要打开网页</p></div></div>
          <div className="profit-method-list">
            <div><span>数据源</span><b>{pnl?.source || '等待Moomoo OpenD'}</b></div>
            <div><span>开始日期</span><b>{pnl?.coverageStartDate || '等待第一条记录'}</b></div>
            <div><span>已保存快照</span><b>{pnl?.snapshotCount || 0}</b></div>
            <div><span>时间口径</span><b>America/New_York</b></div>
          </div>
        </section>
      </div>

      <section className="panel profit-history-panel">
        <div className="panel-heading"><div><h2>每日盈利明细</h2><p>{pnl?.calculation || '每日盈利=收盘净值-开盘基准净值'}</p></div></div>
        <div className="table-scroll"><table><thead><tr><th>交易日</th><th>开盘基准净值</th><th>最新/收盘净值</th><th>当日盈利</th><th>收益率</th><th>现金</th><th>持仓市值</th><th>快照数</th><th>更新时间</th></tr></thead><tbody>{(pnl?.daily || []).length ? pnl.daily.map((row) => <tr key={row.date}><td><strong>{row.date}</strong></td><td>{usd(row.openingAssets)}</td><td>{usd(row.endingAssets)}</td><td className={Number(row.profit || 0) >= 0 ? 'positive' : 'negative'}>{signedUsd(row.profit)}</td><td className={Number(row.returnPct || 0) >= 0 ? 'positive' : 'negative'}>{signedPct(row.returnPct)}</td><td>{usd(row.cash)}</td><td>{usd(row.marketValue)}</td><td>{row.snapshots}</td><td>{localTime(row.lastSnapshotAt)}</td></tr>) : <tr><td colSpan="9" className="empty-row">等待后台保存第一条账户净值</td></tr>}</tbody></table></div>
      </section>

      <section className="panel profit-limitations"><AlertTriangle size={19} /><div><strong>统计边界</strong><span>{(pnl?.limitations || ['启用记录以前的历史无法回补']).join('；')}</span></div></section>
    </ViewFrame>
  )
}

function orderStateClass(status) {
  const value = String(status || '')
  if (value.includes('FILLED')) return 'filled'
  if (value.includes('CANCEL') || value.includes('FAIL') || value.includes('REJECT')) return 'failed'
  return 'pending'
}

export function MoomooView({ moomoo, account, universe, onSubmit, onToggle, busy }) {
  const ready = Boolean(moomoo?.connected)
  const tradable = (universe?.items || []).filter((item) => item.tradable !== false)
  const funds = account?.funds || {}
  const stats = account?.statistics || {}
  const plan = account?.tTrading || {}
  const livePositions = (account?.positions || []).filter((position) => Number(position.quantity || 0) > 0)
  const [ticket, setTicket] = useState({ code: 'US.AAPL', side: 'BUY', quantity: 1, price: '', orderType: 'LIMIT' })
  const tickerName = useMemo(() => Object.fromEntries(tradable.map((item) => [item.code, item.name])), [tradable])

  async function submitTicket(event) {
    event.preventDefault()
    await onSubmit({
      environment: 'SIMULATE',
      code: ticket.code,
      side: ticket.side,
      quantity: Number(ticket.quantity),
      price: ticket.orderType === 'MARKET' ? 0 : Number(ticket.price),
      orderType: ticket.orderType,
      remark: 'AEGIS_MANUAL_SIM',
    })
  }

  return (
    <ViewFrame title="模拟账户与做T控制台" subtitle="资金、持仓和委托直接来自 Moomoo OpenD；成交统计由订单字段派生">
      <section className="broker-connect-strip">
        <span className={`broker-state ${ready ? 'ready' : 'waiting'}`}>{ready ? <CheckCircle2 size={14} /> : <AlertTriangle size={14} />}{ready ? 'SIMULATION READY' : moomoo?.state || 'WAITING'}</span>
        <span>模拟账户 <b>{account?.account?.masked || moomoo?.accounts?.[0]?.account || '—'}</b></span>
        <span><Server size={14} /> OpenD {moomoo?.opendReachable ? '已连接' : '未连接'}</span>
        <span className="real-lock"><LockKeyhole size={14} /> REAL TRADING LOCKED</span>
      </section>

      <section className="panel account-kpis">
        <article><span>总资产（USD）</span><strong>{usd(funds.totalAssets)}</strong><small>OpenD 账户净值</small></article>
        <article><span>现金（USD）</span><strong>{usd(funds.cash)}</strong><small>可用资金 {usd(funds.availableFunds)}</small></article>
        <article><span>购买力（USD）</span><strong>{usd(funds.buyingPower)}</strong><small>模拟账户授信</small></article>
        <article><span>持仓市值（USD）</span><strong>{usd(funds.marketValue)}</strong><small>{livePositions.length} 个持仓 · {Number(plan.actualExposurePct || 0).toFixed(1)}% / 目标{Number(plan.targetExposurePct || 100).toFixed(0)}%</small></article>
        <article><span>今日持仓盈亏</span><strong className={Number(funds.todayPnl || 0) >= 0 ? 'positive' : 'negative'}>{usd(funds.todayPnl)}</strong><small>未实现 {usd(funds.unrealizedPnl)}</small></article>
      </section>

      <div className="broker-control-grid">
        <section className="panel cadence-panel">
          <div className="panel-heading"><div><h2>今日模拟成交</h2><p>{plan.exposureDefinition || plan.definition || '买入或卖出各计1笔'}</p></div><b>{plan.filledOrdersToday || 0} / {plan.targetFilledOrdersPerDay || 5}</b></div>
          <div className="cadence-body">
            <div className="cadence-track">{Array.from({ length: plan.targetFilledOrdersPerDay || 5 }, (_, index) => <i key={index} className={index < (plan.filledOrdersToday || 0) ? 'done' : ''} />)}</div>
            <div className="cadence-meta"><span>剩余 <strong>{plan.remaining ?? 5}</strong> 笔</span><span>状态 <strong>{plan.state || 'WAITING'}</strong></span></div>
          </div>
        </section>

        <section className="panel schedule-panel">
          <div className="panel-heading"><div><h2>交易日程与状态</h2><p>美东时间；仅常规交易时段</p></div><Clock3 size={18} /></div>
          <div className="schedule-state"><strong>{plan.state === 'MARKET_CLOSED' ? '等待美股开市' : plan.state || '等待账户数据'}</strong><span>市场状态 {plan.marketState || 'UNKNOWN'}</span><small>时间窗 {(plan.scheduleEt || []).join(' · ') || '—'} ET</small></div>
        </section>

        <section className="panel t-control-panel">
          <div className="panel-heading"><div><h2>做T训练控制</h2><p>固定节奏单不冒充高置信策略信号</p></div><button type="button" className={`toggle-control ${plan.enabled ? 'on' : ''}`} onClick={() => onToggle(!plan.enabled)} disabled={busy}><i /><span>{plan.enabled ? '已启用' : '已暂停'}</span></button></div>
          <div className="t-rules">{(plan.rules || []).map((rule) => <span key={rule}><ShieldCheck size={13} />{rule}</span>)}</div>
          <p className="runtime-note">{plan.runtimeDependency || '本机与 OpenD 必须持续运行'}</p>
        </section>

        <section className="panel order-ticket-panel">
          <div className="panel-heading"><div><h2>快速下单（模拟）</h2><p>手动委托同样进入 Moomoo 模拟账户</p></div><WalletCards size={18} /></div>
          <form className="order-ticket" onSubmit={submitTicket}>
            <div className="ticket-sides"><button type="button" className={ticket.side === 'BUY' ? 'active buy' : ''} onClick={() => setTicket({ ...ticket, side: 'BUY' })}>买入 BUY</button><button type="button" className={ticket.side === 'SELL' ? 'active sell' : ''} onClick={() => setTicket({ ...ticket, side: 'SELL' })}>卖出 SELL</button></div>
            <label><span>股票</span><select value={ticket.code} onChange={(event) => setTicket({ ...ticket, code: event.target.value })}>{tradable.map((item) => <option value={item.code} key={item.code}>{item.ticker} · {item.name}</option>)}</select></label>
            <div className="ticket-row"><label><span>数量</span><input type="number" min="1" max="100" value={ticket.quantity} onChange={(event) => setTicket({ ...ticket, quantity: event.target.value })} /></label><label><span>类型</span><select value={ticket.orderType} onChange={(event) => setTicket({ ...ticket, orderType: event.target.value })}><option value="LIMIT">限价</option><option value="MARKET">市价</option></select></label></div>
            <label><span>限价（USD）</span><input type="number" min="0.01" step="0.01" disabled={ticket.orderType === 'MARKET'} value={ticket.price} onChange={(event) => setTicket({ ...ticket, price: event.target.value })} placeholder={ticket.orderType === 'MARKET' ? '市价单无需填写' : '输入限价'} /></label>
            <button className="ticket-submit" type="submit" disabled={!ready || busy || (ticket.orderType === 'LIMIT' && !Number(ticket.price))}>{busy ? '正在提交…' : `提交${ticket.side === 'BUY' ? '买入' : '卖出'}模拟委托`}</button>
            <small>{tickerName[ticket.code]} · SIMULATE · DAY</small>
          </form>
        </section>
      </div>

      <section className="panel order-stats-panel">
        <div className="panel-heading"><div><h2>今日订单统计</h2><p>直接按 Moomoo 模拟委托记录汇总</p></div><span>数据更新 {account?.asOf ? new Date(account.asOf).toLocaleTimeString('zh-CN') : '—'}</span></div>
        <div className="order-stats"><article><span>已提交</span><strong>{stats.submittedOrders || 0}</strong></article><article><span>已成交委托</span><strong className="positive">{stats.filledOrders || 0}</strong></article><article><span>活动委托</span><strong>{stats.activeOrders || 0}</strong></article><article><span>已撤/拒单</span><strong className="warning">{stats.cancelledOrRejectedOrders || 0}</strong></article><article><span>成交股数</span><strong>{stats.filledQuantity || 0}</strong></article><article><span>成交金额</span><strong>{usd(stats.turnover)}</strong></article></div>
      </section>

      <div className="broker-tables-grid">
        <section className="panel broker-table-panel">
          <div className="panel-heading"><div><h2>今日委托与派生成交</h2><p>{account?.provenance?.fills || '等待账户数据'}</p></div></div>
          <div className="table-scroll"><table><thead><tr><th>时间</th><th>股票</th><th>方向</th><th>数量</th><th>委托价</th><th>已成交</th><th>成交均价</th><th>状态</th><th>订单号</th></tr></thead><tbody>{(account?.orders || []).length ? account.orders.map((order) => <tr key={order.orderId}><td>{order.createdAt?.split(' ')[1] || '—'}</td><td><strong>{order.code?.replace('US.', '')}</strong><span className="subline">{order.name}</span></td><td className={order.side === 'BUY' ? 'positive' : 'negative'}>{order.side}</td><td>{order.quantity}</td><td>{order.orderType === 'MARKET' ? 'MARKET' : usd(order.price)}</td><td>{order.dealtQuantity}</td><td>{order.dealtQuantity ? usd(order.dealtAveragePrice) : '—'}</td><td><span className={`order-status ${orderStateClass(order.status)}`}>{order.status}</span></td><td className="mono">{order.orderIdMasked}</td></tr>) : <tr><td colSpan="9" className="empty-row">今日暂无模拟委托</td></tr>}</tbody></table></div>
        </section>
        <section className="panel broker-table-panel position-table-panel">
          <div className="panel-heading"><div><h2>当前持仓</h2><p>只读展示 Moomoo 模拟账户持仓</p></div></div>
          <div className="table-scroll"><table><thead><tr><th>股票</th><th>持仓</th><th>可卖</th><th>平均成本</th><th>现价</th><th>市值</th><th>浮动盈亏</th></tr></thead><tbody>{livePositions.length ? livePositions.map((position) => <tr key={position.code}><td><strong>{position.code.replace('US.', '')}</strong><span className="subline">{position.name}</span></td><td>{position.quantity}</td><td>{position.canSellQuantity}</td><td>{usd(position.averageCost)}</td><td>{usd(position.lastPrice)}</td><td>{usd(position.marketValue)}</td><td className={position.unrealizedPnl >= 0 ? 'positive' : 'negative'}>{usd(position.unrealizedPnl)}</td></tr>) : <tr><td colSpan="7" className="empty-row">当前无持仓</td></tr>}</tbody></table></div>
        </section>
      </div>

      <section className="panel safety-panel"><LockKeyhole size={24}/><div><strong>账户安全边界</strong><span>Aegis 不接收、不保存、不显示 Moomoo 密码或交易解锁信息。自动做T只调用 SIMULATE；本机关闭或 OpenD 退出后不会运行。</span></div></section>
    </ViewFrame>
  )
}

export function ValidationView({ performance }) {
  return (
    <ViewFrame title="模型验证" subtitle="先证明样本外有效，再讨论准确率">
      <EvidenceChart performance={performance} expanded />
      <section className="panel methodology-panel">
        <div className="panel-heading"><div><h2>验证协议</h2><p>防止未来函数、过拟合和漂亮但无效的回测</p></div></div>
        <div className="method-grid">
          <article><strong>时间切分</strong><span>每周只使用当时之前504个交易日训练</span></article>
          <article><strong>标签隔离</strong><span>预测日前保留5日隔离带，避免偷看未来</span></article>
          <article><strong>可成交假设</strong><span>收盘后信号按下一交易日开盘近似进入</span></article>
          <article><strong>交易摩擦</strong><span>回测统一扣除20bp往返成本</span></article>
          <article><strong>精度闸门</strong><span>概率、收益和样本数同时达标才接受</span></article>
          <article><strong>主动弃权</strong><span>市场或证据不合格时正确输出为0只</span></article>
        </div>
      </section>
    </ViewFrame>
  )
}

export function FactorsView({ factors, signals }) {
  return (
    <ViewFrame title="因子研究" subtitle="因子定义、权重和当前横截面状态完全透明">
      <FactorBars factors={factors} />
      <section className="panel factor-evidence">
        <div className="panel-heading"><div><h2>当前技术分布</h2><p>技术分不等于上涨概率</p></div></div>
        <div className="score-distribution">
          {['0–59', '60–69', '70–79', '80–89', '90–100'].map((bucket) => {
            const [lower, upper] = bucket.split('–').map(Number)
            const count = (signals?.items || []).filter((item) => item.technicalScore >= lower && item.technicalScore <= upper).length
            return <div key={bucket}><span>{bucket}</span><i><em style={{ width: `${Math.min(100, count * 10)}%` }} /></i><b>{count}</b></div>
          })}
        </div>
      </section>
    </ViewFrame>
  )
}

export function DataView({ dataStatus, universe, onSync, busy }) {
  const coverage = dataStatus?.coverage || {}
  const meta = universe?.meta || {}
  return (
    <ViewFrame title="数据中心" subtitle="来源、覆盖、时效和缺口都必须可见">
      <section className="panel data-overview">
        <div className="panel-heading"><div><h2>真实覆盖</h2><p>{dataStatus?.purchaseRecommendation}</p></div><button className="secondary-button" onClick={onSync} disabled={busy}>{busy ? <RefreshCw className="spin" size={16} /> : <Database size={16} />}{busy ? '检查中' : '检查 Moomoo'}</button></div>
        <div className="data-kpis">
          <span><small>研究股票池</small><strong>{(coverage.researchUniverse || 0).toLocaleString()}</strong></span>
          <span><small>公开股票覆盖</small><strong>{(coverage.coveredSecurities || 0)} / {(coverage.marketDataUniverse || 0)}</strong></span>
          <span><small>覆盖率</small><strong>{(coverage.coveragePct || 0).toFixed(2)}%</strong></span>
          <span><small>最新日期</small><strong>{coverage.latestDate || '—'}</strong></span>
          <span><small>交易环境</small><strong>{meta.execution || '—'}</strong></span>
        </div>
      </section>
      <section className="panel source-panel">
        <div className="panel-heading"><div><h2>数据源注册表</h2><p>付费数据未购买时明确标记，不以替代源冒充</p></div></div>
        <div className="source-list">
          {(dataStatus?.sources || []).map((source) => <div key={source.name}><span className={`source-dot ${source.status.toLowerCase()}`} /><strong>{source.name}</strong><span>{source.role}</span><b>{source.status}</b><em>{source.updatedAt || '—'}</em></div>)}
        </div>
        {(dataStatus?.warnings || []).length > 0 && <div className="warning-list">{dataStatus.warnings.map((warning) => <span key={warning}><AlertTriangle size={15} />{warning}</span>)}</div>}
      </section>
    </ViewFrame>
  )
}

export function LearningView({ learning, onRun, busy }) {
  return <ViewFrame title="学习记录" subtitle="总结经验可以自动，替换冠军模型必须通过证据门"><LearningConsole learning={learning} expanded onRun={onRun} busy={busy} /></ViewFrame>
}

export function AuditView({ audit }) {
  const verification = audit?.verification
  return (
    <ViewFrame title="系统审计" subtitle="每次预测、数据刷新和模型评估均进入SHA-256链式日志">
      <section className="panel audit-panel full-panel">
        <div className="audit-verification">{verification?.valid ? <CheckCircle2 size={20} /> : <AlertTriangle size={20} />}<div><strong>{verification?.valid ? '审计链完整' : '审计链异常'}</strong><span>{verification?.events || 0}条事件 · Head {verification?.headHash?.slice(0, 16) || '—'}</span></div></div>
        <div className="table-scroll"><table><thead><tr><th>序号</th><th>时间</th><th>类别</th><th>动作</th><th>Trace ID</th><th>哈希</th></tr></thead><tbody>{(audit?.items || []).map((event) => <tr key={event.sequence}><td>{event.sequence}</td><td>{new Date(event.eventTime).toLocaleString('zh-CN')}</td><td>{event.category}</td><td>{event.action}</td><td className="mono">{event.traceId.slice(0, 10)}</td><td className="mono">{event.eventHash.slice(0, 12)}</td></tr>)}</tbody></table></div>
      </section>
    </ViewFrame>
  )
}
