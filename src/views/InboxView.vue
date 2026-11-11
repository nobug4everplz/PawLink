<script setup>
// 照顧者的通報收件匣（FR-2.2 站內通知）：只列出自己照顧的餵食點收到的通報
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getReportInbox, handleReport, REPORT_CATEGORY, REPORT_STATUS } from '../lib/api'

const router = useRouter()
const list = ref([]), loading = ref(true), busy = ref(false)
const cur = ref(null), show = ref(false), response = ref('')

async function load() {
  loading.value = true
  try { list.value = await getReportInbox() } catch (e) { showToast(e.message) } finally { loading.value = false }
}
onMounted(load)
const pending = computed(() => list.value.filter((r) => r.status !== 'resolved'))
const resolved = computed(() => list.value.filter((r) => r.status === 'resolved'))
function open(r) { cur.value = r; response.value = r.response || ''; show.value = true }
async function save(status) {
  busy.value = true
  try {
    await handleReport(cur.value.id, status, response.value.trim())
    show.value = false
    showToast(status === 'resolved' ? '已標記為已處理' : '已標記為處理中')
    await load()
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
const when = (t) => new Date(t).toLocaleString('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })
</script>

<template>
  <van-nav-bar title="居民通報" left-arrow @click-left="router.push('/')" />
  <van-empty v-if="!loading && !list.length" description="你照顧的餵食點目前沒有收到通報" />
  <template v-for="group in [{ title: '待處理', items: pending }, { title: '已處理', items: resolved }]" :key="group.title">
    <template v-if="group.items.length">
      <h4 class="sec">{{ group.title }}（{{ group.items.length }}）</h4>
      <van-cell-group inset>
        <van-cell v-for="r in group.items" :key="r.id" is-link @click="open(r)">
          <template #title>
            <van-tag :type="REPORT_STATUS[r.status][1]">{{ REPORT_STATUS[r.status][0] }}</van-tag>
            <b class="cat">{{ REPORT_CATEGORY[r.category] }}</b><span class="spot">{{ r.spot_name }}</span>
          </template>
          <template #label><div class="desc">{{ r.description }}</div><div>{{ when(r.created_at) }}</div></template>
        </van-cell>
      </van-cell-group>
    </template>
  </template>
  <p v-if="list.length" class="tip">通報是匿名的，內容只有該餵食點的照顧者與管理員看得到。你的回覆會公開顯示在餵食點的進度頁。</p>

  <van-popup v-model:show="show" position="bottom" round closeable>
    <div v-if="cur" class="sheet">
      <h4>{{ REPORT_CATEGORY[cur.category] }}・{{ cur.spot_name }}</h4>
      <p class="full">{{ cur.description }}</p>
      <van-field v-model="response" type="textarea" rows="3" maxlength="300" show-word-limit class="resp"
        placeholder="公開回覆（選填），例：已清理，之後改用有蓋餵食盒。請不要寫個人資料。" />
      <div class="btns">
        <van-button round plain type="warning" :loading="busy" @click="save('acknowledged')">處理中</van-button>
        <van-button round type="success" :loading="busy" @click="save('resolved')">已處理</van-button>
      </div>
      <van-button v-if="cur.status !== 'open'" size="small" plain block style="margin-top:10px" :disabled="busy" @click="save('open')">改回待處理</van-button>
    </div>
  </van-popup>
</template>

<style scoped>
.sec { margin: 16px 16px 8px; color: #555; }
.cat { margin: 0 8px; }
.spot { color: #888; font-size: 13px; }
.desc { color: #333; font-size: 14px; margin: 4px 0; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.tip { margin: 12px 20px 24px; color: #999; font-size: 12px; line-height: 1.6; }
.sheet { padding: 20px 16px 24px; }
.sheet h4 { margin: 0 32px 8px 0; }
.full { color: #333; line-height: 1.7; white-space: pre-wrap; margin: 0 0 12px; }
.resp { background: #f7f8fa; border-radius: 8px; }
.btns { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 14px; }
</style>
