<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth, isAdmin } from '../lib/auth'
import { getAnimal, updateTnrStage, canEditAnimal, uploadAnimalPhoto, photoUrl, reportSighting, getAnimalSightings, SIGHTING_CONDITION, getTnrTasks, openTnrCase } from '../lib/api'
import TnrSteps from '../components/TnrSteps.vue'
import { compressImage } from '../lib/image'

const route = useRoute(), router = useRouter()
const a = ref(null), canEdit = ref(false), saving = ref(false)
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']
const SEX = { male: '公', female: '母', unknown: '未知' }
const SPECIES = { cat: '貓', dog: '狗', other: '其他' }
const STATUS = { missing: ['失蹤中', 'warning'], deceased: ['已過世', 'default'], adopted: ['已送養', 'primary'] }
// TNR 接力（FR-5.2）。tnr 是 null 表示資料庫還沒有這個功能
const tnr = ref(null)
async function startRelay() {
  try { await showConfirmDialog({ title: '發起 TNR 接力', message: `把「${a.value.name}」的誘捕、送醫、術後照顧、放回分成四個任務，讓大家分別認領。` }) } catch { return }
  try { await openTnrCase(a.value.id); showToast('已發起，等大家認領'); await load() } catch (e) { showToast(e.message) }
}
// 哨兵（FR-4.2）：回報目擊。sightings 是 null 表示資料庫還沒有這個功能，整區不顯示
const sightings = ref(null), showSight = ref(false), cond = ref('normal'), note = ref(''), sending = ref(false)
const ago = (t) => {
  const h = Math.floor((Date.now() - new Date(t).getTime()) / 3600000)
  return h < 1 ? '不到 1 小時前' : h < 24 ? `${h} 小時前` : `${Math.floor(h / 24)} 天前`
}
const when = (t) => new Date(t).toLocaleString('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })
async function sendSighting() {
  sending.value = true
  try {
    const r = await reportSighting(a.value.id, cond.value, note.value.trim())
    showSight.value = false; cond.value = 'normal'; note.value = ''
    showToast(r?.alert_id ? '已回報，並通知照顧者留意牠的健康' : r?.missing_resolved ? '已回報，失蹤提醒已解除' : '已回報，謝謝你')
    await load()
  } catch (e) { showToast(e.message) } finally { sending.value = false }
}

async function load() {
  try {
    a.value = await getAnimal(route.params.id)
    canEdit.value = await canEditAnimal(a.value, auth.user, isAdmin())
    sightings.value = auth.user ? await getAnimalSightings(a.value.id) : null
    tnr.value = auth.user ? await getTnrTasks(a.value.id) : null
  } catch (e) { showToast(e.message) }
}
onMounted(load)
watch(() => [auth.user?.id, auth.profile?.role], () => { if (a.value) load() })

async function setStage(stage) {
  if (!canEdit.value || saving.value || stage === a.value.tnr_stage) return
  try { await showConfirmDialog({ title: '更新結紮進度', message: `把「${a.value.name}」的進度改為「${STAGES[stage - 1]}」？` }) } catch { return }
  saving.value = true
  try {
    await updateTnrStage(a.value.id, stage)
    await load()
    showToast(a.value.is_sterilized ? '已更新，標記為已結紮' : '已更新進度')
  } catch (e) { showToast('無法更新：' + e.message) } finally { saving.value = false }
}
async function addPhoto(it) {
  try { await uploadAnimalPhoto(a.value.id, await compressImage(it.file)); await load() } catch (e) { showToast(e.message) }
}
</script>

<template>
  <van-nav-bar title="動物身分檔" left-arrow @click-left="router.back()" />
  <div v-if="a" class="wrap">
    <van-swipe v-if="a.animal_photos.length" class="photos" :autoplay="0">
      <van-swipe-item v-for="p in a.animal_photos" :key="p.id"><img :src="photoUrl(p.storage_path)" /></van-swipe-item>
    </van-swipe>
    <div class="head">
      <h2>{{ a.name }}</h2>
      <van-tag v-if="a.is_sterilized" type="success" size="large">已結紮</van-tag>
      <van-tag v-if="a.ear_tipped" plain size="large" style="margin-left:6px">剪耳</van-tag>
      <van-tag v-if="STATUS[a.status]" :type="STATUS[a.status][1]" size="large" style="margin-left:6px">{{ STATUS[a.status][0] }}</van-tag>
    </div>
    <van-cell-group inset>
      <van-cell title="種類" :value="SPECIES[a.species]" />
      <van-cell title="性別" :value="SEX[a.sex]" />
      <van-cell v-if="a.coat" title="毛色" :value="a.coat" />
      <van-cell v-if="a.features" title="特徵" :label="a.features" />
      <van-cell v-if="a.last_seen_at" title="最後出現" :value="ago(a.last_seen_at)" />
    </van-cell-group>
    <template v-if="sightings">
      <div class="sight-head">
        <h4>目擊紀錄</h4>
        <van-button round size="small" type="primary" icon="eye-o" @click="showSight = true">回報目擊</van-button>
      </div>
      <van-cell-group v-if="sightings.length" inset>
        <van-cell v-for="g in sightings" :key="g.id" :title="when(g.seen_at)" :label="[g.spot_name, g.reporter_name, g.note].filter(Boolean).join('・')">
          <template #value><van-tag :type="g.condition === 'normal' ? 'success' : 'danger'" plain>{{ SIGHTING_CONDITION[g.condition] }}</van-tag></template>
        </van-cell>
      </van-cell-group>
      <p class="tip">看到牠就回報一下。太久沒人看到，或有人回報受傷，系統會提醒照顧者。</p>
    </template>
    <h4 class="sec">結紮（TNR）進度</h4>
    <van-cell-group inset class="stages">
      <van-cell v-for="(s, i) in STAGES" :key="s" :title="`${i + 1}. ${s}`" :clickable="canEdit" :class="{ done: i + 1 < a.tnr_stage, now: i + 1 === a.tnr_stage }" @click="setStage(i + 1)">
        <template #icon><van-icon :name="i + 1 <= a.tnr_stage ? 'checked' : 'circle'" class="dot" /></template>
        <template #value><span v-if="i + 1 === a.tnr_stage">目前</span><span v-else-if="canEdit" class="set">設為此階段</span></template>
      </van-cell>
    </van-cell-group>
    <p v-if="canEdit" class="tip">點任一階段即可更新；「已手術」起會自動標記已結紮。</p>
    <p v-else-if="auth.user" class="tip">只有建立者或該餵食點的照顧者可以更新進度。到餵食點面板按「成為照顧者」即可。</p>
    <p v-else class="tip">登入後，建立者或照顧者可以更新進度。</p>
    <template v-if="tnr">
      <div class="sight-head">
        <h4>TNR 接力</h4>
        <van-button v-if="canEdit && a.tnr_stage < 5 && !(tnr.length && tnr[0].case_status === 'open')" round size="small" type="primary" icon="exchange" @click="startRelay">發起接力</van-button>
      </div>
      <TnrSteps v-if="tnr.length" :tasks="tnr" @changed="load" />
      <p v-else class="tip">還沒有人發起。發起後，誘捕、送醫、術後照顧、放回可以由不同的人認領，每完成一步，上面的結紮進度會自動更新。</p>
    </template>
    <van-uploader v-if="canEdit" :after-read="addPhoto" style="margin:12px 16px">
      <van-button size="small" icon="photograph">新增照片</van-button>
    </van-uploader>
  </div>
  <van-popup v-model:show="showSight" position="bottom" round closeable>
    <div v-if="a" class="sheet">
      <h4>我看到「{{ a.name }}」了</h4>
      <van-radio-group v-model="cond" class="conds">
        <van-radio v-for="(label, k) in SIGHTING_CONDITION" :key="k" :name="k">{{ label }}</van-radio>
      </van-radio-group>
      <van-field v-model="note" type="textarea" rows="2" maxlength="200" show-word-limit class="note" placeholder="備註（選填），例：左後腳不敢著地" />
      <van-button block round type="primary" :loading="sending" style="margin-top:14px" @click="sendSighting">送出</van-button>
      <p v-if="cond !== 'normal'" class="tip" style="margin:10px 0 0">送出後會立刻通知這隻動物的照顧者。</p>
    </div>
  </van-popup>
</template>

<style scoped>
.wrap { padding-bottom: 32px; }
.photos img { width: 100%; height: 260px; object-fit: cover; }
.head { display: flex; align-items: center; padding: 12px 16px 4px; }
.head h2 { margin: 0 10px 0 0; }
.sec { margin: 16px 16px 0; }
.stages { margin-top: 8px; }
.dot { font-size: 18px; margin-right: 8px; color: #c8c9cc; align-self: center; }
.done .dot, .now .dot { color: #2f9e6b; }
.now :deep(.van-cell__title) { font-weight: 600; color: #2f9e6b; }
.set { color: #1989fa; }
.tip { margin: 8px 16px; color: #999; font-size: 12px; }
.sight-head { display: flex; align-items: center; justify-content: space-between; margin: 16px 16px 8px; }
.sight-head h4 { margin: 0; }
.sheet { padding: 20px 16px 24px; }
.sheet h4 { margin: 0 32px 14px 0; }
.conds { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 14px; }
.note { background: #f7f8fa; border-radius: 8px; }
</style>
