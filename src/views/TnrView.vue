<script setup>
// TNR 接力看板（FR-5.2）：所有進行中的案件，先列出有我認領任務的
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getTnrTasks } from '../lib/api'
import TnrSteps from '../components/TnrSteps.vue'

const router = useRouter()
const tasks = ref([]), loading = ref(true), unavailable = ref(false)
async function load() {
  try {
    const rows = await getTnrTasks()
    unavailable.value = rows === null
    tasks.value = rows || []
  } catch (e) { showToast(e.message) } finally { loading.value = false }
}
onMounted(load)
const cases = computed(() => {
  const m = new Map()
  for (const t of tasks.value) { if (!m.has(t.case_id)) m.set(t.case_id, []); m.get(t.case_id).push(t) }
  const all = [...m.values()]
  const score = (c) => (c.some((t) => t.is_mine && t.is_ready) ? 0 : c.some((t) => t.is_mine && t.status === 'claimed') ? 1 : c.some((t) => t.status === 'open') ? 2 : 3)
  return all.sort((x, y) => score(x) - score(y))
})
const open = computed(() => tasks.value.filter((t) => t.status === 'open').length)
</script>

<template>
  <van-nav-bar title="TNR 接力" left-arrow @click-left="router.push('/')" />
  <van-empty v-if="unavailable" description="資料庫還沒有套用 TNR 接力功能" />
  <van-empty v-else-if="!loading && !cases.length" description="目前沒有進行中的 TNR 接力">
    <p class="how">到動物身分檔按「發起接力」，就能把誘捕、送醫、術後照顧、放回分給不同的人。</p>
  </van-empty>
  <template v-else-if="!loading">
    <p class="tip">進行中 {{ cases.length }} 件，還有 {{ open }} 個任務等人認領。四步要依序完成，每完成一步，動物的結紮進度會自動更新。</p>
    <div v-for="c in cases" :key="c[0].case_id" class="case">
      <div class="head" @click="router.push({ name: 'animal', params: { id: c[0].animal_id } })">
        <b>{{ c[0].animal_name }}</b><span v-if="c[0].spot_name" class="spot">{{ c[0].spot_name }}</span><van-icon name="arrow" />
      </div>
      <TnrSteps :tasks="c" @changed="load" />
    </div>
  </template>
</template>

<style scoped>
.tip { margin: 12px 20px 4px; color: #888; font-size: 12px; line-height: 1.6; }
.how { color: #999; font-size: 13px; padding: 0 32px; line-height: 1.6; }
.case { margin-top: 14px; }
.head { display: flex; align-items: center; gap: 8px; margin: 0 20px 8px; }
.head .spot { color: #888; font-size: 13px; flex: 1; }
.head .van-icon { color: #c8c9cc; }
</style>
