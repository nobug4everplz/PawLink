<script setup>
// 管理員後台（FR-4.1）：角色設定、保育熱區、餵食點管理
// 進得來不代表有權限：每個動作都由資料庫的 RLS 與 RPC 再檢查一次
import { ref, watch, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth } from '../lib/auth'
import {
  adminListUsers, setUserRole, adminListSpots, adminSetSpotOwner, setSpotStatus,
  adminListZones, setZoneStatus, deleteZone, adminListFlags, moderateContent,
} from '../lib/api'

const route = useRoute(), router = useRouter()
const tab = ref(route.query.tab || 'users')
watch(tab, (t) => router.replace({ query: { tab: t } }))

const users = ref([]), userQ = ref(''), zones = ref([]), spots = ref([]), spotQ = ref('')
const loading = ref(false)

async function run(fn, okMsg) {
  loading.value = true
  try { await fn(); if (okMsg) showToast(okMsg) } catch (e) { showToast(e.message || String(e)) } finally { loading.value = false }
}
const loadUsers = () => run(async () => { users.value = await adminListUsers(userQ.value) })
const loadZones = () => run(async () => { zones.value = await adminListZones() })
const loadSpots = () => run(async () => { spots.value = await adminListSpots(spotQ.value) })
const flags = ref([])
const loadFlags = () => run(async () => { flags.value = await adminListFlags() })
async function moderate(f, hide) {
  await run(async () => { await moderateContent(f.target_type, f.target_id, hide); await loadFlags() }, hide ? '已隱藏內容' : '已駁回檢舉，內容恢復顯示')
}
onMounted(() => { loadUsers(); loadZones(); loadSpots(); loadFlags() })

// ---------- 使用者 ----------
async function toggleRole(u) {
  const to = u.role === 'admin' ? 'user' : 'admin'
  try {
    await showConfirmDialog({
      title: to === 'admin' ? '設為管理員' : '取消管理員',
      message: to === 'admin'
        ? `「${u.display_name}」將可以進入後台、繪製保育熱區、修改任何餵食點與動物資料。`
        : `「${u.display_name}」將變回一般使用者。`,
    })
  } catch { return }
  await run(async () => { await setUserRole(u.id, to); await loadUsers() }, '已更新角色')
}

// ---------- 保育熱區 ----------
async function toggleZone(z) {
  await run(async () => { await setZoneStatus(z.id, z.status === 'active' ? 'archived' : 'active'); await loadZones() },
    z.status === 'active' ? '已停用，不再顯示也不再警示' : '已重新啟用')
}
async function removeZone(z) {
  try { await showConfirmDialog({ title: '刪除保育熱區', message: `確定刪除「${z.name}」？刪除後無法復原。只是暫時不用的話可以改按「停用」。`, confirmButtonColor: '#e03e3e' }) } catch { return }
  await run(async () => { await deleteZone(z.id); await loadZones() }, '已刪除')
}

// ---------- 餵食點 ----------
const LEVEL = { red: ['保育熱區內', 'danger'], yellow: ['鄰近熱區', 'warning'] }
const act = ref(null), showAct = ref(false)
const showOwner = ref(false), ownerQ = ref(''), ownerList = ref([])
function openSpot(s) { act.value = s; showAct.value = true }
const actions = () => !act.value ? [] : [
  { name: '在地圖上查看', key: 'view', disabled: act.value.status !== 'active' },
  { name: '指派 owner', key: 'owner' },
  act.value.status === 'active' ? { name: '停用這個餵食點', key: 'archive', color: '#e03e3e' } : { name: '重新啟用', key: 'restore' },
]
async function onAction(a) {
  showAct.value = false
  const s = act.value
  if (a.key === 'view') return router.push({ name: 'map', query: { spot: s.id } })
  if (a.key === 'owner') { ownerQ.value = ''; showOwner.value = true; return searchOwner() }
  const to = a.key === 'archive' ? 'archived' : 'active'
  if (to === 'archived') {
    try { await showConfirmDialog({ title: '停用餵食點', message: `「${s.name}」停用後不會出現在地圖上，也不能再記錄餵食。歷史紀錄會保留，之後可以重新啟用。` }) } catch { return }
  }
  await run(async () => { await setSpotStatus(s.id, to); await loadSpots() }, to === 'archived' ? '已停用' : '已重新啟用')
}
const searchOwner = () => run(async () => { ownerList.value = await adminListUsers(ownerQ.value) })
async function pickOwner(u) {
  showOwner.value = false
  await run(async () => { await adminSetSpotOwner(act.value.id, u.id); await loadSpots() }, `已把「${u.display_name}」設為 owner`)
}
const day = (t) => new Date(t).toLocaleDateString('zh-TW')
</script>

<template>
  <van-nav-bar title="管理後台" left-arrow @click-left="router.push('/')" />
  <van-tabs v-model:active="tab" sticky>
    <van-tab title="使用者" name="users">
      <van-search v-model="userQ" placeholder="搜尋暱稱或 Email" @search="loadUsers" @clear="loadUsers" />
      <van-cell-group inset>
        <van-cell v-for="u in users" :key="u.id" :title="u.display_name" :label="`${u.email || '（無 Email）'}・照顧 ${u.spot_count} 個點・${day(u.created_at)} 加入`" center>
          <template #value>
            <van-tag v-if="u.role === 'admin'" type="danger" style="margin-right:8px">管理員</van-tag>
            <van-button size="mini" plain :type="u.role === 'admin' ? 'default' : 'primary'" :disabled="loading" @click="toggleRole(u)">
              {{ u.role === 'admin' ? '取消管理員' : '設為管理員' }}
            </van-button>
          </template>
        </van-cell>
      </van-cell-group>
      <van-empty v-if="!users.length && !loading" description="沒有符合的使用者" />
      <p class="tip">「照顧者」不是在這裡設定的角色：使用者建立餵食點或在餵食點按「成為照顧者」後，就是那個點的照顧者。</p>
    </van-tab>

    <van-tab title="保育熱區" name="zones">
      <div class="bar"><van-button type="primary" round block icon="edit" @click="router.push({ name: 'zone-edit', params: { id: 'new' } })">畫新的保育熱區</van-button></div>
      <van-cell-group inset>
        <van-cell v-for="z in zones" :key="z.id" :label="z.description || ''" center>
          <template #title>
            {{ z.name }}
            <van-tag v-if="z.species" plain type="danger" style="margin-left:4px">{{ z.species }}</van-tag>
            <van-tag v-if="z.is_demo" plain style="margin-left:4px">示意</van-tag>
            <van-tag v-if="z.status !== 'active'" type="default" style="margin-left:4px">已停用</van-tag>
          </template>
          <template #value>
            <van-button v-if="z.status === 'active'" size="mini" plain type="primary" @click="router.push({ name: 'zone-edit', params: { id: z.id } })">編輯</van-button>
            <van-button size="mini" plain :disabled="loading" @click="toggleZone(z)">{{ z.status === 'active' ? '停用' : '啟用' }}</van-button>
            <van-button size="mini" plain type="danger" :disabled="loading" @click="removeZone(z)">刪除</van-button>
          </template>
        </van-cell>
      </van-cell-group>
      <van-empty v-if="!zones.length && !loading" description="還沒有保育熱區，按上面的按鈕開始畫" />
      <p class="tip">熱區範圍內建點會出現紅色警示，範圍外 200 公尺內出現黃色警示。沒有官方圖資時請勾選「示意資料」。</p>
    </van-tab>

    <van-tab title="餵食點" name="spots">
      <van-search v-model="spotQ" placeholder="搜尋餵食點名稱" @search="loadSpots" @clear="loadSpots" />
      <van-cell-group inset>
        <van-cell v-for="s in spots" :key="s.id" is-link center
          :label="`owner：${s.owner_names || '（沒有 owner）'}・照顧者 ${s.caretaker_count} 人・${day(s.created_at)} 建立`" @click="openSpot(s)">
          <template #title>
            {{ s.name }}
            <van-tag v-if="LEVEL[s.alert_level]" :type="LEVEL[s.alert_level][1]" style="margin-left:4px">{{ LEVEL[s.alert_level][0] }}</van-tag>
            <van-tag v-if="s.status !== 'active'" type="default" style="margin-left:4px">已停用</van-tag>
            <van-tag v-if="!s.owner_names" plain type="warning" style="margin-left:4px">缺 owner</van-tag>
          </template>
        </van-cell>
      </van-cell-group>
      <van-empty v-if="!spots.length && !loading" description="沒有符合的餵食點" />
    </van-tab>
    <van-tab title="檢舉" name="flags" :badge="flags.length || ''">
      <van-cell-group inset style="margin-top:12px">
        <van-cell v-for="f in flags" :key="f.target_id" class="flag">
          <template #title>
            <van-tag plain>{{ f.target_type === 'post' ? '貼文' : '留言' }}</van-tag>
            <b style="margin-left:6px">{{ f.title }}</b>
            <van-tag v-if="f.content_status === 'hidden'" type="warning" style="margin-left:6px">已自動隱藏</van-tag>
          </template>
          <template #label>
            <div class="excerpt">{{ f.excerpt }}</div>
            <div>作者：{{ f.author_name || '已離開的使用者' }}・{{ f.flag_count }} 人檢舉：{{ f.reasons }}</div>
            <div class="fbtns">
              <van-button size="small" type="danger" :disabled="loading" @click="moderate(f, true)">隱藏內容</van-button>
              <van-button size="small" plain :disabled="loading" @click="moderate(f, false)">駁回檢舉</van-button>
              <van-button size="small" plain type="primary" @click="router.push({ name: 'post', params: { id: f.post_id } })">查看</van-button>
            </div>
          </template>
        </van-cell>
      </van-cell-group>
      <van-empty v-if="!flags.length && !loading" description="沒有待處理的檢舉" />
      <p class="tip">同一則內容被 3 個人檢舉會先自動隱藏。「隱藏內容」會讓它只剩作者與管理員看得到；「駁回檢舉」會恢復顯示。</p>
    </van-tab>
  </van-tabs>

  <van-action-sheet v-model:show="showAct" :title="act?.name" :actions="actions()" cancel-text="取消" @select="onAction" />
  <van-popup v-model:show="showOwner" position="bottom" round closeable style="height:70%">
    <h4 class="ph">指派「{{ act?.name }}」的 owner</h4>
    <van-search v-model="ownerQ" placeholder="搜尋暱稱或 Email" @search="searchOwner" @clear="searchOwner" />
    <van-cell-group>
      <van-cell v-for="u in ownerList" :key="u.id" :title="u.display_name" :label="u.email" is-link @click="pickOwner(u)" />
    </van-cell-group>
  </van-popup>
  <p v-if="!auth.user" class="tip">請先登入。</p>
</template>

<style scoped>
.bar { margin: 12px 16px; }
.tip { margin: 12px 20px 24px; color: #999; font-size: 12px; line-height: 1.6; }
.ph { margin: 16px 16px 4px; }
.excerpt { color: #333; margin: 6px 0; white-space: pre-wrap; }
.fbtns { display: flex; gap: 8px; margin-top: 8px; }
:deep(.van-cell__value) { flex: none; display: flex; gap: 4px; align-items: center; }
:deep(.van-cell__title) { flex: 1; min-width: 0; }
</style>
