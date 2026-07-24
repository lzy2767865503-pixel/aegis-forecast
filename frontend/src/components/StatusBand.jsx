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
  const market = status?.market || {}
  const coverage = status?.coverage || {}
  const model = status?.model || {}
  const covered = coverage.coveredSecurities || 0
  const universe = coverage.marketDataUniverse || market.activeUniverse || 0
  return (
    <section className="status-band">
      <Stat label="市场状态" value={market.state || 'NOT READY'} detail="日线市场门" tone="danger" />
      <Stat label="Nasdaq-100证券池" value={`${(market.researchUniverse || 0).toLocaleString()}只`} detail="100家公司；双股权类别分别排名" tone="accent" />
      <Stat label="当前进攻信号" value={`${market.highConfidenceSignals || 0}只`} detail="最多5只；仍可主动弃权" tone="accent" />
      <Stat label="可排名证券覆盖" value={`${covered.toLocaleString()} / ${universe.toLocaleString()}`} detail="历史不足的最新成分股自动剔除" tone="accent" />
      <Stat label="模型结论" value={model.conclusion || '等待验证'} detail={model.claimAllowed ? '进入持续验证' : '禁止宣称高准确率'} tone="danger" />
    </section>
  )
}
