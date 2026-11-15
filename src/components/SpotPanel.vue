<script setup>
import { ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth } from '../lib/auth'
import { isNetworkError } from '../lib/offlineQueue'
import { getSpotSummary, listSpotAnimals, checkRecentFeeding, recordFeeding, getPendingCleanups, reportCleanup, joinSpot, photoUrl, checkSpotAlert } from '../lib/api'

const props = defineProps({ spotId: String, refreshKey: Number })
const emit = defineEmits(['changed'])
const router = useRouter()

const FOOT = { fresh: '剛餵過', recent: '一陣子前', hungry: '久未餵食' }
const FOOD = [{ text: '乾糧', value: 'dry', icon: '🥣' }, { text: '濕食', value: 'wet', icon: '🥫' }, { text: '混合', value: 'mixed', icon: '🍱' }, { text: '其他', value: 'other', icon: '🍽️' }]
const STAGE = ['', '未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']

const s = ref(null), animals = ref([]), pending = ref([]), busy = ref(false), alert = ref(null)
const showFeed = ref(false), food = ref('dry'), note = ref('')

async function load() {
  if (!props.spotId) return
  try {
    s.value = await getSpotSummary(props.spotId)
    if (s.value?.offline) return // 離線：只有地圖上次載入的基本資料
    animals.value = await listSpotAnimals(props.spotId)
    pending.value = auth.user ? (await getPendingCleanups()).filter((p) => p.spot_id === props.spotId) : []
    alert.value = auth.user ? await checkSpotAlert(props.spotId) : null
  } catch (e) { showToast(isNetworkError(e) ? '目前沒有網路，無法載入這個餵食點' : e.message) }
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
  } catch (e) {
    // 使用者在「最近已有人餵過」按取消時 e 不是錯誤物件；離線查不到最近紀錄就直接讓他記
    if (!(e instanceof Error) && !e?.message) return
    if (!isNetworkError(e)) return showToast(e.message)
  }
  showFeed.value = true
}
async function submitFeed() {
  busy.value = true
  try {
    const r = await recordFeeding(props.spotId, food.value, note.value)
    showFeed.value = false; note.value = ''
    showToast(r.queued ? { message: '目前沒有網路，已先存在手機，恢復連線後會自動補傳', duration: 3500 } : '已記錄餵食，30 分鐘後別忘了回報清理')
    if (r.queued) return
    await load(); emit('changed')
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
async function cleanup(p) {
  try { await reportCleanup(p.log_id); showToast('已回報清理'); await load(); emit('changed') } catch (e) { showToast(e.message) }
}
async function join() {
  try { await joinSpot(props.spotId, auth.user.id); showToast('已加入照顧者'); await load() } catch (e) { showToast(e.message) }
}
/** 上次餵食距今多久；沒有紀錄回 null */
function fedAgo(t) {
  if (!t) return null
  const m = Math.max(0, Math.floor((Date.now() - new Date(t).getTime()) / 60000))
  if (m < 1) return '剛剛'
  if (m < 60) return `${m} 分鐘前`
  if (m < 48 * 60) return `${Math.floor(m / 60)} 小時前`
  return `${Math.floor(m / 1440)} 天前`
}
const cover = (a) => {
  const p = [...(a.animal_photos || [])].sort((x, y) => y.created_at.localeCompare(x.created_at))[0]
  return p ? photoUrl(p.storage_path) : null
}
</script>

<template>
  <div v-if="s" class="info">
    <i class="grip" aria-hidden="true" />
    <h3>{{ s.name }}</h3>
    <div v-if="alert && alert.level !== 'none'" class="cz" :class="alert.level" @click="router.push({ name: 'conservation' })">
      <van-icon name="warning-o" />
      <span><b>{{ alert.level === 'red' ? '保育熱區內' : '鄰近保育熱區' }}</b>　{{ alert.level === 'red' ? '位在' : `距離約 ${Math.round(alert.distance_m)} 公尺：` }}保育熱區「{{ alert.zone_name }}」{{ alert.level === 'red' ? '範圍內' : '' }}，請餵完就清理、不要留食物過夜。</span>
    </div>
    <p v-if="s.description" class="desc">{{ s.description }}</p>

    <!-- 已餵食／已結紮：這個點最重要的兩個狀態 -->
    <div class="stats">
      <div class="stat feed" :class="s.footprint" data-test="stat-feed">
        <span class="k"><i class="dot" />餵食狀態</span>
        <b>{{ FOOT[s.footprint] || '尚無紀錄' }}</b>
        <small>{{ fedAgo(s.last_fed_at) ? `上次 ${fedAgo(s.last_fed_at)}` : '還沒有餵食紀錄' }}</small>
      </div>
      <div class="stat ster" :class="{ all: s.animal_count && s.sterilized_count >= s.animal_count }" data-test="stat-ster">
        <span class="k">✂ 已結紮</span>
        <b v-if="s.animal_count">{{ s.sterilized_count ?? 0 }}<em> / {{ s.animal_count }} 隻</em></b>
        <b v-else class="none">尚未登記</b>
        <span class="meter"><i :style="{ width: (s.animal_count ? Math.round((s.sterilized_count / s.animal_count) * 100) : 0) + '%' }" /></span>
      </div>
      <div class="stat clean">
        <span class="k">清理率</span>
        <b>{{ s.clean_rate_30d == null ? '—' : Math.round(s.clean_rate_30d * 100) + '%' }}</b>
        <small>{{ s.feedings_30d != null ? `近 30 天 ${s.cleaned_30d}/${s.feedings_30d} 次` : '近 30 天' }}</small>
      </div>
    </div>
    <p v-if="s.offline" class="hint">目前離線，顯示的是上次載入的資料。仍然可以記錄餵食，恢復連線後會自動補傳。</p>
    <p v-if="s.is_fuzzed" class="hint">訪客僅顯示大約位置，登入後可看精確位置</p>

    <div v-for="p in pending" :key="p.log_id" class="todo">
      <van-icon name="brush-o" />
      <span>你的餵食還沒回報清理</span>
      <van-button size="small" round type="primary" @click="cleanup(p)">已清理</van-button>
    </div>

    <van-button class="feed-btn" type="primary" round block data-test="feed" @click="startFeed">
      <svg class="paw" viewBox="0 0 24 24" aria-hidden="true"><ellipse cx="5" cy="10.5" rx="2.3" ry="3"/><ellipse cx="9.6" cy="5.6" rx="2.3" ry="3.1"/><ellipse cx="14.4" cy="5.6" rx="2.3" ry="3.1"/><ellipse cx="19" cy="10.5" rx="2.3" ry="3"/><path d="M12 11.2c-3.2 0-6 3.3-6 6 0 1.9 1.5 2.8 3.1 2.8 1.2 0 1.9-.6 2.9-.6s1.7.6 2.9.6c1.6 0 3.1-.9 3.1-2.8 0-2.7-2.8-6-6-6z"/></svg>{{ auth.user ? '我餵了，記錄餵食' : '登入後記錄餵食' }}
    </van-button>

    <div class="btns">
      <van-button v-if="auth.user && !s.is_caretaker" round size="small" plain type="primary" icon="friends-o" @click="join">成為照顧者</van-button>
      <van-button v-if="auth.user" round size="small" plain icon="plus" @click="router.push({ name: 'animal-new', params: { id: spotId } })">新增動物</van-button>
      <van-button round size="small" plain icon="chart-trending-o" @click="router.push({ name: 'spot-progress', params: { id: spotId } })">公開進度</van-button>
      <van-button round size="small" plain icon="warning-o" class="warn" @click="router.push({ name: 'spot-report', params: { id: spotId } })">匿名通報</van-button>
    </div>

    <template v-if="animals.length">
      <h4>這裡的動物</h4>
      <div class="animals">
        <button v-for="a in animals" :key="a.id" type="button" class="animal" :class="{ done: a.is_sterilized }" @click="router.push({ name: 'animal', params: { id: a.id } })">
          <span class="pic">
            <van-image round width="60" height="60" fit="cover" :src="cover(a)">
              <template #error><span class="emoji">{{ a.species === 'dog' ? '🐶' : '🐱' }}</span></template>
              <template #loading><span class="emoji">{{ a.species === 'dog' ? '🐶' : '🐱' }}</span></template>
            </van-image>
            <i v-if="a.is_sterilized" class="check" aria-hidden="true"><van-icon name="success" /></i>
          </span>
          <span class="an">{{ a.name }}</span>
          <span class="stage" :class="a.is_sterilized ? 'ok' : a.tnr_stage > 1 ? 'going' : 'none'">{{ a.is_sterilized ? '已結紮' : STAGE[a.tnr_stage] }}</span>
        </button>
      </div>
    </template>

    <van-action-sheet v-model:show="showFeed" title="這次餵了什麼？" teleport="body">
      <div class="feed-sheet">
        <div class="foods" role="radiogroup" aria-label="食物種類">
          <button v-for="f in FOOD" :key="f.value" type="button" role="radio" :aria-checked="food === f.value" class="food" :class="{ on: food === f.value }" @click="food = f.value">
            <span>{{ f.icon }}</span>{{ f.text }}
          </button>
        </div>
        <van-field v-model="note" class="note" placeholder="備註（選填）" maxlength="200" />
        <van-button block round type="primary" class="feed-btn" :loading="busy" data-test="feed-submit" @click="submitFeed">確認已餵食</van-button>
        <p class="hint center">送出後地圖上的腳印會變成綠色，30 分鐘後記得回報清理。</p>
      </div>
    </van-action-sheet>
  </div>
</template>

<style scoped>
.info { padding: 10px 18px calc(22px + env(safe-area-inset-bottom)); max-height: 68vh; overflow: auto; }
.grip { display: block; width: 36px; height: 4px; border-radius: 2px; background: #dcd9ce; margin: 0 auto 12px; }
.info h3 { margin: 0 36px 8px 0; font-size: 20px; line-height: 1.3; }
.desc { margin: 0 0 10px; color: var(--pl-sub); font-size: 14px; line-height: 1.55; }
.hint { margin: 8px 0 0; color: var(--pl-muted); font-size: 12px; line-height: 1.5; }
.hint.center { text-align: center; margin-top: 10px; }
.cz { display: flex; gap: 8px; align-items: flex-start; border-radius: 12px; padding: 9px 12px; margin: 0 0 10px; font-size: 13px; line-height: 1.5; cursor: pointer; }
.cz .van-icon { font-size: 16px; margin-top: 2px; }
.cz.red { background: var(--pl-red-soft); color: var(--pl-red-ink); }
.cz.yellow { background: var(--pl-amber-soft); color: var(--pl-amber-ink); }

.stats { display: grid; grid-template-columns: 1.15fr 1.15fr 1fr; gap: 8px; }
.stat { border-radius: 14px; padding: 10px 10px 11px; background: #f3f1ea; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.stat .k { font-size: 12px; font-weight: 600; color: var(--pl-sub); display: flex; align-items: center; gap: 5px; white-space: nowrap; }
.stat b { font-size: 19px; line-height: 1.25; white-space: nowrap; }
.stat b em { font-style: normal; font-size: 13px; font-weight: 600; color: var(--pl-sub); }
.stat small { font-size: 11px; color: var(--pl-sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.stat .dot { width: 9px; height: 9px; border-radius: 50%; background: currentColor; }
.stat.feed.fresh { background: var(--pl-green-soft); }
.stat.feed.fresh b, .stat.feed.fresh .dot { color: var(--pl-green-dark); }
.stat.feed.recent { background: var(--pl-amber-soft); }
.stat.feed.recent b, .stat.feed.recent .dot { color: var(--pl-amber-ink); }
.stat.feed.hungry { background: var(--pl-red-soft); }
.stat.feed.hungry b, .stat.feed.hungry .dot { color: var(--pl-red-ink); }
.stat.ster b { color: var(--pl-green-dark); }
.stat.ster b.none { color: var(--pl-sub); font-size: 16px; }
.stat.ster.all { background: var(--pl-green-soft); }
.meter { display: block; height: 6px; border-radius: 3px; background: #dedbd0; overflow: hidden; margin-top: 5px; }
.meter i { display: block; height: 100%; border-radius: 3px; background: var(--pl-green); transition: width .3s; }

.todo { display: flex; align-items: center; gap: 8px; margin-top: 10px; padding: 8px 8px 8px 12px; border-radius: 14px; background: var(--pl-amber-soft); color: var(--pl-amber-ink); font-size: 14px; font-weight: 600; }
.todo span { flex: 1; }
.todo .van-icon { font-size: 18px; }

.feed-btn { height: 52px; font-size: 17px; font-weight: 700; margin-top: 12px; }
.feed-btn .paw { width: 22px; height: 22px; fill: currentColor; margin-right: 8px; vertical-align: -4px; }
.btns { display: flex; gap: 8px; margin: 12px 0 0; flex-wrap: wrap; }
.btns .warn { color: var(--pl-red-ink); }

h4 { margin: 18px 0 8px; font-size: 14px; color: var(--pl-sub); }
.animals { display: flex; gap: 6px; overflow-x: auto; margin: 0 -18px; padding: 2px 18px 6px; scrollbar-width: none; }
.animals::-webkit-scrollbar { display: none; }
.animal { flex: none; width: 78px; border: 0; background: none; padding: 0; font: inherit; color: inherit; display: flex; flex-direction: column; align-items: center; gap: 4px; cursor: pointer; }
.pic { position: relative; width: 60px; height: 60px; border-radius: 50%; box-shadow: 0 0 0 3px #e4e1d6; }
.animal.done .pic { box-shadow: 0 0 0 3px var(--pl-green); }
.pic :deep(.van-image__error), .pic :deep(.van-image__loading) { background: #f3f1ea; border-radius: 50%; }
.emoji { font-size: 28px; }
.check { position: absolute; right: -4px; bottom: -3px; width: 22px; height: 22px; border-radius: 50%; background: var(--pl-green); color: #fff; font-size: 13px; display: flex; align-items: center; justify-content: center; box-shadow: 0 0 0 2px #fff; }
.an { font-size: 13px; font-weight: 600; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; margin-top: 2px; }
.stage { font-size: 11px; font-weight: 700; padding: 1px 7px; border-radius: 9px; white-space: nowrap; }
.stage.ok { background: var(--pl-green-soft); color: var(--pl-green-dark); }
.stage.going { background: var(--pl-amber-soft); color: var(--pl-amber-ink); }
.stage.none { background: #eceae2; color: var(--pl-sub); }

.feed-sheet { padding: 4px 16px calc(20px + env(safe-area-inset-bottom)); }
.foods { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
.food { border: 2px solid var(--pl-line); background: #fff; border-radius: 14px; padding: 12px 0 10px; font: inherit; font-size: 14px; font-weight: 600; color: var(--pl-ink); display: flex; flex-direction: column; align-items: center; gap: 4px; cursor: pointer; }
.food span { font-size: 26px; line-height: 1.1; }
.food.on { border-color: var(--pl-green); background: var(--pl-green-soft); color: var(--pl-green-dark); }
.note { margin-top: 12px; background: #f3f1ea; border-radius: 12px; }
</style>
