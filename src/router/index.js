import { createRouter, createWebHistory } from 'vue-router'
import { auth, initAuth } from '../lib/auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'map', component: () => import('../views/MapView.vue') },
    { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
    { path: '/spots/new', name: 'spot-new', component: () => import('../views/SpotNewView.vue'), meta: { auth: true } },
    { path: '/spots/:id/animals/new', name: 'animal-new', component: () => import('../views/AnimalNewView.vue'), meta: { auth: true } },
    { path: '/animals/:id', name: 'animal', component: () => import('../views/AnimalView.vue') },
  ],
})

const ready = initAuth()
router.beforeEach(async (to) => {
  await ready
  if (to.meta.auth && !auth.user) return { name: 'login', query: { redirect: to.fullPath } }
})
export default router
