import { supabase } from './supabase'
import { mockSpots } from './mockSpots'
import { isNetworkError } from './offlineQueue'

// 上次載入的餵食點留一份在手機，離線時地圖還看得到（登出時清掉，見 auth.js）
const KEY = 'pawlink:spots'
let cache = null
function load() {
  if (cache) return cache
  try { cache = JSON.parse(localStorage.getItem(KEY) || '{}') } catch { cache = {} }
  return cache
}
function remember(spots) {
  const c = load()
  const now = Date.now()
  for (const s of spots) c[s.id] = { ...s, _at: now }
  const ids = Object.keys(c)
  if (ids.length > 600) ids.sort((a, b) => c[a]._at - c[b]._at).slice(0, ids.length - 600).forEach((id) => delete c[id])
  try { localStorage.setItem(KEY, JSON.stringify(c)) } catch { /* 空間不足就不存 */ }
}
export const cachedSpot = (id) => load()[id] || null
export function clearSpotCache() { cache = {}; try { localStorage.removeItem(KEY) } catch { /* ignore */ } }

/**
 * 取得視窗內餵食點。有 Supabase 設定走 RPC，否則假資料。
 * 連不上伺服器時回傳上次載入、落在視窗內的點，並標記 offline。
 */
export async function fetchMapSpots(bounds) {
  if (!supabase) return mockSpots
  const { data, error } = await supabase.rpc('get_map_spots', {
    min_lng: bounds.getWest(),
    min_lat: bounds.getSouth(),
    max_lng: bounds.getEast(),
    max_lat: bounds.getNorth(),
  })
  if (error) {
    if (!isNetworkError(error)) throw error
    const list = Object.values(load()).filter((s) => bounds.contains([s.lat, s.lng]))
    list.offline = true
    return list
  }
  remember(data)
  return data
}
