import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from './api'
import Sidebar from './components/Sidebar'
import SignalDrawer from './components/SignalDrawer'
import Topbar from './components/Topbar'
import Overview from './views/Overview'
import {
  AuditView,
  DataView,
  FactorsView,
  LearningView,
  MoomooView,
  AutonomyView,
  ProfitView,
  PredictionsView,
  ValidationView,
} from './views/SecondaryViews'

const emptyData = {
  status: null,
  autonomy: null,
  signals: null,
  universe: null,
  learning: null,
  performance: null,
  pnl: null,
  audit: null,
  dataStatus: null,
  factors: null,
  moomoo: null,
  moomooAccount: null,
}

export default function App() {
  const [active, setActive] = useState('overview')
  const [data, setData] = useState(emptyData)
  const [busy, setBusy] = useState({ initial: true, refresh: false, learning: false, universe: false, broker: false })
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [selectedSignal, setSelectedSignal] = useState(null)

  const load = useCallback(async () => {
    try {
      const [status, autonomy, signals, universe, learning, performance, pnl, audit, dataStatus, factors, moomoo, moomooAccount] = await Promise.all([
        api.status(), api.autonomy(), api.signals(), api.universe(), api.learning(), api.performance(), api.pnl(), api.audit(), api.data(), api.factors(), api.moomoo(), api.moomooAccount().catch(() => null),
      ])
      setData({ status, autonomy, signals, universe, learning, performance, pnl, audit, dataStatus, factors, moomoo, moomooAccount })
      setError('')
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, initial: false }))
    }
  }, [])

  useEffect(() => {
    load()
    const timer = window.setInterval(load, 30_000)
    return () => window.clearInterval(timer)
  }, [load])

  async function refreshPredictions() {
    setBusy((current) => ({ ...current, refresh: true }))
    setNotice('')
    try {
      const result = await api.refreshPredictions()
      setNotice(result.message || '预测已刷新')
      await load()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, refresh: false }))
    }
  }

  async function runLearning() {
    setBusy((current) => ({ ...current, learning: true }))
    try {
      await api.runLearning()
      setNotice('学习评估已完成；不满足证据门槛时不会替换模型')
      await load()
    } finally {
      setBusy((current) => ({ ...current, learning: false }))
    }
  }

  async function syncUniverse() {
    setBusy((current) => ({ ...current, universe: true }))
    try {
      await api.syncUniverse()
      setNotice('证券主表已同步')
      await load()
    } finally {
      setBusy((current) => ({ ...current, universe: false }))
    }
  }

  async function submitSimulationOrder(order) {
    setBusy((current) => ({ ...current, broker: true }))
    setNotice('')
    try {
      const result = await api.submitMoomooOrder(order)
      setNotice(`模拟委托已提交：${result.code} ${result.side} ${result.quantity}股 · ${result.status}`)
      await load()
      return result
    } catch (requestError) {
      setError(requestError.message)
      throw requestError
    } finally {
      setBusy((current) => ({ ...current, broker: false }))
    }
  }

  async function setTTradingEnabled(enabled) {
    setBusy((current) => ({ ...current, broker: true }))
    try {
      await api.updateTTrading({ enabled })
      setNotice(enabled ? '自动做T训练已启用：仅模拟盘' : '自动做T训练已暂停')
      await load()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, broker: false }))
    }
  }

  const actions = useMemo(() => ({
    selectSignal: setSelectedSignal,
    refreshPredictions,
    runLearning,
    syncUniverse,
    submitSimulationOrder,
    setTTradingEnabled,
  }), [data]) // eslint-disable-line react-hooks/exhaustive-deps

  const views = {
    overview: <Overview data={data} actions={actions} />,
    predictions: <PredictionsView signals={data.signals} onSelect={setSelectedSignal} />,
    simulation: <MoomooView moomoo={data.moomoo} account={data.moomooAccount} universe={data.universe} onSubmit={submitSimulationOrder} onToggle={setTTradingEnabled} busy={busy.broker} />,
    profit: <ProfitView pnl={data.pnl} account={data.moomooAccount} />,
    autonomy: <AutonomyView autonomy={data.autonomy} moomoo={data.moomoo} account={data.moomooAccount} />,
    validation: <ValidationView performance={data.performance} />,
    factors: <FactorsView factors={data.factors} signals={data.signals} />,
    data: <DataView dataStatus={data.dataStatus} universe={data.universe} onSync={syncUniverse} busy={busy.universe} />,
    learning: <LearningView learning={data.learning} onRun={runLearning} busy={busy.learning} />,
    audit: <AuditView audit={data.audit} />,
  }

  return (
    <div className="app-shell">
      <Sidebar active={active} onChange={setActive} />
      <div className="workspace">
        <Topbar status={data.status} busy={busy.refresh} onRefresh={refreshPredictions} />
        <main className="main-content">
          {error && <div className="message-banner error">服务异常：{error}</div>}
          {notice && <div className="message-banner success">{notice}</div>}
          {busy.initial ? <div className="loading-state">正在载入预测工作站…</div> : views[active]}
        </main>
        <footer className="status-footer">
          <span>范围：Nasdaq-100当前成分证券</span>
          <span>预测周期：5个交易日</span>
          <span>数据：<b>{data.status?.system?.demoData ? '合成演示' : data.moomoo?.connected ? 'Moomoo模拟盘' : '等待OpenD'}</b></span>
          <span>后台：<b>{data.autonomy?.healthy ? '30秒心跳正常' : '检查中'}</b></span>
          <span>Built by <b>LAI ZEYU</b></span>
          <strong>真实盘永久禁用 · 不构成投资建议</strong>
        </footer>
      </div>
      <SignalDrawer signal={selectedSignal} onClose={() => setSelectedSignal(null)} />
    </div>
  )
}
