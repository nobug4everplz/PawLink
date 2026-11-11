<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth, isAdmin } from '../lib/auth'
import { getAnimal, updateTnrStage, canEditAnimal, uploadAnimalPhoto, photoUrl } from '../lib/api'
import { compressImage } from '../lib/image'

const route = useRoute(), router = useRouter()
const a = ref(null), canEdit = ref(false), saving = ref(false)
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']
const SEX = { male: '公', female: '母', unknown: '未知' }
const SPECIES = { cat: '貓', dog: '狗', other: '其他' }

async function load() {
  try {
    a.value = await getAnimal(route.params.id)
    canEdit.value = await canEditAnimal(a.value, auth.user, isAdmin())
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
    </div>
    <van-cell-group inset>
      <van-cell title="種類" :value="SPECIES[a.species]" />
      <van-cell title="性別" :value="SEX[a.sex]" />
      <van-cell v-if="a.coat" title="毛色" :value="a.coat" />
      <van-cell v-if="a.features" title="特徵" :label="a.features" />
    </van-cell-group>
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
    <van-uploader v-if="canEdit" :after-read="addPhoto" style="margin:12px 16px">
      <van-button size="small" icon="photograph">新增照片</van-button>
    </van-uploader>
  </div>
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
</style>
