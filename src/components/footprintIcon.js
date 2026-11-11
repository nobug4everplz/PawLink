import L from '../lib/leaflet'

// 腳印顏色：新鮮(6h內)綠、普通黃、久未餵食(24h+)紅
const COLORS = { fresh: '#2f9e6b', recent: '#f2b705', hungry: '#e03e3e' }

export function footprintIcon(state = 'hungry') {
  const c = COLORS[state] ?? COLORS.hungry
  return L.divIcon({
    className: 'paw-icon',
    iconSize: [34, 34],
    iconAnchor: [17, 17],
    html: `<div style="width:34px;height:34px;border-radius:50%;background:#fff;border:3px solid ${c};display:flex;align-items:center;justify-content:center;font-size:18px;box-shadow:0 1px 4px rgba(0,0,0,.35)">🐾</div>`,
  })
}
