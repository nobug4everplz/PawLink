<script setup>
// 居民匿名通報（FR-2.1）：不用登入，不收任何個人資料
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getSpotSummary, submitReport, reportCaptchaRequired, REPORT_CATEGORY } from '../lib/api'
import TurnstileWidget from '../components/TurnstileWidget.vue'

const route = useRoute(), router = useRouter()
const spot = ref(null), category = ref('mess'), description = ref('')
const needCaptcha = ref(false), token = ref(''), ts = ref(null)
const busy = ref(false), done = ref(false)

onMounted(async () => {
  try { spot.value = await getSpotSummary(route.params.id) } catch (e) { showToast(e.message) }
  needCaptcha.value = await reportCaptchaRequired()
})
async function submit() {
  if (needCaptcha.value && !token.value) return showToast('請先完成人機驗證')
  busy.value = true
  try {
    await submitReport(route.params.id, category.value, description.value.trim(), token.value)
    done.value = true
  } catch (e) {
    showToast({ message: e.message || '送出失敗', duration: 4000 })
    ts.value?.reset()
  } finally { busy.value = false }
}
const back = () => (window.history.length > 1 ? router.back() : router.replace('/'))
</script>

<template>
  <van-nav-bar title="通報問題" left-arrow @click-left="back" />
  <div v-if="done" class="done">
    <van-icon name="passed" size="56" color="#2f9e6b" />
    <h3>已送出，謝謝你的通報</h3>
    <p>這個餵食點的照顧者會收到通知。通報內容只有照顧者與管理員看得到，處理進度會公開在進度頁。</p>
    <van-button round type="primary" @click="router.replace({ name: 'spot-progress', params: { id: route.params.id } })">查看處理進度</van-button>
    <van-button round plain style="margin-top:12px" @click="router.replace('/')">回地圖</van-button>
  </div>
  <template v-else>
    <van-notice-bar wrapable :scrollable="false" left-icon="shield-o" color="#1f7a50" background="#e8f6ef">
      不用登入，也不會記錄你的身分。通報內容只有這個餵食點的照顧者與管理員看得到。
    </van-notice-bar>
    <van-form @submit="submit">
      <van-cell-group inset style="margin-top:12px">
        <van-cell title="餵食點" :value="spot?.name || '載入中'" />
        <van-field label="問題類別"><template #input>
          <van-radio-group v-model="category">
            <van-radio v-for="(text, key) in REPORT_CATEGORY" :key="key" :name="key" style="margin:4px 0">{{ text }}</van-radio>
          </van-radio-group></template></van-field>
        <van-field v-model="description" label="說明" type="textarea" rows="4" maxlength="500" show-word-limit
          placeholder="發生了什麼事、大約什麼時間。請不要寫出任何人的姓名、電話或門牌。"
          :rules="[{ validator: (v) => v.trim().length >= 5, message: '請至少寫 5 個字' }]" />
      </van-cell-group>
      <TurnstileWidget v-if="needCaptcha" ref="ts" v-model="token" />
      <p class="tip">為避免灌水，同一個網路 1 分鐘內只能送出一則、1 小時內最多三則。</p>
      <div style="margin:16px"><van-button round block type="primary" native-type="submit" :loading="busy" :disabled="!spot">送出通報</van-button></div>
    </van-form>
  </template>
</template>

<style scoped>
.tip { margin: 10px 20px 0; color: #999; font-size: 12px; }
.done { padding: 48px 28px; text-align: center; display: flex; flex-direction: column; align-items: center; }
.done p { color: #555; line-height: 1.7; margin: 0 0 24px; }
.done .van-button { width: 220px; }
</style>
