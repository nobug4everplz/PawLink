import L from '../lib/leaflet'

// 腳印顏色：新鮮(6h內)綠、普通琥珀、久未餵食(24h+)紅
export const FOOT_COLOR = { fresh: '#1f8459', recent: '#e39b00', hungry: '#d9482f' }
const PAW = '<svg viewBox="0 0 24 24" aria-hidden="true"><ellipse cx="5" cy="10.5" rx="2.3" ry="3"/><ellipse cx="9.6" cy="5.6" rx="2.3" ry="3.1"/><ellipse cx="14.4" cy="5.6" rx="2.3" ry="3.1"/><ellipse cx="19" cy="10.5" rx="2.3" ry="3"/><path d="M12 11.2c-3.2 0-6 3.3-6 6 0 1.9 1.5 2.8 3.1 2.8 1.2 0 1.9-.6 2.9-.6s1.7.6 2.9.6c1.6 0 3.1-.9 3.1-2.8 0-2.7-2.8-6-6-6z"/></svg>'

/**
 * 餵食點標記。可以傳整個餵食點（會多顯示「已結紮／總數」小標），也可以只傳狀態字串。
 * 小標的數字來自資料庫，只是數字，不含使用者輸入的文字。
 */
export function footprintIcon(spot = 'hungry') {
  const state = typeof spot === 'string' ? spot : spot?.footprint
  const key = FOOT_COLOR[state] ? state : 'hungry'
  const total = Number(spot?.animal_count) || 0, done = Number(spot?.sterilized_count) || 0
  const ster = total ? `<span class="ster${done >= total ? ' all' : ''}">✂ ${done}/${total}</span>` : ''
  return L.divIcon({
    className: '',
    iconSize: [44, 54],
    iconAnchor: [22, 44],
    html: `<div class="paw-pin ${key}" style="--c:${FOOT_COLOR[key]}"><div class="drop"></div>${PAW}${ster}</div>`,
  })
}
