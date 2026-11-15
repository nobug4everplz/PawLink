<script setup>
import { useRoute } from 'vue-router'
import AppTabbar from './components/AppTabbar.vue'

const route = useRoute()
</script>

<template>
  <div class="shell" :class="{ 'has-tab': route.meta.tab }">
    <router-view />
    <AppTabbar v-if="route.meta.tab" />
  </div>
</template>

<style>
.shell { min-height: 100%; box-sizing: border-box; }
.shell.has-tab { --pl-tabbar-h: calc(58px + env(safe-area-inset-bottom)); padding-bottom: var(--pl-tabbar-h); }
</style>
