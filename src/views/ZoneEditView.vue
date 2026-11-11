<script setup>
// 保育熱區繪製（FR-3.1）：Leaflet-Geoman 畫一個多邊形，送出時由資料庫 ST_IsValid 驗證
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import L from 'leaflet'
import '@geoman-io/leaflet-geoman-free'
import '@geoman-io/leaflet-geoman-free/dist/leaflet-geoman.css'
import { showToast, showDialog } from 'vant'
import { getZones, saveZone } from '../lib/api'

const route = useRoute(), router = useRouter()
const isNew = route.params.id === 'new'
const mapEl = ref(null)
const f = ref({ name: '', species: '石虎', description: '', is_demo: true })
const hasShape = ref(false), busy = ref(false), showForm = ref(false)
let map, layer, others

const STYLE = { color: '#e03e3e', weight: 2, fillColor: '#e03e3e', fillOpacity: 0.2 }
// 允許畫出交叉的邊線，交給資料庫擋（送出時會說明原因）
const DRAW = { allowSelfIntersection: true, templineStyle: { color: '#e03e3e' }, hintlineStyle: { color: '#e03e3e', dashArray: '5 5' }, pathOptions: STYLE }

function setLayer(l) {
  if (layer && layer !== l) layer.remove()
  layer = l
  hasShape.value = true
  layer.pm.enable({ allowSelfIntersection: true }) // 直接拖曳頂點調整
}
function redraw() {
  if (layer) { layer.remove(); layer = null }
  hasShape.value = false
  map.pm.enableDraw('Polygon', DRAW)
}

onMounted(async () => {
  map = L.map(mapEl.value, { zoomControl: true }).setView([24.45, 120.78], 12) // 預設在苗栗淺山一帶
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap contributors' }).addTo(map)
  map.pm.setLang('zh_tw')
  map.on('pm:create', (e) => { setLayer(e.layer); showForm.value = true })

  const zones = await getZones()
  if (!map) return
  // 其他熱區當參考底圖（不可編輯）
  others = L.layerGroup().addTo(map)
  for (const z of zones) {
    if (z.id === route.params.id) continue
    L.geoJSON(z.geojson, { interactive: false, pmIgnore: true, style: { color: '#999', weight: 1, fillOpacity: 0.08 } }).addTo(others)
  }
  if (isNew) {
    map.locate({ setView: true, maxZoom: 14 })
    map.pm.enableDraw('Polygon', DRAW)
  } else {
    const z = zones.find((x) => x.id === route.params.id)
    if (!z) { showToast('找不到這個保育熱區（停用中的熱區請先啟用再編輯）'); return router.replace({ name: 'admin', query: { tab: 'zones' } }) }
    f.value = { name: z.name, species: z.species || '', description: z.description || '', is_demo: z.is_demo }
    const ring = z.geojson.coordinates[0].slice(0, -1).map(([lng, lat]) => [lat, lng])
    setLayer(L.polygon(ring, STYLE).addTo(map))
    map.fitBounds(layer.getBounds(), { padding: [30, 30] })
  }
})
onBeforeUnmount(() => { map?.remove(); map = null })

async function submit() {
  if (!layer) return showToast('請先在地圖上畫出範圍')
  busy.value = true
  try {
    await saveZone({ ...f.value, id: isNew ? null : route.params.id, geojson: layer.toGeoJSON().geometry })
    showToast('已儲存保育熱區')
    router.replace({ name: 'admin', query: { tab: 'zones' } })
  } catch (e) {
    // 最常見：邊線交叉（ST_IsValid 不通過）。用對話框講清楚，留在頁面讓管理員調整
    showForm.value = false
    await showDialog({ title: '無法儲存', message: e.message || String(e) })
  } finally { busy.value = false }
}
</script>

<template>
  <div class="page">
    <van-nav-bar :title="isNew ? '畫新的保育熱區' : '編輯保育熱區'" left-arrow @click-left="router.replace({ name: 'admin', query: { tab: 'zones' } })" />
    <div ref="mapEl" class="map" />
    <div class="hint">
      <template v-if="!hasShape">在地圖上依序點出範圍的每個角，最後點回第一個點完成。</template>
      <template v-else>拖曳白色圓點可以調整範圍。邊線不能互相交叉。</template>
    </div>
    <div class="actions">
      <van-button round plain :disabled="!hasShape" @click="redraw">重畫</van-button>
      <van-button round type="primary" :disabled="!hasShape" @click="showForm = true">填寫資料並儲存</van-button>
    </div>
    <van-popup v-model:show="showForm" position="bottom" round closeable>
      <van-form style="padding:36px 0 16px" @submit="submit">
        <van-cell-group inset>
          <van-field v-model="f.name" label="名稱" maxlength="50" placeholder="例：通霄淺山石虎熱區" :rules="[{ required: true, message: '請輸入名稱' }]" />
          <van-field v-model="f.species" label="保育對象" maxlength="30" placeholder="例：石虎、白鼻心" />
          <van-field v-model="f.description" label="說明" type="textarea" rows="2" maxlength="500" placeholder="資料來源或注意事項" />
          <van-field label="示意資料"><template #input><van-switch v-model="f.is_demo" size="20" /></template></van-field>
        </van-cell-group>
        <p class="tip">不是官方圖資、依公開文獻自行繪製的範圍請開啟「示意資料」，地圖上會標示「示意」。</p>
        <div style="margin:12px 16px"><van-button round block type="primary" native-type="submit" :loading="busy">儲存</van-button></div>
      </van-form>
    </van-popup>
  </div>
</template>

<style scoped>
.page { height: 100%; display: flex; flex-direction: column; position: relative; }
.map { flex: 1; min-height: 0; }
.hint { position: absolute; top: 56px; left: 56px; right: 12px; z-index: 1000; background: rgba(255,255,255,.94); border-radius: 8px; padding: 8px 12px; font-size: 13px; color: #333; box-shadow: 0 1px 4px rgba(0,0,0,.2); }
.actions { position: absolute; left: 0; right: 0; bottom: 28px; z-index: 1000; display: flex; gap: 12px; justify-content: center; }
.actions .van-button { box-shadow: 0 1px 6px rgba(0,0,0,.25); }
.tip { margin: 8px 20px 0; color: #999; font-size: 12px; }
</style>
