<script setup>
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showConfirmDialog } from 'vant'
import { auth, isAdmin } from '../lib/auth'
import { getPost, listComments, createComment, deletePost, deleteComment, flagContent } from '../lib/api'

const route = useRoute(), router = useRouter()
const post = ref(null), comments = ref([]), missing = ref(false)
const text = ref(''), busy = ref(false)
const flagTarget = ref(null), showFlag = ref(false), reason = ref('')
const REASONS = ['廣告或洗版', '人身攻擊或騷擾', '洩漏個人資料或地址', '不實資訊']

async function load() {
  try {
    post.value = await getPost(route.params.id)
    if (!post.value) { missing.value = true; return }
    comments.value = await listComments(route.params.id)
  } catch (e) { showToast(e.message) }
}
onMounted(load)
const mine = (x) => x.author_id === auth.user?.id || isAdmin()
const when = (t) => new Date(t).toLocaleString('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })

async function send() {
  if (!text.value.trim()) return
  busy.value = true
  try { await createComment(post.value.id, text.value.trim()); text.value = ''; await load() }
  catch (e) { showToast(e.message) } finally { busy.value = false }
}
async function removePost() {
  try { await showConfirmDialog({ title: '刪除貼文', message: '貼文和底下的留言會一起刪除，無法復原。' }) } catch { return }
  try { await deletePost(post.value.id); showToast('已刪除'); router.replace({ name: 'community' }) } catch (e) { showToast(e.message) }
}
async function removeComment(c) {
  try { await showConfirmDialog({ title: '刪除留言', message: '確定刪除這則留言？' }) } catch { return }
  try { await deleteComment(c.id); await load() } catch (e) { showToast(e.message) }
}
function openFlag(target) { flagTarget.value = target; reason.value = REASONS[0]; showFlag.value = true }
async function sendFlag() {
  try { await flagContent(flagTarget.value, reason.value); showFlag.value = false; showToast('已送出檢舉，管理員會處理') }
  catch (e) { showFlag.value = false; showToast(e.message) }
}
</script>

<template>
  <van-nav-bar title="貼文" left-arrow @click-left="router.push({ name: 'community' })" />
  <van-empty v-if="missing" description="找不到這篇貼文，可能已被刪除或隱藏" />
  <div v-else-if="post" class="wrap">
    <van-notice-bar v-if="post.status === 'hidden'" wrapable :scrollable="false" color="#8a5a00" background="#fff7d6">
      這篇貼文因為被檢舉而暫時隱藏，只有你和管理員看得到。
    </van-notice-bar>
    <article>
      <h2>{{ post.title }}</h2>
      <div class="meta">{{ post.author?.display_name || '已離開的使用者' }}・{{ when(post.created_at) }}</div>
      <p class="body">{{ post.body }}</p>
      <div class="ops">
        <a v-if="post.author_id !== auth.user?.id" @click="openFlag({ post_id: post.id })">檢舉</a>
        <a v-if="mine(post)" class="del" @click="removePost">刪除</a>
      </div>
    </article>

    <h4>留言（{{ comments.length }}）</h4>
    <div v-for="c in comments" :key="c.id" class="comment">
      <div class="meta"><b>{{ c.author?.display_name || '已離開的使用者' }}</b>・{{ when(c.created_at) }}
        <van-tag v-if="c.status === 'hidden'" type="warning" style="margin-left:6px">已被隱藏</van-tag></div>
      <p class="body">{{ c.body }}</p>
      <div class="ops">
        <a v-if="c.author_id !== auth.user?.id" @click="openFlag({ comment_id: c.id })">檢舉</a>
        <a v-if="mine(c)" class="del" @click="removeComment(c)">刪除</a>
      </div>
    </div>
    <p v-if="!comments.length" class="none">還沒有留言。</p>

    <div v-if="post.status === 'visible'" class="reply">
      <van-field v-model="text" type="textarea" rows="1" autosize maxlength="500" placeholder="寫下留言" />
      <van-button type="primary" size="small" round :loading="busy" :disabled="!text.trim()" @click="send">送出</van-button>
    </div>
  </div>

  <van-popup v-model:show="showFlag" position="bottom" round closeable>
    <div class="sheet">
      <h4>檢舉原因</h4>
      <van-radio-group v-model="reason">
        <van-radio v-for="r in REASONS" :key="r" :name="r" style="margin:10px 0">{{ r }}</van-radio>
      </van-radio-group>
      <van-button round block type="danger" style="margin-top:16px" @click="sendFlag">送出檢舉</van-button>
    </div>
  </van-popup>
</template>

<style scoped>
.wrap { padding-bottom: 96px; max-width: 720px; margin: 0 auto; }
article { padding: 16px; border-bottom: 8px solid #f5f6f7; }
h2 { margin: 0 0 6px; font-size: 19px; }
h4 { margin: 16px 16px 4px; }
.meta { color: #888; font-size: 12px; }
.body { margin: 10px 0 6px; line-height: 1.7; white-space: pre-wrap; word-break: break-word; color: #222; }
.ops { display: flex; gap: 16px; font-size: 12px; }
.ops a { color: #888; }
.ops a.del { color: #e03e3e; }
.comment { padding: 12px 16px; border-bottom: 1px solid #f0f0f0; }
.none { margin: 12px 16px; color: #999; font-size: 13px; }
.reply { position: fixed; left: 0; right: 0; bottom: 0; background: #fff; border-top: 1px solid #eee; display: flex; align-items: flex-end; gap: 8px; padding: 8px 12px calc(8px + env(safe-area-inset-bottom)); }
.reply .van-field { background: #f5f6f7; border-radius: 16px; padding: 6px 12px; }
.sheet { padding: 20px 20px 24px; }
.sheet h4 { margin: 0 0 8px; }
</style>
