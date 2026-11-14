// 離線打卡（FR-1.5）：沒有網路時把餵食紀錄存在手機的 IndexedDB，恢復連線後自動補傳。
// 每筆紀錄在建立當下就產生 client_id（UUID）；補傳時伺服器以它去重，重送幾次都只會有一筆。
import { reactive } from 'vue'
import { supabase } from './supabase'
import { auth } from './auth'

const DB = 'pawlink', STORE = 'feedings'
/** count：這支手機上還沒補傳的筆數；online：瀏覽器回報的連線狀態 */
export const net = reactive({ online: typeof navigator === 'undefined' ? true : navigator.onLine, count: 0, flushing: false })
const listeners = new Set()
/** 補傳成功後通知畫面重新整理 */
export const onFlushed = (fn) => { listeners.add(fn); return () => listeners.delete(fn) }

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'client_id' })
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}
async function tx(mode, fn) {
  const db = await open()
  try {
    return await new Promise((resolve, reject) => {
      const t = db.transaction(STORE, mode)
      const r = fn(t.objectStore(STORE))
      t.oncomplete = () => resolve(r?.result)
      t.onerror = () => reject(t.error)
      t.onabort = () => reject(t.error)
    })
  } finally { db.close() }
}
const all = () => tx('readonly', (s) => s.getAll())
const remove = (id) => tx('readwrite', (s) => s.delete(id))
async function refresh() {
  try { net.count = (await all()).filter((x) => !auth.user || x.user_id === auth.user.id).length } catch { net.count = 0 }
}

/** 連不上伺服器（不是被伺服器拒絕）。supabase-js 遇到斷線時回傳沒有 code 的 fetch 錯誤 */
export function isNetworkError(e) {
  if (typeof navigator !== 'undefined' && !navigator.onLine) return true
  return !e?.code && /failed to fetch|networkerror|load failed|network request failed|fetch failed/i.test(String(e?.message || e))
}

/**
 * 伺服器明確拒絕這筆資料本身（重送幾次結果都一樣）：
 * 違反檢查限制（例如超過 7 天）、餵食點已刪除、資料格式不對，或被 RLS 擋下（餵食點已停用）。
 * 其他錯誤（登入過期、沒有權限呼叫、5xx、請求過多）都可能只是暫時的，不能因此丟掉紀錄。
 */
export function isPermanentError(e) {
  const code = String(e?.code || '')
  if (['23514', '23503', '23502', '22P02', '22023', '22007', '22008'].includes(code)) return true
  return code === '42501' && /row-level security/i.test(String(e?.message || ''))
}

export async function enqueueFeeding(item) {
  await tx('readwrite', (s) => s.put(item))
  await refresh()
}

/** 把排隊中的紀錄送出。回傳 { sent, dropped }；dropped 是被伺服器拒絕而放棄的（例如餵食點已停用、超過 7 天） */
export async function flushQueue() {
  if (!supabase || !auth.user || net.flushing) return { sent: 0, dropped: [] }
  net.flushing = true
  let sent = 0
  const dropped = []
  try {
    const items = (await all()).filter((x) => x.user_id === auth.user.id).sort((a, b) => a.fed_at.localeCompare(b.fed_at))
    for (const it of items) {
      const { error } = await supabase.rpc('record_feeding', {
        p_spot_id: it.spot_id, p_food_type: it.food_type, p_note: it.note || null, p_fed_at: it.fed_at, p_client_id: it.client_id,
      })
      if (!error) { await remove(it.client_id); sent++; continue }
      // 只有確定重送也不會成功的才放棄；登入過期、伺服器忙碌這類暫時性的錯誤一律留著下次再試
      if (!isPermanentError(error)) { console.warn('補傳暫時失敗，下次再試', error); break }
      await remove(it.client_id)
      dropped.push({ ...it, reason: error.message })
    }
  } catch (e) { console.warn('補傳失敗', e) } finally {
    net.flushing = false
    await refresh()
  }
  if (sent || dropped.length) listeners.forEach((fn) => fn({ sent, dropped }))
  return { sent, dropped }
}

export function initOfflineQueue() {
  if (typeof window === 'undefined' || !('indexedDB' in window)) return
  window.addEventListener('online', () => { net.online = true; flushQueue() })
  window.addEventListener('offline', () => { net.online = false })
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && navigator.onLine) flushQueue() })
  refresh().then(() => { if (navigator.onLine) flushQueue() })
}
export { refresh as refreshQueueCount }
