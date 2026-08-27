async function request(path, options = {}) {
  const method = String(options.method || 'GET').toUpperCase()
  const csrf = document.querySelector('meta[name="aegis-csrf-token"]')?.content || ''
  const headers = { ...(options.headers || {}) }
  if (method !== 'GET' && method !== 'HEAD') {
    headers['Content-Type'] = 'application/json'
    headers['X-Aegis-CSRF'] = csrf
  }
  const response = await fetch(path, {
    credentials: 'same-origin',
    ...options,
    headers,
  })
  const payload = await response.json()
  if (!response.ok) throw new Error(payload.error || payload.message || `请求失败：${response.status}`)
  return payload
}

export const api = {
  health: () => request('/api/health'),
  status: () => request('/api/status'),
  signals: () => request('/api/signals?limit=200'),
  universe: (query = '') => request(`/api/universe?limit=200&q=${encodeURIComponent(query)}`),
  integrity: () => request('/api/integrity'),
  performance: () => request('/api/performance'),
  audit: () => request('/api/audit'),
  data: () => request('/api/data'),
  factors: () => request('/api/factors'),
  privacy: () => request('/api/privacy'),
  updatePrivacy: (settings) => request('/api/privacy', { method: 'POST', body: JSON.stringify(settings) }),
  deleteLocalData: () => request('/api/privacy/delete-local-data', { method: 'POST', body: JSON.stringify({ confirm: 'DELETE_LOCAL_DATA' }) }),
  verifyScenario: () => request('/api/scenario/verify', { method: 'POST', body: '{}' }),
  runIntegrityCheck: () => request('/api/integrity/run', { method: 'POST', body: '{}' }),
}
