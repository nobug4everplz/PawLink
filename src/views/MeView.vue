<script setup>
// 「我的」：個人待辦入口（輪值、TNR 接力、領養）、管理後台、加入主畫面與登出
import { computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showConfirmDialog, showToast } from 'vant'
import { auth, signOut, isAdmin } from '../lib/auth'
import { net } from '../lib/offlineQueue'
import { badges, refreshBadges } from '../lib/badges'

const router = useRouter()
const name = computed(() => auth.profile?.display_name || '已登入')
const initial = computed(() => [...name.value][0] || '🐾')
onMounted(refreshBadges)

async function logout() {
  try {
    await showConfirmDialog({
      title: '登出',
      message: net.count ? `還有 ${net.count} 筆餵食紀錄沒補傳，登出後要再登入同一個帳號才會補傳。確定要登出嗎？` : '確定要登出嗎？',
      confirmButtonText: '登出',
    })
  } catch { return }
  try { await signOut(); showToast('已登出') } catch (e) { showToast(e.message) }
}
</script>

<template>
  <div class="me">
    <header v-if="auth.user" class="card who">
      <div class="avatar">{{ initial }}</div>
      <div class="id">
        <b>{{ name }}</b>
        <span>{{ isAdmin() ? '管理員' : '餵食夥伴' }}・{{ auth.user.email }}</span>
      </div>
    </header>
    <header v-else class="card guest">
      <img src="/pwa-192.png" alt="" width="64" height="64" />
      <h2>一起照顧街上的牠們</h2>
      <p>登入後可以記錄餵食、更新結紮進度、加入餵食點的照顧行列。</p>
      <van-button type="primary" round block data-test="me-login" @click="router.push({ name: 'login', query: { redirect: '/' } })">登入或註冊</van-button>
    </header>

    <template v-if="auth.user">
      <h3>我的待辦</h3>
      <van-cell-group inset>
        <van-cell title="餵食輪值" label="排班、求代班、接手別人的班" icon="calendar-o" is-link @click="router.push({ name: 'shifts' })">
          <template v-if="badges.shifts" #value><span class="count">{{ badges.shifts }} 班求代班</span></template>
        </van-cell>
        <van-cell title="TNR 接力" label="誘捕、送醫、術後照顧、放回分工" icon="exchange" is-link @click="router.push({ name: 'tnr' })">
          <template v-if="badges.tnr" #value><span class="count">{{ badges.tnr }} 件輪到我</span></template>
        </van-cell>
        <van-cell v-if="badges.adopt !== null" title="領養陪伴" label="領養後第 7、30、90 天回報近況" icon="like-o" is-link @click="router.push({ name: 'adoptions' })">
          <template v-if="badges.adopt" #value><span class="count">{{ badges.adopt }} 件待處理</span></template>
        </van-cell>
      </van-cell-group>
    </template>

    <h3>更多</h3>
    <van-cell-group inset>
      <van-cell v-if="isAdmin()" title="管理後台" label="使用者、保育熱區、檢舉與哨兵" icon="setting-o" is-link @click="router.push({ name: 'admin' })" />
      <van-cell title="加入主畫面" label="像 App 一樣開啟，沒有網路也能記錄餵食" icon="apps-o" is-link @click="router.push({ name: 'install' })" />
      <van-cell v-if="auth.user" title="登出" icon="revoke" class="out" clickable data-test="logout" @click="logout" />
    </van-cell-group>
    <p class="foot">PawLink 流浪動物資訊共享與保育警示平台</p>
  </div>
</template>

<style scoped>
.me { max-width: 720px; margin: 0 auto; padding: calc(16px + env(safe-area-inset-top)) 0 24px; }
.card { margin: 0 16px; background: var(--pl-card); border-radius: 20px; box-shadow: var(--pl-shadow); }
.who { display: flex; align-items: center; gap: 14px; padding: 18px; }
.avatar { flex: none; width: 56px; height: 56px; border-radius: 50%; background: var(--pl-green); color: #fff; font-size: 24px; font-weight: 700; display: flex; align-items: center; justify-content: center; }
.id { min-width: 0; display: flex; flex-direction: column; gap: 4px; }
.id b { font-size: 19px; }
.id span { color: var(--pl-muted); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.guest { padding: 28px 22px 22px; text-align: center; }
.guest img { border-radius: 18px; }
.guest h2 { margin: 12px 0 6px; font-size: 20px; }
.guest p { margin: 0 0 18px; color: var(--pl-sub); font-size: 14px; line-height: 1.7; }
h3 { margin: 24px 20px 10px; font-size: 14px; color: var(--pl-sub); font-weight: 700; }
.count { color: var(--pl-red-ink); background: var(--pl-red-soft); font-size: 12px; font-weight: 700; padding: 2px 8px; border-radius: 10px; white-space: nowrap; }
.me :deep(.van-cell__left-icon) { font-size: 20px; color: var(--pl-green); margin-right: 12px; align-self: center; }
.me :deep(.van-cell__value) { flex: none; align-self: center; }
.me :deep(.van-cell__title) { flex: 1; }
.out :deep(.van-cell__left-icon), .out :deep(.van-cell__title) { color: var(--pl-red); }
.foot { margin: 22px 20px 0; text-align: center; color: var(--pl-muted); font-size: 12px; }
</style>
