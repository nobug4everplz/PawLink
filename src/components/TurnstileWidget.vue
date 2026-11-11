<script setup>
// Cloudflare Turnstile 人機驗證。site key 來自 VITE_TURNSTILE_SITE_KEY（公開金鑰）；secret 只放在資料庫
import { ref, onMounted, onBeforeUnmount } from 'vue'

const emit = defineEmits(['update:modelValue'])
const siteKey = import.meta.env.VITE_TURNSTILE_SITE_KEY
const el = ref(null), failed = ref(false)
let widgetId = null

function loadScript() {
  if (window.turnstile) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const s = document.createElement('script')
    s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'
    s.async = true
    s.onload = resolve
    s.onerror = reject
    document.head.appendChild(s)
  })
}
onMounted(async () => {
  if (!siteKey) return
  try {
    await loadScript()
    widgetId = window.turnstile.render(el.value, {
      sitekey: siteKey,
      callback: (token) => emit('update:modelValue', token),
      'expired-callback': () => emit('update:modelValue', ''),
      'error-callback': () => { failed.value = true; emit('update:modelValue', '') },
    })
  } catch { failed.value = true }
})
onBeforeUnmount(() => { if (widgetId != null) window.turnstile?.remove(widgetId) })
/** token 只能用一次，送出失敗後要重新驗證 */
defineExpose({ reset: () => { emit('update:modelValue', ''); if (widgetId != null) window.turnstile?.reset(widgetId) } })
</script>

<template>
  <div class="ts">
    <div v-if="siteKey" ref="el" />
    <p v-if="!siteKey" class="err">人機驗證尚未設定完成，暫時無法送出通報，請聯絡管理員。</p>
    <p v-else-if="failed" class="err">人機驗證載入失敗，請重新整理頁面再試。</p>
  </div>
</template>

<style scoped>
.ts { margin: 12px 16px 0; }
.err { color: #b42318; font-size: 13px; margin: 0; }
</style>
