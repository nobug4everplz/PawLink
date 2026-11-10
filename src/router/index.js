import { createRouter, createWebHistory } from 'vue-router'

export default createRouter({
  history: createWebHistory(),
  routes: [{ path: '/', name: 'map', component: () => import('../views/MapView.vue') }],
})
