<script setup>
// 照顧者的通知（站內通知）：居民通報（FR-2.2）與哨兵的動物提醒（FR-4.2），只列出自己照顧的餵食點
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getReportInbox, handleReport, REPORT_CATEGORY, REPORT_STATUS, getAnimalAlerts, resolveAnimalAlert, SIGHTING_CONDITION } from '../lib/api'

const route = useRoute(), router = useRouter()
const tab = ref(route.query.tab === 'alerts' ? 'alerts' : 'reports')
const list = ref([]), loading = ref(true), busy = ref(false)
const cur = ref(null), show = ref(false), response = ref('')
const alerts = ref([]), curAlert = ref(null), showAlert = ref(false), alertNote = ref('')

async function load() {
  loading.value = true
  try { list.value = await getReportInbox() } catch (e) { showToast(e.message) } finally { loading.value = false }
  alerts.value = await getAnimalAlerts({ silent: true })
}
onMounted(load)
const pending = computed(() => list.value.filter((r) => r.status !== 'resolved'))
const resolved = computed(() => list.value.filter((r) => r.status === 'resolved'))
function open(r) { cur.value = r; response.value = r.response || ''; show.value = true }
async function save(status) {
  busy.value = true
  try {
    await handleReport(cur.value.id, status, response.value.trim())
    show.value = false
    showToast(status === 'resolved' ? '已標記為已處理' : '已標記為處理中')
    await load()
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
const openAlerts = computed(() => alerts.value.filter((a) => a.status === 'open'))
const doneAlerts = computed(() => alerts.value.filter((a) => a.status !== 'open'))
const days = (t) => Math.max(0, Math.floor((Date.now() - new Date(t).getTime()) / 86400000))
function alertTitle(a) {
  return a.type === 'missing' ? `${a.animal_name} 可能失蹤` : `${a.animal_name} ${SIGHTING_CONDITION[a.condition] || '健康狀況異常'}`
}
function alertDesc(a) {
  if (a.type === 'missing') return `已經 ${days(a.last_seen_at)} 天沒有人回報看到牠（門檻 ${Number(a.threshold_days)} 天），這段期間餵食點有人餵過。`
  return `有人回報看到牠${SIGHTING_CONDITION[a.condition] || '狀況異常'}，請找時間確認。`
}
function openAlert(a) { curAlert.value = a; alertNote.value = a.note || ''; showAlert.value = true }
async function resolveAlert(markMissing) {
  busy.value = true
  try {
    await resolveAnimalAlert(curAlert.value.id, alertNote.value.trim(), markMissing)
    showAlert.value = false
    showToast(markMissing ? '已結案，並把牠標記為失蹤' : '已標記為已處理')
    await load()
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
const when = (t) => new Date(t).toLocaleString('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })
</script>

<template>
  <van-nav-bar title="通知" left-arrow @click-left="router.push('/')" />
  <van-tabs v-model:active="tab" sticky>
    <van-tab title="居民通報" name="reports" :badge="pending.filter((r) => r.status === 'open').length || ''">
    <van-empty v-if="!loading && !list.length" description="你照顧的餵食點目前沒有收到通報" />
  <template v-for="group in [{ title: '待處理', items: pending }, { title: '已處理', items: resolved }]" :key="group.title">
    <template v-if="group.items.length">
      <h4 class="sec">{{ group.title }}（{{ group.items.length }}）</h4>
      <van-cell-group inset>
        <van-cell v-for="r in group.items" :key="r.id" is-link @click="open(r)">
          <template #title>
            <van-tag :type="REPORT_STATUS[r.status][1]">{{ REPORT_STATUS[r.status][0] }}</van-tag>
            <b class="cat">{{ REPORT_CATEGORY[r.category] }}</b><span class="spot">{{ r.spot_name }}</span>
          </template>
          <template #label><div class="desc">{{ r.description }}</div><div>{{ when(r.created_at) }}</div></template>
        </van-cell>
      </van-cell-group>
    </template>
  </template>
  <p v-if="list.length" class="tip">通報是匿名的，內容只有該餵食點的照顧者與管理員看得到。你的回覆會公開顯示在餵食點的進度頁。</p>
    </van-tab>
    <van-tab title="動物提醒" name="alerts" :badge="openAlerts.length || ''">
      <van-empty v-if="!loading && !alerts.length" description="你照顧的動物目前沒有提醒" />
      <template v-for="group in [{ title: '待處理', items: openAlerts }, { title: '已處理', items: doneAlerts }]" :key="group.title">
        <template v-if="group.items.length">
          <h4 class="sec">{{ group.title }}（{{ group.items.length }}）</h4>
          <van-cell-group inset>
            <van-cell v-for="a in group.items" :key="a.id" is-link @click="openAlert(a)">
              <template #title>
                <van-tag :type="a.status !== 'open' ? 'success' : a.type === 'missing' ? 'warning' : 'danger'">{{ a.type === 'missing' ? '可能失蹤' : '健康' }}</van-tag>
                <b class="cat">{{ alertTitle(a) }}</b>
              </template>
              <template #label><div class="desc">{{ alertDesc(a) }}</div><div>{{ a.spot_name || '未指定餵食點' }}・{{ when(a.updated_at) }}</div></template>
            </van-cell>
          </van-cell-group>
        </template>
      </template>
      <p class="tip">系統每天檢查一次：動物超過 3 天（或牠平常出現間隔的 2 倍）沒有人回報看到，而且這段期間餵食點有人餵過，就會提醒照顧者。有人回報受傷、跛腳或消瘦時會立刻提醒。在動物身分檔按「回報目擊」就能更新。</p>
    </van-tab>
  </van-tabs>

  <van-popup v-model:show="show" position="bottom" round closeable>
    <div v-if="cur" class="sheet">
      <h4>{{ REPORT_CATEGORY[cur.category] }}・{{ cur.spot_name }}</h4>
      <p class="full">{{ cur.description }}</p>
      <van-field v-model="response" type="textarea" rows="3" maxlength="300" show-word-limit class="resp"
        placeholder="公開回覆（選填），例：已清理，之後改用有蓋餵食盒。請不要寫個人資料。" />
      <div class="btns">
        <van-button round plain type="warning" :loading="busy" @click="save('acknowledged')">處理中</van-button>
        <van-button round type="success" :loading="busy" @click="save('resolved')">已處理</van-button>
      </div>
      <van-button v-if="cur.status !== 'open'" size="small" plain block style="margin-top:10px" :disabled="busy" @click="save('open')">改回待處理</van-button>
    </div>
  </van-popup>

  <van-popup v-model:show="showAlert" position="bottom" round closeable>
    <div v-if="curAlert" class="sheet">
      <h4>{{ alertTitle(curAlert) }}</h4>
      <p class="full">{{ alertDesc(curAlert) }}</p>
      <van-button size="small" plain type="primary" icon="photo-o" @click="router.push({ name: 'animal', params: { id: curAlert.animal_id } })">看身分檔、回報目擊</van-button>
      <template v-if="curAlert.status === 'open'">
        <van-field v-model="alertNote" type="textarea" rows="2" maxlength="200" show-word-limit class="resp" style="margin-top:12px"
          placeholder="處理備註（選填），例：已帶去看醫生、問過鄰居說搬家帶走了" />
        <div class="btns" :style="curAlert.type === 'missing' ? '' : 'grid-template-columns:1fr'">
          <van-button v-if="curAlert.type === 'missing'" round plain type="warning" :loading="busy" @click="resolveAlert(true)">標記為失蹤</van-button>
          <van-button round type="success" :loading="busy" @click="resolveAlert(false)">已處理</van-button>
        </div>
      </template>
      <p v-else-if="curAlert.note" class="full" style="margin-top:12px;color:#666">處理備註：{{ curAlert.note }}</p>
    </div>
  </van-popup>
</template>

<style scoped>
.sec { margin: 16px 16px 8px; color: #555; }
.cat { margin: 0 8px; }
.spot { color: #888; font-size: 13px; }
.desc { color: #333; font-size: 14px; margin: 4px 0; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.tip { margin: 12px 20px 24px; color: #999; font-size: 12px; line-height: 1.6; }
.sheet { padding: 20px 16px 24px; }
.sheet h4 { margin: 0 32px 8px 0; }
.full { color: #333; line-height: 1.7; white-space: pre-wrap; margin: 0 0 12px; }
.resp { background: #f7f8fa; border-radius: 8px; }
.btns { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 14px; }
</style>
