import { createRouter, createWebHistory } from 'vue-router'
import { showToast } from 'vant'
import { auth, initAuth, isAdmin } from '../lib/auth'
import { isChunkError, reloadForUpdate } from '../lib/update'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'map', component: () => import('../views/MapView.vue'), meta: { tab: 'map' } },
    { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
    { path: '/spots/new', name: 'spot-new', component: () => import('../views/SpotNewView.vue'), meta: { auth: true } },
    { path: '/spots/:id/animals/new', name: 'animal-new', component: () => import('../views/AnimalNewView.vue'), meta: { auth: true } },
    { path: '/animals/:id', name: 'animal', component: () => import('../views/AnimalView.vue') },
    { path: '/install', name: 'install', component: () => import('../views/InstallView.vue') },
    { path: '/conservation', name: 'conservation', component: () => import('../views/ConservationView.vue'), meta: { tab: 'conservation' } },
    { path: '/spots/:id/report', name: 'spot-report', component: () => import('../views/ReportView.vue') },
    { path: '/spots/:id/progress', name: 'spot-progress', component: () => import('../views/SpotProgressView.vue') },
    { path: '/reports', name: 'inbox', component: () => import('../views/InboxView.vue'), meta: { auth: true, tab: 'inbox' } },
    { path: '/tnr', name: 'tnr', component: () => import('../views/TnrView.vue'), meta: { auth: true } },
    { path: '/adoptions', name: 'adoptions', component: () => import('../views/AdoptionView.vue'), meta: { auth: true } },
    { path: '/shifts', name: 'shifts', component: () => import('../views/ShiftsView.vue'), meta: { auth: true } },
    { path: '/community', name: 'community', component: () => import('../views/CommunityView.vue'), meta: { auth: true, tab: 'community' } },
    { path: '/me', name: 'me', component: () => import('../views/MeView.vue'), meta: { tab: 'me' } },
    { path: '/community/:id', name: 'post', component: () => import('../views/PostView.vue'), meta: { auth: true } },
    { path: '/admin', name: 'admin', component: () => import('../views/AdminView.vue'), meta: { auth: true, admin: true } },
    { path: '/admin/zones/:id', name: 'zone-edit', component: () => import('../views/ZoneEditView.vue'), meta: { auth: true, admin: true } },
  ],
  scrollBehavior: (to, from, saved) => saved || { top: 0 },
})

const ready = initAuth()
router.beforeEach(async (to) => {
  await ready
  if (to.meta.auth && !auth.user) return { name: 'login', query: { redirect: to.fullPath } }
  // 只是介面上的擋門；真正的權限由資料庫 RLS 與 RPC 檢查
  if (to.meta.admin && !isAdmin()) { showToast('只有管理員可以進入後台'); return { name: 'map' } }
})
// 新版上線後，還開著的舊頁面會載不到分頁程式：重新整理到要去的那一頁
router.onError((err, to) => {
  if (!isChunkError(err)) return
  if (!reloadForUpdate(to?.fullPath)) showToast('頁面載入失敗，請確認網路後再試一次')
})
export default router
