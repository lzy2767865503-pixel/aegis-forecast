async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  })
  const payload = await response.json()
  if (!response.ok) throw new Error(payload.error || payload.message || `请求失败：${response.status}`)
  return payload
}

export const api = {
  status: () => request('/api/status'),
  autonomy: () => request('/api/autonomy'),
  signals: () => request('/api/signals?limit=200'),
  universe: (query = '') => request(`/api/universe?limit=200&q=${encodeURIComponent(query)}`),
  learning: () => request('/api/learning'),
  performance: () => request('/api/performance'),
  pnl: () => request('/api/pnl/history'),
  audit: () => request('/api/audit'),
  data: () => request('/api/data'),
  factors: () => request('/api/factors'),
  moomoo: () => request('/api/moomoo/status'),
  moomooAccount: () => request('/api/moomoo/account'),
  submitMoomooOrder: (order) => request('/api/moomoo/orders', { method: 'POST', body: JSON.stringify(order) }),
  updateTTrading: (policy) => request('/api/moomoo/t-trading', { method: 'POST', body: JSON.stringify(policy) }),
  refreshPredictions: () => request('/api/predictions/refresh', { method: 'POST', body: '{}' }),
  syncUniverse: () => request('/api/universe/sync', { method: 'POST', body: '{}' }),
  runLearning: () => request('/api/learning/run', { method: 'POST', body: '{}' }),
}
