import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from './api'
import Sidebar from './components/Sidebar'
import SignalDrawer from './components/SignalDrawer'
import Topbar from './components/Topbar'
import Overview from './views/Overview'
import {
  AuditView,
  AboutView,
  ConsistencyView,
  DataView,
  FactorsView,
  IntegrityView,
  PrivacyView,
  ScenariosView,
} from './views/SecondaryViews'

const emptyData = {
  health: null,
  status: null,
  signals: null,
  universe: null,
  integrity: null,
  performance: null,
  audit: null,
  dataStatus: null,
  factors: null,
  privacy: null,
}

export default function App() {
  const [active, setActive] = useState('overview')
  const [data, setData] = useState(emptyData)
  const [busy, setBusy] = useState({ initial: true, verify: false, integrity: false, privacy: false, deleting: false })
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [selectedSignal, setSelectedSignal] = useState(null)
  const [coreApiReady, setCoreApiReady] = useState(false)
  const closeSignal = useCallback(() => setSelectedSignal(null), [])

  const load = useCallback(async () => {
    try {
      const [health, status, signals, universe, integrity, performance, audit, dataStatus, factors, privacy] = await Promise.all([
        api.health(), api.status(), api.signals(), api.universe(), api.integrity(), api.performance(), api.audit(), api.data(), api.factors(), api.privacy(),
      ])
      const ready = health?.ok === true
        && health?.storeReadOnly === true
        && health?.executionEnabled === false
        && status?.system?.storeReadOnly === true
        && status?.system?.dataMode === 'DETERMINISTIC_SYNTHETIC_SCENARIO'
        && Array.isArray(signals?.items) && signals.items.length > 0
        && Array.isArray(universe?.items) && universe.items.length > 0
        && dataStatus?.dataMode === 'DETERMINISTIC_SYNTHETIC_SCENARIO'
      if (!ready) throw new Error('核心只读说明性数据 API 未通过完整性检查')
      setData({ health, status, signals, universe, integrity, performance, audit, dataStatus, factors, privacy })
      setCoreApiReady(true)
      setError('')
    } catch (requestError) {
      setCoreApiReady(false)
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

  async function verifyScenario() {
    setBusy((current) => ({ ...current, verify: true }))
    setNotice('')
    try {
      const result = await api.verifyScenario()
      setNotice(result.message || '说明性情景已核对')
      await load()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, verify: false }))
    }
  }

  async function runIntegrityCheck() {
    setBusy((current) => ({ ...current, integrity: true }))
    try {
      await api.runIntegrityCheck()
      setNotice('说明性生成文件完整性核对完成；应用不训练或替换模型')
      await load()
    } finally {
      setBusy((current) => ({ ...current, integrity: false }))
    }
  }

  async function updatePrivacy(settings) {
    setBusy((current) => ({ ...current, privacy: true }))
    try {
      await api.updatePrivacy(settings)
      setNotice('隐私选择已保存在本机')
      await load()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, privacy: false }))
    }
  }

  async function deleteLocalData() {
    if (!window.confirm('删除 Quant Scenario Studio 的全部本地运行数据？合成演示数据和应用本身会保留。')) return
    setBusy((current) => ({ ...current, deleting: true }))
    try {
      const result = await api.deleteLocalData()
      setNotice(result.message)
      await load()
    } catch (requestError) {
      setError(requestError.message)
    } finally {
      setBusy((current) => ({ ...current, deleting: false }))
    }
  }

  const actions = useMemo(() => ({
    selectSignal: setSelectedSignal,
    verifyScenario,
    runIntegrityCheck,
    updatePrivacy,
    deleteLocalData,
  }), [data]) // eslint-disable-line react-hooks/exhaustive-deps

  const views = {
    overview: <Overview data={data} actions={actions} />,
    scenarios: <ScenariosView signals={data.signals} onSelect={setSelectedSignal} />,
    consistency: <ConsistencyView performance={data.performance} />,
    factors: <FactorsView factors={data.factors} signals={data.signals} />,
    data: <DataView dataStatus={data.dataStatus} universe={data.universe} />,
    integrity: <IntegrityView integrity={data.integrity} onRun={runIntegrityCheck} busy={busy.integrity} />,
    audit: <AuditView audit={data.audit} />,
    privacy: <PrivacyView privacy={data.privacy} onPrivacy={updatePrivacy} onDelete={deleteLocalData} busy={busy.privacy} deleting={busy.deleting} />,
    about: <AboutView />,
  }

  return (
    <div
      className="app-shell"
      data-product="Quant Scenario Studio by LAI ZEYU"
      data-author="LAI ZEYU（来泽宇）"
      data-store-read-only="true"
      data-privacy="local-only-no-telemetry"
      data-demo="deterministic-synthetic-2026-08-26"
      data-language="zh-CN"
    >
      {coreApiReady && <span id="store-readiness" className="visually-hidden" data-api-health="true" data-core-data="true">Quant Scenario Studio by LAI ZEYU · LAI ZEYU（来泽宇） · Store 只读 · API 健康 · 核心说明性数据已载入 · 隐私：本机且无遥测 · 2026-08-26 确定性合成演示</span>}
      <Sidebar active={active} onChange={setActive} />
      <div className="workspace">
        <Topbar status={data.status} busy={busy.verify} onRefresh={verifyScenario} />
        <main className="main-content">
          {!busy.initial && !data.privacy?.researchNoticeAccepted && (
            <div className="message-banner notice" role="status">
              本软件仅用于研究、教育与合成模拟，不提供下单，不构成投资建议。
              <button type="button" onClick={() => setActive('privacy')}>阅读并确认</button>
            </div>
          )}
          {error && <div className="message-banner error">服务异常：{error}</div>}
          {notice && <div className="message-banner success">{notice}</div>}
          {busy.initial ? <div className="loading-state">正在载入说明性情景工作站…</div> : views[active]}
        </main>
        <footer className="status-footer">
          <span>范围：Nasdaq-100 2026-08-26 成分快照</span>
          <span>生成方法：稳定 SHA-256 哈希</span>
          <span>数据：<b>确定性合成演示（非真实行情）</b></span>
          <span>版本：<b>Windows Store Read-Only</b></span>
          <span>研究引擎：<b>Aegis Forecast</b></span>
          <span>作者：<b>LAI ZEYU（来泽宇）</b></span>
          <strong>Store 包不含交易或自动执行模块 · 不构成投资建议</strong>
        </footer>
      </div>
      <SignalDrawer signal={selectedSignal} onClose={closeSignal} />
    </div>
  )
}
