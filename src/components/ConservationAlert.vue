<script setup>
// 三層警示橫幅：red＝保育熱區內、yellow＝熱區外 200 公尺內、none 不顯示
import { computed } from 'vue'
import { useRouter } from 'vue-router'

const props = defineProps({ alert: Object, context: { type: String, default: 'spot' } })
const router = useRouter()
const zone = computed(() => {
  const a = props.alert
  if (!a) return ''
  return `「${a.zone_name}」${a.species ? `（${a.species}）` : ''}`
})
const text = computed(() => {
  const a = props.alert
  if (!a || a.level === 'none') return ''
  if (props.context === 'animal') {
    return a.level === 'red'
      ? `這個餵食點位在保育熱區${zone.value}範圍內。這裡的犬貓請優先安排結紮，並留意有沒有追逐野生動物的情形。`
      : `這個餵食點距離保育熱區${zone.value}約 ${Math.round(a.distance_m)} 公尺。這裡的犬貓請盡早安排結紮。`
  }
  return a.level === 'red'
    ? `這裡位在保育熱區${zone.value}範圍內。固定餵食會讓犬貓聚集，威脅野生動物，建議不要在這裡設點。`
    : `這裡距離保育熱區${zone.value}約 ${Math.round(a.distance_m)} 公尺（200 公尺內）。請餵完就清理，不要留食物過夜。`
})
</script>

<template>
  <van-notice-bar
    v-if="text" wrapable :scrollable="false" mode="link" left-icon="warning-o"
    :class="['cz-alert', alert.level]"
    :color="alert.level === 'red' ? '#b42318' : '#8a5a00'"
    :background="alert.level === 'red' ? '#fdecea' : '#fff7d6'"
    @click="router.push({ name: 'conservation' })"
  >
    <b>{{ alert.level === 'red' ? '紅色警示' : '黃色警示' }}</b>　{{ text }}
    <span v-if="alert.is_demo" class="demo">（範圍為示意資料）</span>
  </van-notice-bar>
</template>

<style scoped>.demo { opacity: .75; font-size: 12px; }</style>
