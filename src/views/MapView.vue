<script setup>
import { onMounted, onBeforeUnmount, ref } from 'vue'
import L from 'leaflet'
import 'leaflet.markercluster'
import { showToast } from 'vant'
import { fetchMapSpots } from '../lib/spots'
import { footprintIcon } from '../components/footprintIcon'

const mapEl = ref(null)
const selected = ref(null)
const showPanel = ref(false)
let map, cluster, meMarker, timer

const FOOT = { fresh: '剛餵過', recent: '一陣子前', hungry: '久未餵食' }

async function loadSpots() {
  try {
    const spots = await fetchMapSpots(map.getBounds())
    cluster.clearLayers()
    for (const s of spots) {
      const m = L.marker([s.lat, s.lng], { icon: footprintIcon(s.footprint) })
      m.on('click', () => { selected.value = s; showPanel.value = true })
      cluster.addLayer(m)
    }
  } catch (e) {
    showToast('載入餵食點失敗：' + e.message)
  }
}

function locate() {
  map.locate({ setView: true, maxZoom: 17, enableHighAccuracy: true })
}

onMounted(() => {
  map = L.map(mapEl.value, { zoomControl: false }).setView([25.0174, 121.5398], 15)
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© OpenStreetMap contributors',
  }).addTo(map)
  cluster = L.markerClusterGroup({ showCoverageOnHover: false, maxClusterRadius: 50 })
  map.addLayer(cluster)

  map.on('locationfound', (e) => {
    if (meMarker) meMarker.remove()
    meMarker = L.circleMarker(e.latlng, { radius: 8, color: '#fff', weight: 3, fillColor: '#1989fa', fillOpacity: 1 }).addTo(map)
  })
  map.on('locationerror', () => showToast('無法取得定位，請確認已允許位置權限（需 HTTPS）'))
  map.on('moveend', () => { clearTimeout(timer); timer = setTimeout(loadSpots, 300) })
  loadSpots()
})
onBeforeUnmount(() => map?.remove())
</script>

<template>
  <div class="page">
    <div ref="mapEl" class="map" />
    <van-button class="locate" round icon="aim" type="primary" @click="locate" />
    <van-popup v-model:show="showPanel" position="bottom" round :overlay="false" class="panel">
      <div v-if="selected" class="info">
        <h3>{{ selected.name }}</h3>
        <p>狀態：{{ FOOT[selected.footprint] }}</p>
        <p>動物 {{ selected.animal_count }} 隻・已結紮 {{ selected.sterilized_count }} 隻</p>
        <p>30 日清理率：{{ selected.clean_rate_30d == null ? '尚無資料' : Math.round(selected.clean_rate_30d * 100) + '%' }}</p>
        <p v-if="selected.is_fuzzed" class="hint">訪客僅顯示大約位置，登入後可看精確位置</p>
      </div>
    </van-popup>
  </div>
</template>

<style scoped>
.page { position: relative; height: 100%; }
.map { height: 100%; }
.locate { position: absolute; right: 16px; bottom: 32px; z-index: 1000; width: 48px; height: 48px; }
.info { padding: 16px 20px 28px; }
.info h3 { margin: 0 0 8px; }
.info p { margin: 4px 0; color: #444; }
.hint { color: #999; font-size: 12px; }
</style>
