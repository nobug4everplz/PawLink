<script setup>
import { ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth } from '../lib/auth'
import { getSpotSummary, listSpotAnimals, checkRecentFeeding, recordFeeding, getPendingCleanups, reportCleanup, joinSpot, photoUrl, checkSpotAlert } from '../lib/api'

const props = defineProps({ spotId: String, refreshKey: Number })
const emit = defineEmits(['changed'])
const router = useRouter()

const FOOT = { fresh: ['剛餵過', '#2f9e6b'], recent: ['一陣子前', '#f2b705'], hungry: ['久未餵食', '#e03e3e'] }
const FOOD = [{ text: '乾糧', value: 'dry' }, { text: '濕食', value: 'wet' }, { text: '混合', value: 'mixed' }, { text: '其他', value: 'other' }]
const STAGE = ['', '未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']

const s = ref(null), animals = ref([]), pending = ref([]), busy = ref(false), alert = ref(null)
const showFeed = ref(false), food = ref('dry'), note = ref('')

async function load() {
  if (!props.spotId) return
  try {
    s.value = await getSpotSummary(props.spotId)
    animals.value = await listSpotAnimals(props.spotId)
    pending.value = auth.user ? (await getPendingCleanups()).filter((p) => p.spot_id === props.spotId) : []
    alert.value = auth.user ? await checkSpotAlert(props.spotId) : null
  } catch (e) { showToast(e.message) }
}
watch(() => [props.spotId, props.refreshKey, auth.user?.id], load, { immediate: true })

function needLogin() { router.push({ name: 'login', query: { redirect: '/' } }) }

async function startFeed() {
  if (!auth.user) return needLogin()
  try {
    const r = await checkRecentFeeding(props.spotId)
    if (r?.length) {
      await showConfirmDialog({ title: '最近已有人餵過', message: `${r[0].fed_by_name || '有人'} ${r[0].minutes_ago} 分鐘前餵過，確定要再餵一次嗎？` })
    }
  } catch (e) { if (e?.message) return showToast(e.message); return }
  showFeed.value = true
}
async function submitFeed() {
  busy.value = true
  try {
    await recordFeeding(props.spotId, food.value, note.value)
    showFeed.value = false; note.value = ''
    showToast('已記錄餵食，30 分鐘後別忘了回報清理')
    await load(); emit('changed')
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
async function cleanup(p) {
  try { await reportCleanup(p.log_id); showToast('已回報清理'); await load(); emit('changed') } catch (e) { showToast(e.message) }
}
async function join() {
  try { await joinSpot(props.spotId, auth.user.id); showToast('已加入照顧者'); await load() } catch (e) { showToast(e.message) }
}
const cover = (a) => {
  const p = [...(a.animal_photos || [])].sort((x, y) => y.created_at.localeCompare(x.created_at))[0]
  return p ? photoUrl(p.storage_path) : null
}
</script>

<template>
  <div v-if="s" class="info">
    <h3>{{ s.name }}
      <van-tag :color="FOOT[s.footprint]?.[1]" style="margin-left:6px">{{ FOOT[s.footprint]?.[0] }}</van-tag>
      <van-tag v-if="alert?.level === 'red'" color="#e03e3e" style="margin-left:6px" @click="router.push({ name: 'conservation' })">保育熱區內</van-tag>
      <van-tag v-else-if="alert?.level === 'yellow'" color="#f2b705" text-color="#5b4300" style="margin-left:6px" @click="router.push({ name: 'conservation' })">鄰近保育熱區</van-tag>
    </h3>
    <p v-if="alert && alert.level !== 'none'" class="cz">{{ alert.level === 'red' ? '位在' : `距離約 ${Math.round(alert.distance_m)} 公尺：` }}保育熱區「{{ alert.zone_name }}」{{ alert.level === 'red' ? '範圍內' : '' }}，請餵完就清理、不要留食物過夜。</p>
    <p v-if="s.description" class="desc">{{ s.description }}</p>
    <p>動物 {{ s.animal_count }} 隻・<b class="ster">已結紮 {{ s.sterilized_count }} 隻</b></p>
    <p>近 30 天清理率：{{ s.clean_rate_30d == null ? '尚無資料' : Math.round(s.clean_rate_30d * 100) + '%' }}
      <span v-if="s.feedings_30d != null">（{{ s.cleaned_30d }}/{{ s.feedings_30d }} 次）</span></p>
    <p v-if="s.is_fuzzed" class="hint">訪客僅顯示大約位置，登入後可看精確位置</p>

    <van-notice-bar v-for="p in pending" :key="p.log_id" wrapable :scrollable="false" left-icon="brush-o">
      你的餵食還沒回報清理
      <template #right-icon><van-button size="mini" type="primary" @click="cleanup(p)">已清理</van-button></template>
    </van-notice-bar>

    <div class="btns">
      <van-button type="primary" round size="small" icon="fire-o" @click="startFeed">記錄餵食</van-button>
      <van-button v-if="auth.user && !s.is_caretaker" round size="small" plain @click="join">成為照顧者</van-button>
      <van-button v-if="auth.user" round size="small" plain icon="plus" @click="router.push({ name: 'animal-new', params: { id: spotId } })">新增動物</van-button>
    </div>

    <div class="public">
      <a @click="router.push({ name: 'spot-progress', params: { id: spotId } })">公開進度</a>
      <a class="warn" @click="router.push({ name: 'spot-report', params: { id: spotId } })">這裡有問題？匿名通報</a>
    </div>

    <div v-if="animals.length" class="animals">
      <div v-for="a in animals" :key="a.id" class="animal" @click="router.push({ name: 'animal', params: { id: a.id } })">
        <van-image round width="52" height="52" fit="cover" :src="cover(a)">
          <template #error>{{ a.species === 'dog' ? '🐶' : '🐱' }}</template>
        </van-image>
        <div class="an">{{ a.name }}</div>
        <van-tag :type="a.is_sterilized ? 'success' : 'default'" size="medium">{{ a.is_sterilized ? '已結紮' : STAGE[a.tnr_stage] }}</van-tag>
      </div>
    </div>

    <van-action-sheet v-model:show="showFeed" title="記錄餵食">
      <div style="padding:8px 16px 24px">
        <van-radio-group v-model="food" direction="horizontal" style="margin-bottom:12px">
          <van-radio v-for="f in FOOD" :key="f.value" :name="f.value">{{ f.text }}</van-radio>
        </van-radio-group>
        <van-field v-model="note" placeholder="備註（選填）" maxlength="200" />
        <van-button block round type="primary" style="margin-top:12px" :loading="busy" @click="submitFeed">送出</van-button>
      </div>
    </van-action-sheet>
  </div>
</template>

<style scoped>
.info { padding: 16px 20px 24px; max-height: 60vh; overflow: auto; }
.info h3 { margin: 0 0 8px; }
.info p { margin: 4px 0; color: #444; }
.desc { color: #666; }
.ster { color: #2f9e6b; }
.hint { color: #999; font-size: 12px; }
.info p.cz { color: #b42318; font-size: 13px; }
.btns { display: flex; gap: 8px; margin: 12px 0; flex-wrap: wrap; }
.public { display: flex; gap: 18px; font-size: 13px; margin: 0 0 12px; }
.public a { color: #1989fa; }
.public a.warn { color: #b42318; }
.animals { display: flex; gap: 14px; overflow-x: auto; padding-bottom: 4px; }
.animal { display: flex; flex-direction: column; align-items: center; gap: 4px; min-width: 64px; }
.an { font-size: 13px; }
</style>
