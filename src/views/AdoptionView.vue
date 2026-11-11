<script setup>
// 領養陪伴（FR-5.4）：我領養的、我陪伴的、等我確認的。到期的關懷問卷在這裡填
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { getAdoptions, confirmAdoption, cancelAdoption, submitAdoptionFollowup, ADOPTION_STATUS, ADOPTION_QUESTIONS } from '../lib/api'

const router = useRouter()
const rows = ref([]), loading = ref(true), unavailable = ref(false)
const ROLE = { adopter: '我是領養人', buddy: '我是陪伴者', caretaker: '等我確認' }
async function load() {
  try {
    const r = await getAdoptions()
    unavailable.value = r === null
    rows.value = r || []
  } catch (e) { showToast(e.message) } finally { loading.value = false }
}
onMounted(load)
const due = computed(() => rows.value.filter((r) => r.my_role === 'adopter').reduce((n, r) => n + r.due_count, 0))
const day = (d) => { const [, m, dd] = d.split('-'); return `${+m}/${+dd}` }

async function confirm(r) {
  try { await showConfirmDialog({ title: '確認領養', message: `確認「${r.adopter_name}」領養了「${r.animal_name}」？確認後你會成為陪伴者，看得到之後的關懷問卷。` }) } catch { return }
  try { await confirmAdoption(r.adoption_id); showToast('已確認'); await load() } catch (e) { showToast(e.message) }
}
async function cancel(r) {
  const title = r.status === 'pending' ? (r.my_role === 'adopter' ? '撤回登記' : '退回登記') : '登記退養'
  const message = r.status === 'pending' ? `取消「${r.animal_name}」的領養登記？` : `「${r.animal_name}」不再由領養人照顧了嗎？牠會回到一般狀態，之後的問卷也會停止。`
  try { await showConfirmDialog({ title, message }) } catch { return }
  try { await cancelAdoption(r.adoption_id); showToast('已取消'); await load() } catch (e) { showToast(e.message) }
}

// 填問卷
const form = ref(null), ans = ref({}), note = ref(''), sending = ref(false)
function openForm(r, f) {
  if (r.my_role !== 'adopter' || !f.is_due) return
  form.value = { ...f, animal_name: r.animal_name }
  ans.value = { eating_ok: true, health_ok: true, settled_ok: true }; note.value = ''
}
async function send() {
  sending.value = true
  try {
    const issue = await submitAdoptionFollowup(form.value.id, ans.value, note.value.trim())
    form.value = null
    showToast(issue ? '已送出，陪伴者會看到你的狀況' : '已送出，謝謝你好好照顧牠')
    await load()
  } catch (e) { showToast(e.message) } finally { sending.value = false }
}
const fuLabel = (r, f) => {
  if (f.answered_at) return [f.eating_ok ? null : '進食有狀況', f.health_ok ? null : '健康有狀況', f.settled_ok ? null : '還沒適應', f.note].filter(Boolean).join('・') || '一切都好'
  if (f.is_due) return r.my_role === 'adopter' ? '到期了，點這裡填寫' : '已到期，等領養人填寫'
  return `${day(f.due_on)} 可以填`
}
</script>

<template>
  <van-nav-bar title="領養陪伴" left-arrow @click-left="router.push('/')" />
  <van-empty v-if="unavailable" description="資料庫還沒有套用領養陪伴功能" />
  <van-empty v-else-if="!loading && !rows.length" description="目前沒有跟你有關的領養紀錄">
    <p class="how">領養了平台上的動物嗎？到牠的身分檔按「我領養了牠」，之後第 7、30、90 天會請你回報近況。</p>
  </van-empty>
  <template v-else-if="!loading">
    <p class="tip"><template v-if="due">你有 {{ due }} 份關懷問卷到期了。</template>領養後第 7、30、90 天各有一份問卷，回答有狀況時陪伴者會看到。</p>
    <div v-for="r in rows" :key="r.adoption_id" class="card">
      <div class="head" @click="router.push({ name: 'animal', params: { id: r.animal_id } })">
        <b>{{ r.animal_name }}</b>
        <van-tag :type="ADOPTION_STATUS[r.status][1]">{{ ADOPTION_STATUS[r.status][0] }}</van-tag>
        <van-tag v-if="r.issue_count" type="danger" plain>有狀況</van-tag>
        <span class="role">{{ ROLE[r.my_role] }}</span><van-icon name="arrow" />
      </div>
      <van-cell-group inset>
        <van-cell title="領養人" :value="r.adopter_name" :label="`${day(r.adopted_on)} 領養${r.note ? '・' + r.note : ''}`" />
        <van-cell v-if="r.buddy_name" title="陪伴者" :value="r.buddy_name" />
        <van-cell v-for="f in r.followups" :key="f.id" :title="`第 ${f.day_offset} 天問卷`" :label="fuLabel(r, f)"
                  :clickable="r.my_role === 'adopter' && f.is_due" :is-link="r.my_role === 'adopter' && f.is_due" @click="openForm(r, f)">
          <template #value>
            <van-tag v-if="f.answered_at" :type="f.has_issue ? 'danger' : 'success'" plain>{{ f.has_issue ? '有狀況' : '已填' }}</van-tag>
            <van-tag v-else-if="f.is_due" type="warning">待填</van-tag>
            <span v-else class="later">未到期</span>
          </template>
        </van-cell>
      </van-cell-group>
      <div v-if="r.status !== 'completed'" class="acts">
        <van-button v-if="r.my_role === 'caretaker' && r.status === 'pending'" size="small" round type="primary" @click="confirm(r)">確認領養</van-button>
        <van-button size="small" round plain @click="cancel(r)">{{ r.status === 'pending' ? (r.my_role === 'adopter' ? '撤回登記' : '退回') : '登記退養' }}</van-button>
      </div>
    </div>
  </template>
  <van-popup :show="!!form" position="bottom" round closeable @update:show="(v) => { if (!v) form = null }">
    <div v-if="form" class="sheet">
      <h4>「{{ form.animal_name }}」第 {{ form.day_offset }} 天關懷問卷</h4>
      <van-cell-group>
        <van-cell v-for="[k, q] in ADOPTION_QUESTIONS" :key="k" :title="q" center>
          <template #value><van-switch v-model="ans[k]" size="22px" /></template>
        </van-cell>
      </van-cell-group>
      <van-field v-model="note" type="textarea" rows="2" maxlength="300" show-word-limit class="note" placeholder="補充說明（選填），例：前兩天躲在床底，現在會出來玩了" />
      <van-button block round type="primary" :loading="sending" style="margin-top:14px" @click="send">送出</van-button>
      <p class="tip" style="margin:10px 0 0">開關打開表示「是」。任何一題答「否」，陪伴者會看到並可以聯絡你。</p>
    </div>
  </van-popup>
</template>

<style scoped>
.tip { margin: 12px 20px 4px; color: #888; font-size: 12px; line-height: 1.6; }
.how { color: #999; font-size: 13px; padding: 0 32px; line-height: 1.6; }
.card { margin-top: 14px; }
.head { display: flex; align-items: center; gap: 8px; margin: 0 20px 8px; }
.head .role { color: #888; font-size: 13px; flex: 1; text-align: right; }
.head .van-icon { color: #c8c9cc; }
.later { color: #c8c9cc; font-size: 13px; }
.acts { display: flex; justify-content: flex-end; gap: 8px; margin: 8px 16px 0; }
.sheet { padding: 20px 16px 24px; }
.sheet h4 { margin: 0 32px 10px 0; }
.note { background: #f7f8fa; border-radius: 8px; margin-top: 10px; }
</style>
