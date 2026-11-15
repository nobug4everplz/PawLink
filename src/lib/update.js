// 新版上線後的更新處理。
// 1. Service Worker：有新版就接手並重新整理頁面；App 回到前景時、以及每 30 分鐘檢查一次。
// 2. 舊頁面要載入的分頁程式在新版部署後已經不存在（伺服器回的是 index.html），
//    這時直接重新整理到目標頁，讓使用者拿到新版，而不是只看到錯誤訊息。
import { registerSW } from 'virtual:pwa-register'

const KEY = 'pawlink:reloaded-at'

/** 是不是「分頁程式載入失敗」這類錯誤（各家瀏覽器的訊息不同） */
export function isChunkError(e) {
  return /dynamically imported module|importing a module script failed|error loading dynamically imported|is not a valid javascript mime type|unable to preload css|failed to load module script/i.test(String(e?.message || e || ''))
}

/**
 * 重新整理到指定路徑。30 秒內已經重整過就不再重整（避免真的沒網路時一直轉），回傳 false。
 */
export function reloadForUpdate(path) {
  let last = 0
  try { last = Number(sessionStorage.getItem(KEY)) || 0 } catch { /* ignore */ }
  if (Date.now() - last < 30e3) return false
  try { sessionStorage.setItem(KEY, String(Date.now())) } catch { /* ignore */ }
  if (path) window.location.assign(path)
  else window.location.reload()
  return true
}

export function initUpdates() {
  if (!('serviceWorker' in navigator)) return
  registerSW({
    immediate: true,
    onRegisteredSW(_url, reg) {
      if (!reg) return
      const check = () => { if (navigator.onLine) reg.update().catch(() => {}) }
      setInterval(check, 30 * 60e3)
      document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') check() })
    },
  })
}
