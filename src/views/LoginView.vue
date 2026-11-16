<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showDialog } from 'vant'
import { signIn, signUp, authErrorText } from '../lib/auth'

const route = useRoute(), router = useRouter()
const mode = ref('login')
const email = ref(''), password = ref(''), name = ref('')
const busy = ref(false)

async function submit() {
  busy.value = true
  try {
    if (mode.value === 'login') {
      await signIn(email.value, password.value)
    } else {
      const d = await signUp(email.value, password.value, name.value)
      if (!d.session) { await showDialog({ message: '註冊成功，請到信箱點擊驗證連結後再登入。' }); mode.value = 'login'; return }
    }
    router.replace(route.query.redirect || '/')
  } catch (e) {
    showToast(/[\u4e00-\u9fff]/.test(e?.message || '') ? e.message : authErrorText(e))
  } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar left-arrow @click-left="router.back()" />
  <div class="login">
    <header>
      <img src="/pwa-192.png" alt="" width="72" height="72" />
      <h1>PawLink</h1>
      <p>記錄餵食、追蹤結紮，一起照顧街上的牠們</p>
    </header>
    <div class="seg" role="tablist">
      <button type="button" role="tab" :aria-selected="mode === 'login'" :class="{ on: mode === 'login' }" @click="mode = 'login'">登入</button>
      <button type="button" role="tab" :aria-selected="mode === 'register'" :class="{ on: mode === 'register' }" @click="mode = 'register'">註冊</button>
    </div>
    <van-form @submit="submit">
      <van-cell-group inset>
        <van-field v-if="mode === 'register'" v-model="name" label="暱稱" maxlength="30" placeholder="其他人看到的名字" autocomplete="nickname" :rules="[{ required: true, message: '請輸入暱稱' }]" />
        <van-field v-model="email" type="email" label="Email" placeholder="you@example.com" autocomplete="email" :rules="[{ required: true, message: '請輸入 Email' }]" />
        <van-field v-model="password" type="password" label="密碼" placeholder="至少 6 碼" :autocomplete="mode === 'login' ? 'current-password' : 'new-password'" :rules="[{ required: true, validator: (v) => v.length >= 6, message: '至少 6 碼' }]" />
      </van-cell-group>
      <div class="go">
        <van-button round block type="primary" native-type="submit" :loading="busy">{{ mode === 'login' ? '登入' : '建立帳號' }}</van-button>
      </div>
    </van-form>
    <p class="tip">不登入也能看地圖與公開進度；記錄餵食、更新結紮進度需要登入。</p>
  </div>
</template>

<style scoped>
.login { max-width: 480px; margin: 0 auto; padding-bottom: 32px; }
header { text-align: center; padding: 8px 24px 22px; }
header img { border-radius: 20px; box-shadow: var(--pl-shadow); }
header h1 { margin: 12px 0 4px; font-size: 26px; letter-spacing: .02em; }
header p { margin: 0; color: var(--pl-sub); font-size: 14px; }
.seg { display: flex; margin: 0 16px 14px; padding: 4px; border-radius: 14px; background: #e9e6dc; }
.seg button { flex: 1; height: 38px; border: 0; border-radius: 10px; background: none; font: inherit; font-size: 15px; font-weight: 600; color: var(--pl-sub); cursor: pointer; }
.seg button.on { background: #fff; color: var(--pl-ink); box-shadow: 0 1px 3px rgba(31, 42, 36, .15); }
.go { margin: 18px 16px 0; }
.go .van-button { height: 50px; }
.tip { margin: 16px 24px 0; text-align: center; color: var(--pl-muted); font-size: 12px; line-height: 1.6; }
</style>
