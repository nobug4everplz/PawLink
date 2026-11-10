<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast } from 'vant'
import { createAnimal, uploadAnimalPhoto } from '../lib/api'
import { compressImage } from '../lib/image'

const route = useRoute(), router = useRouter()
const f = ref({ name: '', species: 'cat', sex: 'unknown', coat: '', features: '', ear_tipped: false, tnr_stage: 1 })
const files = ref([]), busy = ref(false)
const STAGES = ['未結紮', '誘捕中', '已手術', '術後照護', '已原地回置'].map((text, i) => ({ text, value: i + 1 }))

async function submit() {
  busy.value = true
  try {
    const fields = { ...f.value, coat: f.value.coat || null, features: f.value.features || null }
    const a = await createAnimal(route.params.id, fields)
    for (const it of files.value) await uploadAnimalPhoto(a.id, await compressImage(it.file))
    router.replace({ name: 'animal', params: { id: a.id } })
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar title="新增動物" left-arrow @click-left="router.back()" />
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
