import { AlertTriangle, CheckCircle2, Database, ShieldCheck } from 'lucide-react'
import EvidenceChart from '../components/EvidenceChart'
import FactorBars from '../components/FactorBars'
import LearningConsole from '../components/LearningConsole'
import SignalTable from '../components/SignalTable'

function ViewFrame({ title, subtitle, children }) {
  return <><div className="page-heading"><div><h1>{title}</h1><p>{subtitle}</p></div><div className="mode-label">STORE READ-ONLY</div></div><div className="view-stack">{children}</div></>
}

export function ScenariosView({ signals, onSelect }) {
  return <ViewFrame title="Nasdaq-100 研究排名" subtitle="2026-08-26 成分快照上的确定性合成情景；所有数值均非真实行情"><SignalTable signals={signals?.items} expanded onSelect={onSelect} /></ViewFrame>
}
export function ConsistencyView({ performance }) {
  return (
    <ViewFrame title="说明性数据一致性" subtitle="只验证随包生成行与实时计算一致；不验证市场表现">
      <EvidenceChart performance={performance} expanded />
      <section className="panel methodology-panel">
        <div className="panel-heading"><div><h2>生成与核对协议</h2><p>这些步骤证明可复现性，不证明预测能力</p></div></div>
        <div className="method-grid">
          <article><strong>稳定输入</strong><span>使用固定证券代码与带盐 SHA-256 生成数值</span></article>
          <article><strong>无市场数据</strong><span>不读取日线、成交量、账户或券商导出</span></article>
          <article><strong>无模型训练</strong><span>不拟合参数、不使用标签学习、不比较模型</span></article>
          <article><strong>逐行重算</strong><span>API 每次从300行随包说明性结果重新计算指标</span></article>
          <article><strong>文件对照</strong><span>实时结果必须与随包 scenario_metrics.json 完全一致</span></article>
          <article><strong>声明边界</strong><span>所有频率和 Brier 值只描述生成行内部一致性</span></article>
        </div>
      </section>
    </ViewFrame>
  )
}

export function FactorsView({ factors, signals }) {
  return (
    <ViewFrame title="因子研究" subtitle="因子定义、权重和 2026-08-26 合成横截面状态完全透明">
      <FactorBars factors={factors} />
      <section className="panel factor-evidence">
        <div className="panel-heading"><div><h2>2026-08-26 合成技术分布</h2><p>技术分不等于上涨概率</p></div></div>
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

export function DataView({ dataStatus, universe }) {
  const coverage = dataStatus?.coverage || {}
  const meta = universe?.meta || {}
  return (
    <ViewFrame title="数据中心" subtitle="来源、覆盖、时效和缺口都必须可见">
      <section className="panel data-overview">
        <div className="panel-heading"><div><h2>合成演示覆盖</h2><p>{dataStatus?.purchaseRecommendation}</p></div><span className="read-only-badge"><Database size={15} /> 2026-08-26 只读快照</span></div>
        <div className="data-kpis">
          <span><small>研究股票池</small><strong>{(coverage.researchUniverse || 0).toLocaleString()}</strong></span>
          <span><small>说明性证券覆盖</small><strong>{(coverage.coveredSecurities || 0)} / {(coverage.scenarioUniverse || 0)}</strong></span>
          <span><small>覆盖率</small><strong>{(coverage.coveragePct || 0).toFixed(2)}%</strong></span>
          <span><small>情景标签</small><strong>{coverage.scenarioLabel || '—'}</strong></span>
          <span><small>产品模式</small><strong>{meta.productMode || '—'}</strong></span>
        </div>
      </section>
      <section className="panel source-panel">
        <div className="panel-heading"><div><h2>来源与生成注册表</h2><p>成分元数据与说明性生成数值明确分开</p></div></div>
        <div className="source-list">
          {(dataStatus?.sources || []).map((source) => <div key={source.name}><span className={`source-dot ${source.status.toLowerCase()}`} /><strong>{source.name}</strong><span>{source.role}</span><b>{source.status}</b><em>{source.updatedAt || '—'}</em></div>)}
        </div>
        {(dataStatus?.warnings || []).length > 0 && <div className="warning-list">{dataStatus.warnings.map((warning) => <span key={warning}><AlertTriangle size={15} />{warning}</span>)}</div>}
      </section>
    </ViewFrame>
  )
}

export function PrivacyView({ privacy, onPrivacy, onDelete, busy, deleting }) {
  const accepted = Boolean(privacy?.researchNoticeAccepted)
  return (
    <ViewFrame title="隐私与本地数据" subtitle="你可以随时撤销选择或删除本应用在这台设备上的运行数据">
      <section className="panel privacy-notice-panel">
        <ShieldCheck size={30} />
        <div>
          <h2>研究、教育与合成模拟说明</h2>
          <p>Quant Scenario Studio by LAI ZEYU 不提供投资建议、收益保证、订单、撤单或自动交易。说明性生成结果不是市场预测，不能代表未来表现。REAL、LIVE 和 SIMULATE 下单均被 Store 版代码永久拒绝。</p>
        </div>
        <button type="button" className={accepted ? 'secondary-button' : 'primary-button'} onClick={() => onPrivacy({ researchNoticeAccepted: !accepted })} disabled={busy}>{accepted ? '已确认，可撤销' : '我已阅读并确认'}</button>
      </section>

      <section className="panel privacy-grid">
        <article><h2>默认收集</h2><strong>无遥测、无广告标识符</strong><p>应用不上传使用分析、设备标识或崩溃内容。核心演示可以完全离线运行。</p></article>
        <article><h2>本机运行数据</h2><strong>Marker-bound LocalState</strong><p>隐私选择、完整性核对记录和哈希审计链只保存在绑定到当前应用包的目录。</p></article>
        <article><h2>金融账户数据</h2><strong>不读取、不存储</strong><p>Store 包不含券商 SDK、账户连接器或金融交易界面。</p></article>
        <article><h2>网络边界</h2><strong>核心功能完全离线</strong><p>仅有 WinUI 与本机研究引擎之间的随机鉴权 loopback 会话，无远程数据端点。</p></article>
      </section>

      <section className="panel delete-data-panel">
        <div><h2>删除全部本地运行数据</h2><p>只删除所有权标记已验证的 LocalState 中设置、核对记录和审计链。应用文件与随附情景会保留。</p></div>
        <button type="button" className="danger-button" onClick={onDelete} disabled={deleting}>{deleting ? '正在删除…' : '删除本地数据'}</button>
      </section>
    </ViewFrame>
  )
}

export function AboutView() {
  return (
    <ViewFrame title="关于 Quant Scenario Studio" subtitle="产品身份、作者、边界与开源信息">
      <section className="panel about-panel">
        <div className="about-mark" aria-hidden="true">QS</div>
        <div>
          <h2>Quant Scenario Studio by LAI ZEYU</h2>
          <p className="about-author">作者与发布者：<strong>LAI ZEYU（来泽宇）</strong></p>
          <p>Windows Store Read-Only Edition · Version 1.5.0</p>
          <p>源自 Aegis Forecast 研究引擎，仅用于 research、education 与 deterministic synthetic demo；Store 包没有交易或自动执行模块。</p>
          <p>Source: github.com/lzy2767865503-pixel/aegis-forecast · License: MIT · 完整法律文件位于安装包 Legal/</p>
        </div>
      </section>
      <section className="panel privacy-grid">
        <article><h2>作者身份</h2><strong>LAI ZEYU（来泽宇）</strong><p>产品、Store 文案与发布证据使用同一双语署名。</p></article>
        <article><h2>产品身份</h2><strong>Quant Scenario Studio</strong><p>Aegis Forecast 仅作为仓库和内部研究引擎名称。</p></article>
        <article><h2>只读边界</h2><strong>WINDOWS_STORE_READ_ONLY</strong><p>Store 包只展示研究结果，不包含交易、账户连接或调度模块。</p></article>
        <article><h2>数据边界</h2><strong>LocalState / no telemetry</strong><p>无云端账户、无券商连接器；仅保存本地研究设置与审计记录。</p></article>
      </section>
    </ViewFrame>
  )
}

export function IntegrityView({ integrity, onRun, busy }) {
  return <ViewFrame title="本地完整性记录" subtitle="只核对说明性生成文件；没有训练、挑战模型或自动替换"><LearningConsole integrity={integrity} expanded onRun={onRun} busy={busy} /></ViewFrame>
}

export function AuditView({ audit }) {
  const verification = audit?.verification
  return (
    <ViewFrame title="系统审计" subtitle="每次情景核对、隐私更新和本地重算均进入 SHA-256 链式日志">
      <section className="panel audit-panel full-panel">
        <div className="audit-verification">{verification?.valid ? <CheckCircle2 size={20} /> : <AlertTriangle size={20} />}<div><strong>{verification?.valid ? '审计链完整' : '审计链异常'}</strong><span>{verification?.events || 0}条事件 · Head {verification?.headHash?.slice(0, 16) || '—'}</span></div></div>
        <div className="table-scroll"><table><thead><tr><th>序号</th><th>时间</th><th>类别</th><th>动作</th><th>Trace ID</th><th>哈希</th></tr></thead><tbody>{(audit?.items || []).map((event) => <tr key={event.sequence}><td>{event.sequence}</td><td>{new Date(event.eventTime).toLocaleString('zh-CN')}</td><td>{event.category}</td><td>{event.action}</td><td className="mono">{event.traceId.slice(0, 10)}</td><td className="mono">{event.eventHash.slice(0, 12)}</td></tr>)}</tbody></table></div>
      </section>
    </ViewFrame>
  )
}
