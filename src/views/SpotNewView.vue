<script setup>
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth } from '../lib/auth'
import { findNearbySpots, createSpot, joinSpot } from '../lib/api'

const route = useRoute(), router = useRouter()
const lat = ref(parseFloat(route.query.lat)), lng = ref(parseFloat(route.query.lng))
const name = ref(''), description = ref('')
const nearby = ref([]), busy = ref(false)

onMounted(async () => {
  if (Number.isNaN(lat.value)) return router.replace('/')
  try { nearby.value = await findNearbySpots(lat.value, lng.value) } catch (e) { showToast(e.message) }
})

async function join(s) {
  try { await joinSpot(s.id, auth.user.id); showToast('已加入照顧者'); router.replace({ name: 'map', query: { spot: s.id } }) }
  catch (e) { showToast(e.message) }
}
async function submit() {
  if (nearby.value.length) {
    try { await showConfirmDialog({ title: '附近已有餵食點', message: '30 公尺內已有餵食點，確定仍要新增一個嗎？' }) } catch { return }
  }
  busy.value = true
  try {
    const id = await createSpot(name.value, lat.value, lng.value, description.value)
    router.replace({ name: 'map', query: { spot: id } })
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar title="新增餵食點" left-arrow @click-left="router.back()" />
  <van-notice-bar v-if="nearby.length" wrapable :scrollable="false" color="#ed6a0c" background="#fffbe8">
    附近 30 公尺內已有餵食點，要不要直接加入？
  </van-notice-bar>
  <van-cell-group v-if="nearby.length" inset style="margin:12px 0">
    <van-cell v-for="s in nearby" :key="s.id" :title="s.name" :label="`距離約 ${Math.round(s.distance_m)} 公尺`">
      <template #right-icon><van-button size="small" type="primary" @click="join(s)">加入</van-button></template>
    </van-cell>
  </van-cell-group>
  <van-form @submit="submit">
    <van-cell-group inset style="margin-top:12px">
      <van-field v-model="name" label="名稱" maxlength="50" placeholder="例：醉月湖畔 A 點" :rules="[{ required: true, message: '請輸入名稱' }]" />
      <van-field v-model="description" label="說明" type="textarea" rows="2" maxlength="300" placeholder="位置描述、注意事項（訪客看不到）" />
      <van-field :model-value="`${lat.toFixed(5)}, ${lng.toFixed(5)}`" label="座標" readonly />
    </van-cell-group>
    <div style="margin:16px"><van-button round block type="primary" native-type="submit" :loading="busy">建立餵食點</van-button></div>
  </van-form>
</template>
