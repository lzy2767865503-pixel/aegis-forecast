import { X } from 'lucide-react'
import { useEffect, useRef } from 'react'

function pct(value) {
  return value === null || value === undefined ? '—' : `${(value * 100).toFixed(1)}%`
}

function price(value) {
  return value === null || value === undefined ? '—' : Number(value).toFixed(3).replace(/0+$/, '').replace(/\.$/, '')
}

export default function SignalDrawer({ signal, onClose }) {
  const dialogRef = useRef(null)
  const closeRef = useRef(null)
  const previousFocusRef = useRef(null)

  useEffect(() => {
    if (!signal) return undefined
    previousFocusRef.current = document.activeElement
    closeRef.current?.focus()
    function onKeyDown(event) {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }
      if (event.key !== 'Tab') return
      const focusable = [...(dialogRef.current?.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])') || [])]
        .filter((element) => !element.disabled && element.getAttribute('aria-hidden') !== 'true')
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      previousFocusRef.current?.focus?.()
    }
  }, [signal, onClose])

  if (!signal) return null
  const observation = signal.observationScenario || {}
  const invalidation = signal.invalidationScenario || {}
  return (
    <div className="drawer-backdrop" onClick={onClose}>
      <aside ref={dialogRef} className="signal-drawer" role="dialog" aria-modal="true" aria-labelledby="signal-drawer-title" aria-describedby="signal-drawer-notice" onClick={(event) => event.stopPropagation()}>
        <button ref={closeRef} className="drawer-close" aria-label="关闭详情" onClick={onClose}><X size={18} /></button>
        <span className="drawer-code">{signal.code} · {signal.date}</span>
        <h2 id="signal-drawer-title">{signal.name}</h2>
        <p>{signal.strategy} · 情景生成标签 {signal.scenarioState}</p>
        <div className="drawer-score"><strong>{signal.technicalScore.toFixed(1)}</strong><span>综合技术分</span></div>
        <dl className="drawer-details">
          <div><dt>说明性上行分数</dt><dd>{pct(signal.scenarioUpScore)}</dd></div>
          <div><dt>说明性形态分数</dt><dd>{pct(signal.scenarioPatternScore)}</dd></div>
          <div><dt>关联生成结果行</dt><dd>{signal.illustrativeOutcomeRows || '—'}</dd></div>
          <div><dt>说明性变化比率</dt><dd>{signal.variationPct?.toFixed(2)}%</dd></div>
          <div><dt>说明性参考值</dt><dd>{signal.referenceValue || '—'}</dd></div>
          <div><dt>确认阈值</dt><dd>{signal.confirmationLevel || '—'}</dd></div>
          <div><dt>结构参考阈值</dt><dd>{signal.structuralReferenceLevel || '—'}</dd></div>
          <div><dt>失效阈值</dt><dd>{signal.invalidationLevel || '—'}</dd></div>
        </dl>
        <div className="scenario-stack">
          <section className="scenario-card observation-scenario">
            <div><h3>观察阈值</h3><span>{observation.state === 'ABOVE_CONFIRMATION' ? '高于确认阈值' : observation.state === 'WAIT_CONFIRMATION' ? '待验证' : '仅观察'}</span></div>
            <dl><div><dt>确认阈值</dt><dd>{price(observation.confirmationLevel)}</dd></div><div><dt>参考区间</dt><dd>{price(observation.referenceZoneLow)} – {price(observation.referenceZoneHigh)}</dd></div></dl>
            <p>{observation.description || '等待合成情景验证'}</p>
          </section>
          <section className="scenario-card invalidation-scenario">
            <div><h3>失效与敏感度</h3><span>研究参数</span></div>
            <dl><div><dt>失效阈值</dt><dd>{price(invalidation.invalidationLevel)}</dd></div><div><dt>敏感度层1</dt><dd>{price(invalidation.sensitivityLevel1)}</dd></div><div><dt>敏感度层2</dt><dd>{price(invalidation.sensitivityLevel2)}</dd></div><div><dt>数值性质</dt><dd>稳定哈希生成</dd></div></dl>
            <p>{(invalidation.notes || []).join('；') || '仅用于合成情景敏感度研究。'}</p>
          </section>
        </div>
        <div className="factor-mini-grid">
          {Object.entries(signal.factors || {}).map(([name, value]) => (
            <div key={name}><span>{name}</span><b>{value.toFixed(1)}</b><i><em style={{ width: `${value}%` }} /></i></div>
          ))}
        </div>
        <div className="drawer-reasons"><h3>{signal.selected ? '研究样本理由' : '证据不足原因'}</h3>{(signal.rejectionReasons || []).map((reason) => <span key={reason}>{reason}</span>)}</div>
        <div id="signal-drawer-notice" className="drawer-notice">确定性合成演示，非真实行情。阈值只用于理解说明性情景数值敏感度，不对应任何个性化操作或资金安排，不构成投资建议。</div>
      </aside>
    </div>
  )
}
