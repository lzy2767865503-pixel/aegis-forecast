import { BrainCircuit, FlaskConical, ShieldCheck } from 'lucide-react'

export default function LearningConsole({ learning, onRun, busy = false, expanded = false }) {
  const champion = learning?.champion
  const challenger = learning?.challenger
  const evidence = learning?.fullMarketEvidence || {}
  const gate = learning?.promotionGate || {}
  return (
    <section className={`panel learning-console ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading">
        <div><h2>{expanded ? '受控学习记录' : '模型健康度'}</h2><p>挑战模型只能在样本外验证通过后晋级</p></div>
        {expanded && <button className="secondary-button" onClick={onRun} disabled={busy}><BrainCircuit size={16} />{busy ? '评估中' : '运行学习评估'}</button>}
      </div>
      <div className="model-health-list">
        <div><ShieldCheck size={17} /><span>Champion</span><b>{champion?.featureVersion || 'daily-tech-v1'}</b></div>
        <div><FlaskConical size={17} /><span>状态</span><b className="positive">研究基线</b></div>
        <div><BrainCircuit size={17} /><span>漂移监控</span><b>{learning?.drift?.status === 'BASELINE_NOT_ESTABLISHED' ? '尚未建立' : learning?.drift?.status}</b></div>
        <div><BrainCircuit size={17} /><span>下次评审</span><b>数据覆盖达标后</b></div>
      </div>
      {expanded && (
        <div className="learning-detail">
          <article><h3>挑战模型</h3><strong>{challenger?.modelId || '尚未生成'}</strong><span>成熟样本 {evidence.matureSamples || 0}</span><span>影子天数 {evidence.shadowDays || 0}</span></article>
          <article><h3>不可绕过的晋级门</h3><span>成熟样本 ≥ {gate.minimumMatureSamples || 2000}</span><span>高置信信号 ≥ {gate.minimumSignalSamples || 200}</span><span>影子运行 ≥ {gate.minimumShadowDays || 60}日</span><span>必须人工批准</span></article>
          <article><h3>最近评估</h3><strong>{learning?.lastCycle?.status || '尚未运行'}</strong><span>{learning?.lastCycle?.reasons?.join('；') || '等待Nasdaq-100完整样本外证据'}</span></article>
        </div>
      )}
    </section>
  )
}
