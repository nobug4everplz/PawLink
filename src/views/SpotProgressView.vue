<script setup>
// 餵食點公開進度（FR-2.2）：訪客看得到統計與通報處理狀態，看不到個資與通報內容
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getSpotSummary, listSpotAnimals, getSpotPublicReports, REPORT_CATEGORY, REPORT_STATUS } from '../lib/api'

const route = useRoute(), router = useRouter()
const id = route.params.id
const s = ref(null), animals = ref([]), reports = ref([]), missing = ref(false)
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']
const FOOT = { fresh: ['6 小時內餵過', '#2f9e6b'], recent: ['24 小時內餵過', '#f2b705'], hungry: ['超過 24 小時沒有餵食紀錄', '#e03e3e'] }

onMounted(async () => {
  try {
    s.value = await getSpotSummary(id)
    if (!s.value) { missing.value = true; return }
    ;[animals.value, reports.value] = await Promise.all([listSpotAnimals(id), getSpotPublicReports(id)])
  } catch (e) { showToast(e.message) }
})
const stageCounts = computed(() => STAGES.map((name, i) => ({ name, n: animals.value.filter((a) => a.tnr_stage === i + 1).length })))
const sterRate = computed(() => s.value?.animal_count ? Math.round((s.value.sterilized_count / s.value.animal_count) * 100) : null)
const openCount = computed(() => reports.value.filter((r) => r.status !== 'resolved').length)
const day = (t) => new Date(t).toLocaleDateString('zh-TW')
const back = () => (window.history.length > 1 ? router.back() : router.replace('/'))
</script>

<template>
  <van-nav-bar title="餵食點公開進度" left-arrow @click-left="back" />
  <van-empty v-if="missing" description="找不到這個餵食點，可能已經停用" />
  <div v-else-if="s" class="wrap">
    <h2>{{ s.name }}</h2>
    <p class="foot"><i :style="{ background: FOOT[s.footprint]?.[1] }" />{{ FOOT[s.footprint]?.[0] }}</p>

    <div class="stats">
      <div><b>{{ s.clean_rate_30d == null ? '—' : Math.round(s.clean_rate_30d * 100) + '%' }}</b><span>近 30 天清理率</span><small v-if="s.feedings_30d">{{ s.cleaned_30d }}/{{ s.feedings_30d }} 次餵食後有清理</small></div>
      <div><b>{{ sterRate == null ? '—' : sterRate + '%' }}</b><span>結紮率</span><small>{{ s.sterilized_count }}/{{ s.animal_count }} 隻已結紮</small></div>
      <div><b>{{ s.caretaker_count }}</b><span>照顧者</span><small>人</small></div>
    </div>

    <h3>結紮（TNR）進度</h3>
    <van-cell-group inset>
      <van-cell v-for="c in stageCounts" :key="c.name" :title="c.name" :value="`${c.n} 隻`" />
    </van-cell-group>
    <p v-if="!animals.length" class="note">這個餵食點還沒有登記動物。</p>

    <h3>居民通報處理進度 <van-tag v-if="openCount" type="danger" style="margin-left:6px">{{ openCount }} 則處理中</van-tag></h3>
    <van-cell-group v-if="reports.length" inset>
      <van-cell v-for="r in reports" :key="r.id" :title="REPORT_CATEGORY[r.category]" :label="r.response ? `照顧者回覆：${r.response}` : '照顧者尚未回覆'">
        <template #value>
          <van-tag :type="REPORT_STATUS[r.status][1]">{{ REPORT_STATUS[r.status][0] }}</van-tag>
          <div class="date">{{ day(r.created_at) }} 通報</div>
        </template>
      </van-cell>
    </van-cell-group>
    <p v-else class="note">近半年沒有收到通報。</p>
    <p class="note">這裡只顯示通報的類別與處理狀態，不會顯示通報內容，也不會顯示照顧者或通報人的身分。</p>

    <div class="cta"><van-button round block plain type="danger" icon="warning-o" @click="router.push({ name: 'spot-report', params: { id } })">這個餵食點有問題？匿名通報</van-button></div>
  </div>
</template>

<style scoped>
.wrap { padding: 4px 0 40px; max-width: 720px; margin: 0 auto; }
h2 { margin: 16px 16px 4px; }
h3 { margin: 22px 16px 10px; font-size: 16px; display: flex; align-items: center; }
.foot { margin: 0 16px; color: #555; font-size: 14px; display: flex; align-items: center; gap: 6px; }
.foot i { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin: 16px; }
.stats div { background: #f3f8f5; border-radius: 10px; padding: 12px 8px; text-align: center; display: flex; flex-direction: column; gap: 2px; }
.stats b { font-size: 24px; color: #1f7a50; }
.stats span { font-size: 13px; color: #333; }
.stats small { font-size: 11px; color: #888; }
.note { margin: 8px 20px 0; color: #999; font-size: 12px; line-height: 1.6; }
:deep(.van-cell__title) { flex: 2.2; }
.date { font-size: 11px; color: #999; margin-top: 2px; }
.cta { margin: 28px 16px 0; }
</style>
