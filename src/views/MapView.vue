<script setup>
import { onMounted, onBeforeUnmount, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import L, { loadCluster, baseLayer } from '../lib/leaflet'
import { showToast } from 'vant'
import { auth } from '../lib/auth'
import { fetchMapSpots } from '../lib/spots'
import { net, flushQueue, onFlushed, refreshQueueCount } from '../lib/offlineQueue'
import { subscribeFeeding, getSpotSummary, getPendingCleanups, getZones } from '../lib/api'
import { footprintIcon } from '../components/footprintIcon'
import SpotPanel from '../components/SpotPanel.vue'
import { refreshBadges } from '../lib/badges'

const route = useRoute(), router = useRouter()
const mapEl = ref(null)
const selectedId = ref(null)
const showPanel = ref(false)
const refreshKey = ref(0)
const pending = ref([]) // 我還沒回報清理的餵食（餵食後 30 分鐘～24 小時）
let map, cluster, meMarker, timer, rtTimer, unsub, pendingTimer, zoneLayer, zoneBounds, offFlushed
let loadSeq = 0
let fixSize = () => {}
const showingCached = ref(false)
const showInstall = ref(false)
const zoneCount = ref(0)
const filter = ref('all') // 地圖上方的篩選：all 或某一種腳印狀態
const tally = ref({ all: 0, hungry: 0, recent: 0, fresh: 0 }) // 目前視窗內各狀態的餵食點數
const FILTERS = [['all', '全部'], ['hungry', '久未餵食'], ['recent', '一陣子前'], ['fresh', '剛餵過']]
let spots = []

async function loadSpots() {
  if (!map) return // 已離開頁面
  const seq = ++loadSeq
  try {
    const list = await fetchMapSpots(map.getBounds())
    if (!map || seq !== loadSeq) return // 地圖又移動過，這份結果已經過時
    spots = list
    showingCached.value = !!spots.offline
    cluster.clearLayers()
    for (const s of spots) {
      if (filter.value !== 'all' && s.footprint !== filter.value) continue
      const m = L.marker([s.lat, s.lng], { icon: footprintIcon(s), title: s.name, alt: s.name })
      m.on('click', () => select(s.id))
      cluster.addLayer(m)
    }
    const n = { all: spots.length, hungry: 0, recent: 0, fresh: 0 }
    for (const s of spots) if (s.footprint in n) n[s.footprint]++
    tally.value = n
  } catch (e) { showToast('載入餵食點失敗：' + e.message) }
}
/** 手動補傳離線紀錄 */
async function flushNow() {
  if (!net.online) return showToast('還沒有網路，恢復連線後會自動補傳')
  const r = await flushQueue()
  if (!r.sent && !r.dropped.length && net.count) showToast('還連不上伺服器，稍後會再試')
}
/** 保育熱區：紅色為範圍、黃色虛線為 200 公尺警示帶。不攔截點擊，長按建點照常可用 */
async function loadZones() {
  const zones = await getZones()
  if (!map) return
  zoneLayer.clearLayers()
  for (const z of zones) {
    L.geoJSON(z.buffer_geojson, { interactive: false, style: { color: '#d99a00', weight: 1.5, dashArray: '6 6', fillColor: '#f2b705', fillOpacity: 0.12 } }).addTo(zoneLayer)
    // Leaflet 會把字串當成 HTML 插入，熱區名稱是使用者輸入的文字，改用文字節點
    const label = document.createElement('span')
    label.textContent = `保育熱區：${z.name}${z.is_demo ? '（示意）' : ''}`
    L.geoJSON(z.geojson, { interactive: false, style: { color: '#e03e3e', weight: 2, fillColor: '#e03e3e', fillOpacity: 0.18 } })
      .bindTooltip(label, { permanent: true, direction: 'center', className: 'zone-label' })
      .addTo(zoneLayer)
  }
  zoneCount.value = zones.length
  zoneBounds = zones.length ? L.geoJSON(zones.map((x) => x.geojson)).getBounds() : null
  zoneLabels()
  // 從宣導頁點熱區過來：縮放到該熱區
  const z = route.query.zone && zones.find((x) => x.id === route.query.zone)
  if (z) map.fitBounds(L.geoJSON(z.geojson).getBounds(), { padding: [24, 24] })
}
/** 縮到全臺時熱區名稱會疊在一起，縮放 10 以下先藏起來 */
function showAllZones() { if (zoneBounds) map.fitBounds(zoneBounds, { padding: [24, 24] }) }
function zoneLabels() { mapEl.value?.classList.toggle('hide-zone-labels', map.getZoom() < 10) }
function select(id) { selectedId.value = id; showPanel.value = true }
async function loadPending() {
  if (!auth.user) { pending.value = []; return }
  try { pending.value = await getPendingCleanups() } catch { /* 提醒載入失敗不影響地圖 */ }
}
/** 通知、輪值、接力、領養的待辦數字改由底部分頁列顯示（見 lib/badges.js） */
function loadInbox() { refreshBadges() }
function setFilter(f) { filter.value = filter.value === f ? 'all' : f; loadSpots() }
function onChanged() { loadSpots(); loadPending() }
/** 點清理提醒：跳到最早一筆未清理的餵食點並開啟面板 */
async function goPending() {
  const p = pending.value[0]
  if (!p) return
  try {
    const s = await getSpotSummary(p.spot_id)
    if (s?.lat != null) map.setView([s.lat, s.lng], 17)
  } catch { /* 定位不到仍開面板 */ }
  select(p.spot_id)
}

function locate() { map.locate({ setView: true, maxZoom: 17, enableHighAccuracy: true }) }

function addSpotAt(latlng) {
  if (!auth.user) return router.push({ name: 'login', query: { redirect: '/' } })
  router.push({ name: 'spot-new', query: { lat: latlng.lat, lng: latlng.lng } })
}
/** 以 GPS 位置新增：沒有定位就用地圖中心 */
function addHere() { addSpotAt(meMarker ? meMarker.getLatLng() : map.getCenter()) }

onMounted(async () => {
  await loadCluster()
  if (!mapEl.value) return // 外掛載入期間已離開頁面
  map = L.map(mapEl.value, { zoomControl: false }).setView([25.0174, 121.5398], 15)
  baseLayer().addTo(map)
  // 容器大小在建立地圖後才定下來時（加入主畫面、轉向、從背景回來），要請 Leaflet 重新計算，否則會有一塊不載入圖磚
  fixSize = () => map?.invalidateSize()
  requestAnimationFrame(fixSize); setTimeout(fixSize, 600)
  window.addEventListener('pageshow', fixSize); window.addEventListener('orientationchange', fixSize); document.addEventListener('visibilitychange', fixSize)
  // iPhone：在地圖頁的按鈕區用兩指縮放會把整個頁面放大而且縮不回去；地圖本身的縮放不受影響
  mapEl.value.parentElement.addEventListener('gesturestart', (e) => e.preventDefault())
  cluster = L.markerClusterGroup({ showCoverageOnHover: false, maxClusterRadius: 50 })
  map.addLayer(cluster)
  zoneLayer = L.layerGroup().addTo(map)
  loadZones()

  map.on('locationfound', (e) => {
    if (meMarker) meMarker.remove()
    meMarker = L.circleMarker(e.latlng, { radius: 8, color: '#fff', weight: 3, fillColor: '#2f7de1', fillOpacity: 1 }).addTo(map)
  })
  map.on('locationerror', () => showToast('無法取得定位，請確認已允許位置權限（需 HTTPS）'))
  map.on('zoomend', zoneLabels)
  map.on('moveend', () => { clearTimeout(timer); timer = setTimeout(loadSpots, 300) })
  // 長按（右鍵 / 手機長按）選點建檔
  map.on('contextmenu', (e) => addSpotAt(e.latlng))
  // 點地圖空白處收起面板
  map.on('click', () => { showPanel.value = false })

  const id = route.query.spot
  if (id) {
    // 從建點頁回來：直接跳到該點（不論目前視窗是否包含它）
    getSpotSummary(id)
      .then((s) => { if (s?.lat != null) { map.setView([s.lat, s.lng], 17); select(id) } else loadSpots() })
      .catch(() => loadSpots())
  } else loadSpots()
  // 短時間內多筆變動合併成一次重新載入，避免每一筆餵食都讓所有人各打一輪請求
  unsub = subscribeFeeding(() => {
    clearTimeout(rtTimer)
    rtTimer = setTimeout(() => { loadSpots(); loadPending(); refreshKey.value++ }, 1500)
  })
  loadPending(); loadInbox()
  offFlushed = onFlushed(({ sent, dropped }) => {
    if (sent) showToast(`已補傳 ${sent} 筆離線餵食紀錄`)
    if (dropped.length) showToast({ message: `有 ${dropped.length} 筆離線紀錄無法補傳：${dropped[0].reason}`, duration: 5000 })
    loadSpots(); loadPending(); refreshKey.value++
  })
  // 還沒加入主畫面、也沒看過提示的人，顯示一次安裝提示
  const standalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone
  try { showInstall.value = !standalone && !localStorage.getItem('pawlink:install-tip') } catch { /* ignore */ }
  pendingTimer = setInterval(() => { loadPending(); loadInbox() }, 5 * 60e3)
})
function dismissInstall() { showInstall.value = false; try { localStorage.setItem('pawlink:install-tip', '1') } catch { /* ignore */ } }
onBeforeUnmount(() => {
  window.removeEventListener('pageshow', fixSize); window.removeEventListener('orientationchange', fixSize); document.removeEventListener('visibilitychange', fixSize)
  unsub?.(); offFlushed?.(); clearInterval(pendingTimer); clearTimeout(timer); clearTimeout(rtTimer); map?.remove(); map = null })
watch(() => auth.user?.id, () => { if (map) { loadSpots(); loadPending(); loadInbox(); refreshQueueCount().then(() => flushQueue()) } })
watch(() => net.online, (on) => { if (on && map) { loadSpots(); loadZones() } })
</script>

<template>
  <div class="page">
    <div ref="mapEl" class="map" />

    <div class="hud">
      <div class="bar">
        <img src="/pwa-192.png" alt="" width="34" height="34" />
        <div class="ttl">
          <b>PawLink</b>
          <span>{{ tally.all ? `這一帶有 ${tally.all} 個餵食點` : '這一帶還沒有餵食點' }}</span>
        </div>
        <van-button v-if="!auth.user" size="small" round type="primary" @click="router.push('/login')">登入</van-button>
        <button v-else type="button" class="me" :aria-label="`${auth.profile?.display_name || '已登入'}，開啟我的頁面`" @click="router.push({ name: 'me' })">{{ [...(auth.profile?.display_name || '我')][0] }}</button>
      </div>
      <div class="chips" role="group" aria-label="依餵食狀態篩選">
        <button v-for="[k, label] in FILTERS" :key="k" type="button" class="chip" :class="[k, { on: filter === k }]" :aria-pressed="filter === k" @click="setFilter(k)">
          <i v-if="k !== 'all'" />{{ label }}<em>{{ tally[k] }}</em>
        </button>
      </div>
      <button v-if="pending.length" type="button" class="todo pending" @click="goPending">
        <van-icon name="brush-o" />
        <span>你有 {{ pending.length }} 筆餵食還沒回報清理（{{ pending[0].spot_name }}）</span>
        <van-icon name="arrow" />
      </button>
    </div>

    <div class="dock">
      <div class="notes">
        <div v-if="showInstall" class="install">
          <span @click="router.push({ name: 'install' })">📲 加入主畫面，像 App 一樣使用 ›</span>
          <van-icon name="cross" aria-label="關閉" @click="dismissInstall" />
        </div>
        <div v-if="!net.online || net.count || showingCached" class="offline" @click="flushNow">
          <van-icon :name="net.online ? 'upgrade' : 'warning-o'" />
          <span v-if="net.count">{{ net.flushing ? '補傳中…' : `有 ${net.count} 筆餵食紀錄待補傳` }}{{ net.online ? '，點這裡立刻補傳' : '，恢復連線後自動補傳' }}</span>
          <span v-else>目前離線，顯示上次載入的餵食點。仍可記錄餵食</span>
        </div>
        <div v-if="zoneCount" class="legend" @click="showAllZones"><i class="red" />保育熱區 {{ zoneCount }} 處<i class="yellow" />200 公尺警示帶<span class="all">看全部</span></div>
      </div>
      <div class="fabs">
        <button type="button" class="fab" aria-label="定位到我的位置" @click="locate"><van-icon name="aim" /></button>
        <button type="button" class="fab add" aria-label="新增餵食點" @click="addHere"><van-icon name="plus" /></button>
      </div>
    </div>

    <van-popup v-model:show="showPanel" position="bottom" round :overlay="false" closeable class="panel">
      <SpotPanel :spot-id="selectedId" :refresh-key="refreshKey" @changed="onChanged" />
    </van-popup>
  </div>
</template>

<style scoped>
.page { position: relative; height: calc(100vh - var(--pl-tabbar-h)); height: calc(100dvh - var(--pl-tabbar-h)); overflow: hidden; }
.map { height: 100%; }

/* 上方：品牌列、狀態篩選、清理提醒 */
.hud { position: absolute; top: calc(10px + env(safe-area-inset-top)); left: 12px; right: 12px; z-index: 1000; display: flex; flex-direction: column; gap: 8px; pointer-events: none; }
.hud > * { pointer-events: auto; }
.bar { display: flex; align-items: center; gap: 10px; background: rgba(255, 255, 255, .97); border-radius: 18px; padding: 8px 10px 8px 8px; box-shadow: var(--pl-shadow-float); }
.bar img { border-radius: 10px; flex: none; }
.ttl { flex: 1; min-width: 0; display: flex; flex-direction: column; line-height: 1.25; }
.ttl b { font-size: 16px; letter-spacing: .02em; }
.ttl span { font-size: 12px; color: var(--pl-sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.me { flex: none; width: 36px; height: 36px; border-radius: 50%; border: 0; background: var(--pl-green); color: #fff; font: inherit; font-size: 15px; font-weight: 700; cursor: pointer; }
.chips { display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none; margin: 0 -12px; padding: 0 12px 2px; }
.chips::-webkit-scrollbar { display: none; }
.chip { flex: none; display: flex; align-items: center; gap: 5px; height: 32px; padding: 0 10px; border-radius: 16px; border: 1.5px solid transparent; background: rgba(255, 255, 255, .97); color: var(--pl-ink); font: inherit; font-size: 13px; font-weight: 600; box-shadow: 0 1px 4px rgba(31, 42, 36, .18); cursor: pointer; }
.chip i { width: 10px; height: 10px; border-radius: 50%; background: var(--c); }
.chip em { font-style: normal; color: var(--pl-muted); font-weight: 700; }
.chip.hungry { --c: var(--pl-red); }
.chip.recent { --c: var(--pl-amber); }
.chip.fresh { --c: var(--pl-green); }
.chip.on { background: var(--pl-ink); color: #fff; }
.chip.on em { color: rgba(255, 255, 255, .75); }
.todo { display: flex; align-items: center; gap: 8px; text-align: left; border: 0; border-radius: 14px; padding: 10px 12px; background: var(--pl-amber-soft); color: var(--pl-amber-ink); font: inherit; font-size: 13px; font-weight: 600; box-shadow: var(--pl-shadow-float); cursor: pointer; }
.todo span { flex: 1; }
.todo .van-icon { font-size: 16px; flex: none; }

/* 下方：提示與圖例在左，定位與新增在右 */
.dock { position: absolute; left: 12px; right: 12px; bottom: 22px; z-index: 1000; display: flex; align-items: flex-end; gap: 12px; pointer-events: none; }
.dock > * { pointer-events: auto; }
.notes { flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: 8px; }
.offline { background: var(--pl-ink); color: #fff; border-radius: 12px; padding: 9px 12px; font-size: 13px; line-height: 1.45; display: flex; gap: 8px; align-items: center; box-shadow: var(--pl-shadow-float); }
.install { align-self: stretch; background: #fff; color: var(--pl-green-dark); font-weight: 600; border-radius: 12px; padding: 9px 12px; font-size: 13px; display: flex; justify-content: space-between; align-items: center; gap: 8px; box-shadow: var(--pl-shadow-float); }
.legend { background: rgba(255, 255, 255, .95); border-radius: 10px; padding: 5px 10px; font-size: 12px; color: var(--pl-sub); display: flex; align-items: center; flex-wrap: wrap; gap: 4px; cursor: pointer; box-shadow: 0 1px 4px rgba(31, 42, 36, .18); }
.legend .all { margin-left: 6px; color: var(--pl-green); font-weight: 600; }
.legend i { display: inline-block; width: 12px; height: 12px; border-radius: 3px; margin-left: 4px; }
.legend i.red { background: rgba(217, 72, 47, .45); border: 1px solid var(--pl-red); }
.legend i.yellow { background: rgba(242, 183, 5, .35); border: 1px dashed #d99a00; }
.fabs { flex: none; display: flex; flex-direction: column; align-items: center; gap: 12px; }
.fab { width: 48px; height: 48px; border-radius: 50%; border: 0; background: #fff; color: var(--pl-ink); font-size: 22px; display: flex; align-items: center; justify-content: center; box-shadow: var(--pl-shadow-float); cursor: pointer; }
.fab.add { width: 58px; height: 58px; background: var(--pl-green); color: #fff; font-size: 26px; box-shadow: 0 4px 14px rgba(31, 132, 89, .45); }
.fab:active { transform: scale(.95); }

/* 寬螢幕：面板不要橫跨整個畫面 */
@media (min-width: 700px) {
  .panel { max-width: 440px; left: 16px; bottom: calc(16px + var(--pl-tabbar-h)); border-radius: 22px; }
  .hud { max-width: 440px; }
}
</style>
