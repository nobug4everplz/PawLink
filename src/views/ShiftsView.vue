<script setup>
// 餵食輪值與代班（FR-5.1）：只列出自己照顧的餵食點的班
// 能不能排、能不能接都由資料庫的 RPC 決定，這裡只負責顯示
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import {
  getShifts, getShiftSpots, createShift, cancelShift, requestShiftCover, claimShift, completeShift,
  SHIFT_SLOT, SHIFT_STATUS,
} from '../lib/api'

const router = useRouter()
const list = ref([]), spots = ref([]), loading = ref(true), busy = ref(false), unavailable = ref(false)
const cur = ref(null), showAct = ref(false)
const showNew = ref(false), form = ref({ spot: null, date: null, slot: 'morning', note: '' })

// 日期一律用臺灣時間算，跟資料庫一致（手機時區設成別的地方也不會差一天）
const fmtTw = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei' })
const ymd = (d) => fmtTw.format(d)
const today = ymd(new Date())
const utc = (s) => { const [y, m, d] = s.split('-').map(Number); return Date.UTC(y, m - 1, d) }
const WEEK = '日一二三四五六'
function dayLabel(s) {
  const dt = new Date(utc(s)), diff = Math.round((utc(s) - utc(today)) / 86400000)
  return `${dt.getUTCMonth() + 1}/${dt.getUTCDate()}（${WEEK[dt.getUTCDay()]}）${diff === 0 ? '今天' : diff === 1 ? '明天' : ''}`
}
const days = Array.from({ length: 14 }, (_, i) => ymd(new Date(Date.now() + i * 86400000)))

async function load() {
  loading.value = true
  try {
    const rows = await getShifts()
    unavailable.value = rows === null
    list.value = rows || []
    if (rows) spots.value = await getShiftSpots()
  } catch (e) { showToast(e.message) } finally { loading.value = false }
}
onMounted(load)

const upcoming = computed(() => list.value.filter((x) => x.shift_date >= today))
const claimable = computed(() => upcoming.value.filter((x) => x.can_claim))
const mine = computed(() => upcoming.value.filter((x) => (x.is_my_duty || x.is_mine) && x.status !== 'done'))
const who = (x) => x.cover_user_id ? `${x.cover_name || '照顧者'}（代 ${x.user_name || '照顧者'}）` : (x.user_name || '照顧者')

async function act(fn, okMsg) {
  busy.value = true
  try { await fn(); showAct.value = false; showToast(okMsg) } catch (e) { showToast(e.message) } finally { busy.value = false; await load() }
}
const claim = (x) => act(() => claimShift(x.id), '已接下這一班，謝謝你')
function open(x) { cur.value = x; showAct.value = true }
const actions = computed(() => {
  const x = cur.value
  if (!x) return []
  const a = []
  if (x.is_my_duty && ['scheduled', 'covered'].includes(x.status) && x.shift_date <= today) a.push({ name: '標記完成', key: 'done', color: '#2f9e6b' })
  if (x.is_mine && x.status === 'scheduled') a.push({ name: '我沒辦法去，求代班', key: 'need' })
  if (x.is_mine && x.status === 'need_cover') a.push({ name: '收回代班請求', key: 'keep' })
  if (x.is_mine && ['scheduled', 'need_cover'].includes(x.status)) a.push({ name: '取消這一班', key: 'cancel', color: '#ee0a24' })
  return a
})
async function onAction(a) {
  const x = cur.value
  if (a.key === 'done') return act(() => completeShift(x.id), '已標記完成')
  if (a.key === 'need') return act(() => requestShiftCover(x.id, true), '已送出，這個點的其他照顧者會看到')
  if (a.key === 'keep') return act(() => requestShiftCover(x.id, false), '已收回，這一班還是你的')
  if (a.key === 'cancel') {
    showAct.value = false
    try { await showConfirmDialog({ title: '取消這一班', message: `${dayLabel(x.shift_date)}${SHIFT_SLOT[x.time_slot]}・${x.spot_name}` }) } catch { return }
    return act(() => cancelShift(x.id), '已取消')
  }
}
function openNew() {
  form.value = { spot: spots.value[0]?.id || null, date: days[0], slot: 'morning', note: '' }
  showNew.value = true
}
async function submit() {
  const f = form.value
  if (!f.spot) return showToast('請選餵食點')
  busy.value = true
  try {
    await createShift(f.spot, f.date, f.slot, f.note.trim())
    showNew.value = false
    showToast('已登記')
    await load()
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar title="輪值表" left-arrow @click-left="router.push('/')" />
  <van-empty v-if="unavailable" description="資料庫還沒有套用輪值功能" />
  <van-empty v-else-if="!loading && !spots.length" description="成為任一個餵食點的照顧者，就可以排班與代班">
    <van-button round type="primary" size="small" @click="router.push('/')">回地圖找餵食點</van-button>
  </van-empty>
  <template v-else-if="!loading">
    <div class="bar"><van-button block round type="primary" icon="plus" @click="openNew">登記輪值</van-button></div>

    <template v-if="claimable.length">
      <h4 class="sec warn">需要代班（{{ claimable.length }}）</h4>
      <van-cell-group inset>
        <van-cell v-for="x in claimable" :key="x.id" class="claim">
          <template #title><b>{{ dayLabel(x.shift_date) }}{{ SHIFT_SLOT[x.time_slot] }}</b></template>
          <template #label>{{ x.spot_name }}・{{ x.user_name || '照顧者' }} 沒辦法去<span v-if="x.note">・{{ x.note }}</span></template>
          <template #value><van-button size="small" round type="warning" :loading="busy" @click="claim(x)">我來代班</van-button></template>
        </van-cell>
      </van-cell-group>
    </template>

    <h4 class="sec">我的班（{{ mine.length }}）</h4>
    <van-cell-group v-if="mine.length" inset>
      <van-cell v-for="x in mine" :key="x.id" is-link @click="open(x)">
        <template #title>
          <b>{{ dayLabel(x.shift_date) }}{{ SHIFT_SLOT[x.time_slot] }}</b>
          <van-tag :type="SHIFT_STATUS[x.status][1]" style="margin-left:8px">{{ SHIFT_STATUS[x.status][0] }}</van-tag>
        </template>
        <template #label>
          {{ x.spot_name }}
          <span v-if="x.status === 'covered' && x.is_mine">・{{ x.cover_name || '照顧者' }} 會幫你去</span>
          <span v-else-if="x.status === 'covered'">・你代 {{ x.user_name || '照顧者' }} 的班</span>
          <span v-if="x.note">・{{ x.note }}</span>
        </template>
      </van-cell>
    </van-cell-group>
    <p v-else class="tip">你接下來沒有班。</p>

    <h4 class="sec">全部班表</h4>
    <van-cell-group v-if="upcoming.length" inset>
      <van-cell v-for="x in upcoming" :key="x.id" :title="`${dayLabel(x.shift_date)}${SHIFT_SLOT[x.time_slot]}`" :label="`${x.spot_name}・${who(x)}`">
        <template #value><van-tag plain :type="SHIFT_STATUS[x.status][1]">{{ SHIFT_STATUS[x.status][0] }}</van-tag></template>
      </van-cell>
    </van-cell-group>
    <p v-else class="tip">你照顧的餵食點還沒有人排班。</p>
    <p class="tip">一個餵食點每天早上、晚上各一班。臨時不能去就按「求代班」，同一個點的其他照顧者會看到，第一個按「我來代班」的人接下這一班。當天在那個點記錄餵食，班會自動標記完成。</p>
  </template>

  <van-action-sheet v-model:show="showAct" :actions="actions" cancel-text="關閉" :description="cur ? `${dayLabel(cur.shift_date)}${SHIFT_SLOT[cur.time_slot]}・${cur.spot_name}` : ''" @select="onAction" />

  <van-popup v-model:show="showNew" position="bottom" round closeable>
    <div class="sheet">
      <h4>登記輪值</h4>
      <div class="label">餵食點</div>
      <van-radio-group v-model="form.spot" class="spots">
        <van-radio v-for="s in spots" :key="s.id" :name="s.id">{{ s.name }}</van-radio>
      </van-radio-group>
      <div class="label">日期</div>
      <div class="days">
        <span v-for="d in days" :key="d" class="day" :class="{ on: form.date === d }" @click="form.date = d">{{ dayLabel(d) }}</span>
      </div>
      <div class="label">時段</div>
      <van-radio-group v-model="form.slot" direction="horizontal">
        <van-radio v-for="(label, k) in SHIFT_SLOT" :key="k" :name="k">{{ label }}</van-radio>
      </van-radio-group>
      <van-field v-model="form.note" maxlength="100" class="note" placeholder="備註（選填），例：我會帶濕食" />
      <van-button block round type="primary" :loading="busy" style="margin-top:14px" @click="submit">送出</van-button>
    </div>
  </van-popup>
</template>

<style scoped>
.bar { margin: 12px 16px 4px; }
.sec { margin: 16px 16px 8px; color: #555; }
.sec.warn { color: #d9730d; }
.tip { margin: 8px 20px 16px; color: #999; font-size: 12px; line-height: 1.6; }
.claim :deep(.van-cell__value) { flex: none; align-self: center; }
.sheet { padding: 20px 16px 24px; max-height: 80vh; overflow-y: auto; }
.sheet h4 { margin: 0 32px 6px 0; }
.label { margin: 14px 0 8px; color: #666; font-size: 13px; }
.spots { display: grid; gap: 10px; }
.days { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 4px; }
.day { flex: none; padding: 6px 10px; border: 1px solid #dcdee0; border-radius: 16px; font-size: 13px; color: #333; }
.day.on { background: #1989fa; border-color: #1989fa; color: #fff; }
.note { background: #f7f8fa; border-radius: 8px; margin-top: 14px; }
</style>
