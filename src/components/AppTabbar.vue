<script setup>
// 底部分頁列：地圖、保育、交流、通知、我的。只出現在這五個主要頁面（路由 meta.tab）
import { computed, onMounted, onBeforeUnmount, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { auth } from '../lib/auth'
import { badges, refreshBadges } from '../lib/badges'

const route = useRoute(), router = useRouter()
const mine = computed(() => badges.shifts + badges.tnr + (badges.adopt || 0))
const tabs = computed(() => [
  { key: 'map', to: '/', label: '地圖', icon: 'location-o', on: 'location' },
  { key: 'conservation', to: '/conservation', label: '保育', icon: 'flower-o', on: 'flower-o' },
  { key: 'community', to: '/community', label: '交流', icon: 'chat-o', on: 'chat' },
  { key: 'inbox', to: '/reports', label: '通知', icon: 'bell', on: 'bell', badge: badges.inbox },
  { key: 'me', to: '/me', label: auth.user ? '我的' : '登入', icon: 'user-o', on: 'user', badge: mine.value },
])
function go(t) { if (route.meta.tab !== t.key) router.push(t.to) }

let timer
onMounted(() => { refreshBadges(); timer = setInterval(refreshBadges, 5 * 60e3) })
onBeforeUnmount(() => clearInterval(timer))
watch(() => [auth.user?.id, route.meta.tab], refreshBadges)
</script>

<template>
  <nav class="tabbar" aria-label="主要分頁">
    <button v-for="t in tabs" :key="t.key" type="button" class="tab" :class="{ on: route.meta.tab === t.key }"
            :aria-current="route.meta.tab === t.key ? 'page' : undefined" :data-test="`tab-${t.key}`" @click="go(t)">
      <span class="ico">
        <van-icon :name="route.meta.tab === t.key ? t.on : t.icon" />
        <i v-if="t.badge" class="num">{{ t.badge > 99 ? '99+' : t.badge }}</i>
      </span>
      <span class="txt">{{ t.label }}</span>
    </button>
  </nav>
</template>

<style scoped>
.tabbar { position: fixed; left: 0; right: 0; bottom: 0; z-index: 1500; display: flex; height: calc(58px + env(safe-area-inset-bottom)); padding-bottom: env(safe-area-inset-bottom); box-sizing: border-box; background: rgba(255, 255, 255, .96); backdrop-filter: blur(12px); border-top: 1px solid var(--pl-line); }
.tab { flex: 1; border: 0; background: none; padding: 6px 0 4px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; color: var(--pl-muted); font: inherit; cursor: pointer; }
.ico { position: relative; font-size: 23px; line-height: 1; height: 26px; min-width: 44px; display: flex; align-items: center; justify-content: center; border-radius: 13px; transition: background .15s; }
.txt { font-size: 11px; font-weight: 600; }
.tab.on { color: var(--pl-green); }
.tab.on .ico { background: var(--pl-green-soft); }
.num { position: absolute; top: -5px; left: 26px; min-width: 16px; height: 16px; padding: 0 4px; box-sizing: border-box; border-radius: 8px; background: var(--pl-red); color: #fff; font-size: 10px; font-weight: 700; font-style: normal; line-height: 16px; text-align: center; box-shadow: 0 0 0 2px #fff; }
</style>
