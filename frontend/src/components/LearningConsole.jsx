import { BrainCircuit, CheckCircle2, ShieldCheck } from 'lucide-react'

export default function LearningConsole({ integrity, onRun, busy = false, expanded = false }) {
  const reference = integrity?.referenceConfiguration || {}
  const evidence = integrity?.illustrativeEvidence || {}
  const policy = integrity?.replacementPolicy || {}
  const lastCheck = integrity?.lastCheck
  return (
    <section className={`panel learning-console ${expanded ? 'full-panel' : ''}`}>
      <div className="panel-heading">
        <div><h2>{expanded ? '本地情景完整性记录' : '说明性文件健康度'}</h2><p>只核对随包生成文件；不训练、不比较、不替换模型</p></div>
        {expanded && <button className="secondary-button" onClick={onRun} disabled={busy}><BrainCircuit size={16} />{busy ? '核对中' : '运行完整性核对'}</button>}
      </div>
      <div className="model-health-list">
        <div><ShieldCheck size={17} /><span>参考配置</span><b>{reference.id || 'deterministic-scenario-v1'}</b></div>
        <div><CheckCircle2 size={17} /><span>生成方法</span><b className="positive">{evidence.generationMethods?.join(', ') || 'stable-sha256-v1'}</b></div>
        <div><BrainCircuit size={17} /><span>说明性结果行</span><b>{evidence.sampleCount || 0}</b></div>
        <div><ShieldCheck size={17} /><span>自动模型替换</span><b>{policy.automaticReplacement === false ? '永久关闭' : '待检查'}</b></div>
      </div>
      {expanded && (
        <div className="learning-detail">
          <article><h3>文件边界</h3><strong>{evidence.claimBoundary || 'ILLUSTRATIVE_ONLY'}</strong><span>被选情景 {evidence.selectedScenarioCount || 0} 行</span><span>不是市场、训练或回测证据</span></article>
          <article><h3>不可绕过的产品边界</h3><span>训练模型：否</span><span>比较模型：否</span><span>自动替换：否</span><span>执行能力：否</span></article>
          <article><h3>最近核对</h3><strong>{lastCheck?.status || '尚未手动运行'}</strong><span>{lastCheck?.details?.message || '启动时 API 已逐行重算说明性指标'}</span></article>
        </div>
      )}
    </section>
  )
}
