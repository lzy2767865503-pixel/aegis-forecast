function Stat({ label, value, detail, tone = '' }) {
  return (
    <div className={`stat-item ${tone}`}>
      <span className="stat-label">{label}</span>
      <strong className="stat-value">{value}</strong>
      <span className="stat-detail">{detail}</span>
    </div>
  )
}

export default function StatusBand({ status }) {
  const scenario = status?.scenario || {}
  const coverage = status?.coverage || {}
  const claimBoundary = status?.claimBoundary || {}
  const covered = coverage.coveredSecurities || 0
  const universe = coverage.scenarioUniverse || scenario.scenarioUniverse || 0
  return (
    <section className="status-band">
      <Stat label="合成情景标签" value={scenario.state || 'NOT READY'} detail="仅稳定哈希生成标签" tone="danger" />
      <Stat label="2026-08-26 证券池" value={`${(scenario.researchUniverse || 0).toLocaleString()}只`} detail="100家公司；102只成分证券" tone="accent" />
      <Stat label="说明性选择" value={`${scenario.selectedScenarioCount || 0}只`} detail="生成规则结果，非行动建议" tone="accent" />
      <Stat label="说明性生成覆盖" value={`${covered.toLocaleString()} / ${universe.toLocaleString()}`} detail="稳定哈希生成，可重现" tone="accent" />
      <Stat label="结论边界" value={claimBoundary.conclusion || '等待检查'} detail="没有历史市场或真实性能结论" tone="danger" />
    </section>
  )
}
