// leaflet.markercluster 與 Geoman 這類外掛是靠全域變數 L 掛上去的。
// 打包後各模組的初始化順序不保證 Leaflet 先把 window.L 設好，所以在這裡明確設定，
// 外掛一律在這個檔案之後、用動態載入的方式掛上（見 loadCluster）。
import L from 'leaflet'

window.L = L
export default L

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
