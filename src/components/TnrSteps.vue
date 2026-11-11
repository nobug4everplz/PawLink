<script setup>
// 一個 TNR 接力案件的四個步驟：誰認領了、輪到哪一步、認領／完成／放棄
// 能不能做都由資料庫的 RPC 決定
import { ref, computed } from 'vue'
import { showToast, showConfirmDialog } from 'vant'
import { TNR_STEP, claimTnrTask, unclaimTnrTask, completeTnrTask, cancelTnrCase } from '../lib/api'

const props = defineProps({ tasks: { type: Array, required: true } })
const emit = defineEmits(['changed'])
const busy = ref(false)
const c = computed(() => props.tasks[0])
const CASE = { open: ['進行中', 'primary'], done: ['已完成', 'success'], cancelled: ['已取消', 'default'] }

async function run(fn, okMsg) {
  busy.value = true
  try { await fn(); showToast(okMsg) } catch (e) { showToast(e.message) } finally { busy.value = false; emit('changed') }
}
const claim = (t) => run(() => claimTnrTask(t.task_id), `已認領「${TNR_STEP[t.step]}」`)
const giveUp = (t) => run(() => unclaimTnrTask(t.task_id), '已放棄，任務回到待認領')
async function done(t) {
  try { await showConfirmDialog({ title: `回報「${TNR_STEP[t.step]}」完成`, message: '結紮進度會跟著更新。' }) } catch { return }
  await run(() => completeTnrTask(t.task_id), t.step === 'release' ? '四步都完成了，謝謝大家' : '已回報完成，結紮進度已更新')
}
async function cancel() {
  try { await showConfirmDialog({ title: '取消這次接力', message: '已完成的步驟會保留在結紮進度裡。' }) } catch { return }
  await run(() => cancelTnrCase(c.value.case_id), '已取消')
}
function hint(t) {
  if (t.status === 'done') return t.claimer_name ? `${t.claimer_name} 完成` : (t.note || '已完成')
  if (t.status === 'claimed') return `${t.is_mine ? '我' : (t.claimer_name || '有人') + ' '}認領${t.is_ready ? '，輪到這一步' : ''}`
  return t.is_ready ? '待認領，輪到這一步' : '待認領'
}
</script>

<template>
  <van-cell-group inset class="tnr-steps">
    <van-cell v-for="t in tasks" :key="t.task_id" :class="{ done: t.status === 'done', ready: t.is_ready }">
      <template #icon><van-icon :name="t.status === 'done' ? 'checked' : t.status === 'claimed' ? 'manager' : 'circle'" class="dot" /></template>
      <template #title>{{ t.step_no }}. {{ TNR_STEP[t.step] }}</template>
      <template #label>{{ hint(t) }}<span v-if="t.status === 'done' && t.claimer_name && t.note">・{{ t.note }}</span></template>
      <template v-if="c.case_status === 'open'" #value>
        <van-button v-if="t.status === 'open'" size="small" round plain type="primary" :disabled="busy" @click="claim(t)">我來</van-button>
        <template v-else-if="t.status === 'claimed' && t.is_mine">
          <van-button size="small" round plain :disabled="busy" @click="giveUp(t)">放棄</van-button>
          <van-button v-if="t.is_ready" size="small" round type="success" :disabled="busy" @click="done(t)">完成</van-button>
        </template>
      </template>
    </van-cell>
    <van-cell class="foot">
      <template #title>
        <van-tag :type="CASE[c.case_status][1]">{{ CASE[c.case_status][0] }}</van-tag>
        <span class="by">{{ c.opener_name || '照顧者' }} 發起<span v-if="c.case_note">・{{ c.case_note }}</span></span>
      </template>
      <template v-if="c.case_status === 'open' && c.can_manage" #value><a class="cancel" @click="cancel">取消接力</a></template>
    </van-cell>
  </van-cell-group>
</template>

<style scoped>
.dot { font-size: 18px; margin-right: 8px; color: #c8c9cc; align-self: center; }
.done .dot { color: #2f9e6b; }
.ready :deep(.van-cell__title) { font-weight: 600; }
.tnr-steps :deep(.van-cell__value) { flex: none; display: flex; gap: 6px; align-items: center; }
.tnr-steps :deep(.van-cell__title) { flex: 1; min-width: 0; }
.by { margin-left: 8px; color: #888; font-size: 12px; }
.cancel { color: #ee0a24; font-size: 13px; }
</style>
