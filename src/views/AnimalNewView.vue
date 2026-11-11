<script setup>
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { createAnimal, uploadAnimalPhoto, checkSpotAlert } from '../lib/api'
import ConservationAlert from '../components/ConservationAlert.vue'
import { compressImage } from '../lib/image'

const route = useRoute(), router = useRouter()
const f = ref({ name: '', species: 'cat', sex: 'unknown', coat: '', features: '', ear_tipped: false, tnr_stage: 1 })
const files = ref([]), busy = ref(false), alert = ref(null)
onMounted(async () => { alert.value = await checkSpotAlert(route.params.id) })
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置'].map((text, i) => ({ text, value: i + 1 }))

async function submit() {
  alert.value = (await checkSpotAlert(route.params.id)) || alert.value
  if (alert.value?.level === 'red' && f.value.tnr_stage < 3) {
    try {
      await showConfirmDialog({ title: '這個餵食點在保育熱區內', message: `「${f.value.name}」還沒結紮，又在保育熱區「${alert.value.zone_name}」範圍內活動，請優先安排結紮。要繼續建檔嗎？`, confirmButtonText: '繼續建檔' })
    } catch { return }
  }
  busy.value = true
  try {
    const fields = { ...f.value, coat: f.value.coat || null, features: f.value.features || null }
    const a = await createAnimal(route.params.id, fields)
    for (const it of files.value) {
      try { await uploadAnimalPhoto(a.id, await compressImage(it.file)) }
      catch (e) { showToast('照片上傳失敗：' + (e.message || e)) }
    }
    router.replace({ name: 'animal', params: { id: a.id } })
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar title="新增動物" left-arrow @click-left="router.back()" />
  <ConservationAlert :alert="alert" context="animal" />
  <van-form @submit="submit">
    <van-cell-group inset style="margin-top:12px">
      <van-field v-model="f.name" label="名字" maxlength="30" :rules="[{ required: true, message: '請輸入名字' }]" />
      <van-field label="種類"><template #input>
        <van-radio-group v-model="f.species" direction="horizontal">
          <van-radio name="cat">貓</van-radio><van-radio name="dog">狗</van-radio><van-radio name="other">其他</van-radio>
        </van-radio-group></template></van-field>
      <van-field label="性別"><template #input>
        <van-radio-group v-model="f.sex" direction="horizontal">
          <van-radio name="male">公</van-radio><van-radio name="female">母</van-radio><van-radio name="unknown">未知</van-radio>
        </van-radio-group></template></van-field>
      <van-field v-model="f.coat" label="毛色" maxlength="50" />
      <van-field v-model="f.features" label="特徵" type="textarea" rows="2" maxlength="500" />
      <van-field label="剪耳"><template #input><van-switch v-model="f.ear_tipped" size="20" /></template></van-field>
      <van-field label="結紮進度"><template #input>
        <van-radio-group v-model="f.tnr_stage">
          <van-radio v-for="s in STAGES" :key="s.value" :name="s.value" style="margin:4px 0">{{ s.value }}. {{ s.text }}</van-radio>
        </van-radio-group></template></van-field>
      <van-field label="照片"><template #input>
        <van-uploader v-model="files" multiple :max-count="3" /></template></van-field>
    </van-cell-group>
    <p class="tip">照片會在手機端壓縮並移除 GPS 位置資訊後才上傳。</p>
    <div style="margin:16px"><van-button round block type="primary" native-type="submit" :loading="busy">建立</van-button></div>
  </van-form>
</template>

<style scoped>.tip { margin: 8px 20px; color: #999; font-size: 12px; }</style>
