import DataTrace from '../components/DataTrace'
import EvidenceChart from '../components/EvidenceChart'
import LearningConsole from '../components/LearningConsole'
import MarketGate from '../components/MarketGate'
import SignalTable from '../components/SignalTable'
import StatusBand from '../components/StatusBand'

export default function Overview({ data, actions }) {
  return (
    <>
      <div className="page-heading">
        <div><h1>Nasdaq-100 说明性合成情景</h1><p>2026-08-26 成分快照 · 稳定哈希生成 · 无历史行情、无模型训练</p></div>
        <div className="mode-label">
          确定性合成演示 · 非真实行情
        </div>
      </div>
      <StatusBand status={data.status} />
      <div className="dashboard-primary">
        <SignalTable signals={data.signals?.items} onSelect={actions.selectSignal} />
        <MarketGate status={data.status} performance={data.performance} />
      </div>
      <div className="dashboard-secondary">
        <EvidenceChart performance={data.performance} />
        <LearningConsole integrity={data.integrity} />
        <DataTrace status={data.status} audit={data.audit} />
      </div>
    </>
  )
}
