// leaflet.markercluster 與 Geoman 這類外掛是靠全域變數 L 掛上去的。
// 打包後各模組的初始化順序不保證 Leaflet 先把 window.L 設好，所以在這裡明確設定，
// 外掛一律在這個檔案之後、用動態載入的方式掛上（見 loadCluster）。
import L from 'leaflet'

window.L = L
export default L

/**
 * OpenStreetMap 底圖。
 * - 以 CORS 載入（crossOrigin），Service Worker 才能只快取成功的圖磚。
 * - 圖磚載入失敗會自動重試兩次，網址加上參數繞過可能壞掉的快取；OSM 偶爾會限流或逾時。
 * - 手機上拖曳途中就開始載入新的圖磚（updateWhenIdle: false），不用等放開手指。
 */
export function baseLayer() {
  const layer = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, crossOrigin: true, updateWhenIdle: false, keepBuffer: 3,
    attribution: '© OpenStreetMap contributors',
  })
  layer.on('tileerror', (e) => {
    const img = e.tile
    const n = Number(img.dataset.retry || 0)
    if (n >= 2 || !img.src) return
    img.dataset.retry = n + 1
    setTimeout(() => { if (img.isConnected) img.src = `${layer.getTileUrl(e.coords)}?r=${n + 1}` }, 800 * (n + 1))
  })
  return layer
}

let clusterReady = null
/** 載入標記叢集外掛（只載一次） */
export function loadCluster() {
  clusterReady ||= import('leaflet.markercluster')
  return clusterReady
}
let geomanReady = null
/** 載入 Geoman 繪圖外掛（只載一次） */
export function loadGeoman() {
  geomanReady ||= import('@geoman-io/leaflet-geoman-free')
  return geomanReady
}
