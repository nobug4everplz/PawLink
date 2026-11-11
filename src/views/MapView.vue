<script setup>
import { onMounted, onBeforeUnmount, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import L from 'leaflet'
import 'leaflet.markercluster'
import { showToast } from 'vant'
import { auth, signOut, isAdmin } from '../lib/auth'
import { fetchMapSpots } from '../lib/spots'
import { subscribeFeeding, getSpotSummary, getPendingCleanups, getZones, getReportInbox } from '../lib/api'
import { footprintIcon } from '../components/footprintIcon'
import SpotPanel from '../components/SpotPanel.vue'

const route = useRoute(), router = useRouter()
const mapEl = ref(null)
const selectedId = ref(null)
const showPanel = ref(false)
const refreshKey = ref(0)
const pending = ref([]) // 我還沒回報清理的餵食（餵食後 30 分鐘～24 小時）
let map, cluster, meMarker, timer, unsub, pendingTimer, zoneLayer
const zoneCount = ref(0)
const openReports = ref(0) // 我照顧的點還沒處理完的居民通報
let spots = []

async function loadSpots() {
  try {
    spots = await fetchMapSpots(map.getBounds())
    cluster.clearLayers()
    for (const s of spots) {
      const m = L.marker([s.lat, s.lng], { icon: footprintIcon(s.footprint) })
      m.on('click', () => select(s.id))
      cluster.addLayer(m)
    }
  } catch (e) { showToast('載入餵食點失敗：' + e.message) }
}
/** 保育熱區：紅色為範圍、黃色虛線為 200 公尺警示帶。不攔截點擊，長按建點照常可用 */
async function loadZones() {
  const zones = await getZones()
  if (!map) return
  zoneLayer.clearLayers()
  for (const z of zones) {
    L.geoJSON(z.buffer_geojson, { interactive: false, style: { color: '#d99a00', weight: 1.5, dashArray: '6 6', fillColor: '#f2b705', fillOpacity: 0.12 } }).addTo(zoneLayer)
    L.geoJSON(z.geojson, { interactive: false, style: { color: '#e03e3e', weight: 2, fillColor: '#e03e3e', fillOpacity: 0.18 } })
      .bindTooltip(`保育熱區：${z.name}${z.is_demo ? '（示意）' : ''}`, { permanent: true, direction: 'center', className: 'zone-label' })
      .addTo(zoneLayer)
  }
  zoneCount.value = zones.length
}
function select(id) { selectedId.value = id; showPanel.value = true }
async function loadPending() {
  if (!auth.user) { pending.value = []; return }
  try { pending.value = await getPendingCleanups() } catch { /* 提醒載入失敗不影響地圖 */ }
}
async function loadInbox() {
  if (!auth.user) { openReports.value = 0; return }
  openReports.value = (await getReportInbox({ silent: true })).filter((r) => r.status === 'open').length
}
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

onMounted(() => {
  map = L.map(mapEl.value, { zoomControl: false }).setView([25.0174, 121.5398], 15)
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap contributors' }).addTo(map)
  cluster = L.markerClusterGroup({ showCoverageOnHover: false, maxClusterRadius: 50 })
  map.addLayer(cluster)
  zoneLayer = L.layerGroup().addTo(map)
  loadZones()

  map.on('locationfound', (e) => {
    if (meMarker) meMarker.remove()
    meMarker = L.circleMarker(e.latlng, { radius: 8, color: '#fff', weight: 3, fillColor: '#1989fa', fillOpacity: 1 }).addTo(map)
  })
  map.on('locationerror', () => showToast('無法取得定位，請確認已允許位置權限（需 HTTPS）'))
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
  unsub = subscribeFeeding(() => { loadSpots(); loadPending(); refreshKey.value++ })
  loadPending(); loadInbox()
  pendingTimer = setInterval(() => { loadPending(); loadInbox() }, 5 * 60e3)
})
onBeforeUnmount(() => { unsub?.(); clearInterval(pendingTimer); map?.remove() })
watch(() => auth.user?.id, () => { if (map) { loadSpots(); loadPending(); loadInbox() } })
</script>

<template>
  <div class="page">
    <div ref="mapEl" class="map" />
    <van-notice-bar v-if="pending.length" class="pending" left-icon="brush-o" mode="link" :scrollable="false" @click="goPending">
      你有 {{ pending.length }} 筆餵食還沒回報清理（{{ pending[0].spot_name }}）
    </van-notice-bar>
    <div class="top" :class="{ shifted: pending.length }">
      <van-button v-if="!auth.user" size="small" round type="primary" @click="router.push('/login')">登入</van-button>
      <van-button v-else size="small" round plain @click="signOut">{{ auth.profile?.display_name || '已登入' }}・登出</van-button>
    </div>
    <div class="links" :class="{ shifted: pending.length }">
      <van-button size="small" round plain type="success" icon="flower-o" @click="router.push({ name: 'conservation' })">保育</van-button>
      <van-button v-if="auth.user" size="small" round plain type="primary" icon="chat-o" @click="router.push({ name: 'community' })">交流</van-button>
      <van-button v-if="isAdmin()" size="small" round plain type="danger" icon="setting-o" @click="router.push({ name: 'admin' })">後台</van-button>
    </div>
    <van-badge v-if="auth.user" :content="openReports || ''" :show-zero="false" class="inbox" :class="{ shifted: pending.length }">
      <van-button size="small" round plain icon="envelop-o" @click="router.push({ name: 'inbox' })">居民通報</van-button>
    </van-badge>
    <div v-if="zoneCount" class="legend"><i class="red" />保育熱區<i class="yellow" />200 公尺警示帶</div>
    <div class="fabs">
      <van-button round icon="aim" type="primary" class="fab" @click="locate" />
      <van-button round icon="plus" type="success" class="fab" @click="addHere" />
    </div>
    <van-popup v-model:show="showPanel" position="bottom" round :overlay="false" closeable class="panel">
      <SpotPanel :spot-id="selectedId" :refresh-key="refreshKey" @changed="onChanged" />
    </van-popup>
  </div>
</template>

<style scoped>
.page { position: relative; height: 100%; }
.map { height: 100%; }
.top { position: absolute; top: 12px; right: 12px; z-index: 1000; background: #fff; border-radius: 16px; }
.top.shifted, .links.shifted { top: 52px; }
.inbox { position: absolute; top: 52px; left: 12px; z-index: 1000; }
.inbox.shifted { top: 92px; }
.inbox .van-button { background: #fff; }
.links { position: absolute; top: 12px; left: 12px; z-index: 1000; display: flex; gap: 8px; }
.links .van-button { background: #fff; }
.legend { position: absolute; left: 12px; bottom: 28px; z-index: 1000; background: rgba(255,255,255,.92); border-radius: 8px; padding: 4px 10px; font-size: 12px; color: #444; display: flex; align-items: center; gap: 4px; }
.legend i { display: inline-block; width: 12px; height: 12px; border-radius: 3px; margin-left: 4px; }
.legend i.red { background: rgba(224,62,62,.45); border: 1px solid #e03e3e; }
.legend i.yellow { background: rgba(242,183,5,.35); border: 1px dashed #d99a00; }
.pending { position: absolute; top: 0; left: 0; right: 0; z-index: 1000; }
.fabs { position: absolute; right: 16px; bottom: 32px; z-index: 1000; display: flex; flex-direction: column; gap: 12px; }
.fab { width: 48px; height: 48px; }
</style>
