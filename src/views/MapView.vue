<script setup>
import { onMounted, onBeforeUnmount, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import L from 'leaflet'
import 'leaflet.markercluster'
import { showToast } from 'vant'
import { auth, signOut } from '../lib/auth'
import { fetchMapSpots } from '../lib/spots'
import { subscribeFeeding, getSpotSummary, getPendingCleanups } from '../lib/api'
import { footprintIcon } from '../components/footprintIcon'
import SpotPanel from '../components/SpotPanel.vue'

const route = useRoute(), router = useRouter()
const mapEl = ref(null)
const selectedId = ref(null)
const showPanel = ref(false)
const refreshKey = ref(0)
const pending = ref([]) // 我還沒回報清理的餵食（餵食後 30 分鐘～24 小時）
let map, cluster, meMarker, timer, unsub, pendingTimer
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
function select(id) { selectedId.value = id; showPanel.value = true }
async function loadPending() {
  if (!auth.user) { pending.value = []; return }
  try { pending.value = await getPendingCleanups() } catch { /* 提醒載入失敗不影響地圖 */ }
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
  loadPending()
  pendingTimer = setInterval(loadPending, 5 * 60e3)
})
onBeforeUnmount(() => { unsub?.(); clearInterval(pendingTimer); map?.remove() })
watch(() => auth.user?.id, () => { if (map) { loadSpots(); loadPending() } })
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
.top.shifted { top: 52px; }
.pending { position: absolute; top: 0; left: 0; right: 0; z-index: 1000; }
.fabs { position: absolute; right: 16px; bottom: 32px; z-index: 1000; display: flex; flex-direction: column; gap: 12px; }
.fab { width: 48px; height: 48px; }
</style>
