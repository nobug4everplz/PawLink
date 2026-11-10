<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showDialog } from 'vant'
import { signIn, signUp } from '../lib/auth'

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
    showToast(e.message || '失敗')
  } finally { busy.value = false }
}
</script>

<template>
  <van-nav-bar :title="mode === 'login' ? '登入' : '註冊'" left-arrow @click-left="router.back()" />
  <van-form @submit="submit">
    <van-cell-group inset style="margin-top:16px">
      <van-field v-if="mode === 'register'" v-model="name" label="暱稱" maxlength="30" :rules="[{ required: true, message: '請輸入暱稱' }]" />
      <van-field v-model="email" type="email" label="Email" :rules="[{ required: true, message: '請輸入 Email' }]" />
      <van-field v-model="password" type="password" label="密碼" :rules="[{ required: true, validator: (v) => v.length >= 6, message: '至少 6 碼' }]" />
    </van-cell-group>
    <div style="margin:16px">
      <van-button round block type="primary" native-type="submit" :loading="busy">{{ mode === 'login' ? '登入' : '註冊' }}</van-button>
      <van-button round block plain style="margin-top:12px" @click="mode = mode === 'login' ? 'register' : 'login'">
        {{ mode === 'login' ? '還沒有帳號？註冊' : '已有帳號？登入' }}
      </van-button>
    </div>
  </van-form>
</template>
