import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import 'vant/lib/index.css'
import 'leaflet/dist/leaflet.css'
import 'leaflet.markercluster/dist/MarkerCluster.css'
import 'leaflet.markercluster/dist/MarkerCluster.Default.css'
import './style.css'
import { showToast, Locale } from 'vant'
import zhTW from 'vant/es/locale/lang/zh-TW'

Locale.use('zh-TW', zhTW) // Vant 預設是簡體中文

import { initOfflineQueue } from './lib/offlineQueue'

const app = createApp(App)
// 避免任何錯誤造成整頁白畫面：顯示訊息並留在原頁
app.config.errorHandler = (err) => { console.error(err); showToast('發生錯誤：' + (err?.message || err)) }
window.addEventListener('unhandledrejection', (e) => { console.error(e.reason); showToast('發生錯誤：' + (e.reason?.message || e.reason)) })
app.use(router).mount('#app')
initOfflineQueue()
// Android／桌面 Chrome 的安裝事件可能在安裝教學頁載入前就觸發，先留著
window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); window.__pwaPrompt = e })
