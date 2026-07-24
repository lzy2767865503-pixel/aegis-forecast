import DataTrace from '../components/DataTrace'
import EvidenceChart from '../components/EvidenceChart'
import LearningConsole from '../components/LearningConsole'
import MarketGate from '../components/MarketGate'
import SignalTable from '../components/SignalTable'
import StatusBand from '../components/StatusBand'

export default function Overview({ data, actions }) {
  const demo = Boolean(data.status?.system?.demoData)
  return (
    <>
      <div className="page-heading">
        <div><h1>Nasdaq-100量化中心</h1><p>进攻型纯技术面排名 · 当前全部成分证券 · 未来5个交易日</p></div>
        <div className="mode-label">
          {demo ? '合成演示数据 · 不代表真实行情' : 'Moomoo 模拟盘 · 真实盘禁用'}
        </div>
      </div>
      <StatusBand status={data.status} />
      <div className="dashboard-primary">
        <SignalTable signals={data.signals?.items} onSelect={actions.selectSignal} />
        <MarketGate status={data.status} performance={data.performance} />
      </div>
      <div className="dashboard-secondary">
        <EvidenceChart performance={data.performance} />
        <LearningConsole learning={data.learning} />
        <DataTrace status={data.status} audit={data.audit} />
      </div>
    </>
  )
}
