<script setup>
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast } from 'vant'
import { auth } from '../lib/auth'
import { getAnimal, updateTnrStage, uploadAnimalPhoto, photoUrl } from '../lib/api'
import { compressImage } from '../lib/image'

const route = useRoute(), router = useRouter()
const a = ref(null)
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置']
const SEX = { male: '公', female: '母', unknown: '未知' }
const SPECIES = { cat: '貓', dog: '狗', other: '其他' }

async function load() { try { a.value = await getAnimal(route.params.id) } catch (e) { showToast(e.message) } }
onMounted(load)

async function setStage(i) {
  try { await updateTnrStage(a.value.id, i + 1); await load() } catch (e) { showToast('無法更新：' + e.message) }
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
    <van-steps :active="a.tnr_stage - 1" active-color="#2f9e6b">
      <van-step v-for="(s, i) in STAGES" :key="s"><span @click="auth.user && setStage(i)">{{ s }}</span></van-step>
    </van-steps>
    <p v-if="auth.user" class="tip">點步驟名稱可更新進度（需為照顧者或建立者）</p>
    <van-uploader v-if="auth.user" :after-read="addPhoto" style="margin:12px 16px">
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
.tip { margin: 4px 16px; color: #999; font-size: 12px; }
</style>
