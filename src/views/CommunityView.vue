<script setup>
// 餵食民眾交流空間（FR-2.3）：登入者可發文、留言、檢舉
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'
import { listPosts, createPost } from '../lib/api'

const router = useRouter()
const posts = ref([]), loading = ref(true)
const show = ref(false), title = ref(''), body = ref(''), busy = ref(false)

async function load() {
  loading.value = true
  try { posts.value = await listPosts() } catch (e) { showToast(e.message) } finally { loading.value = false }
}
onMounted(load)
async function submit() {
  busy.value = true
  try {
    const id = await createPost(title.value.trim(), body.value.trim())
    show.value = false; title.value = ''; body.value = ''
    router.push({ name: 'post', params: { id } })
  } catch (e) { showToast(e.message) } finally { busy.value = false }
}
const when = (t) => new Date(t).toLocaleString('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })
const filled = (v) => v.trim().length > 0
</script>

<template>
  <van-nav-bar title="交流空間" left-arrow right-text="發文" @click-left="router.push('/')" @click-right="show = true" />
  <van-empty v-if="!loading && !posts.length" description="還沒有貼文，來發第一篇吧" />
  <van-cell-group v-else inset style="margin-top:12px">
    <van-cell v-for="p in posts" :key="p.id" is-link @click="router.push({ name: 'post', params: { id: p.id } })">
      <template #title>
        <b>{{ p.title }}</b>
        <van-tag v-if="p.status === 'hidden'" type="warning" style="margin-left:6px">已被隱藏</van-tag>
      </template>
      <template #label>
        <div class="excerpt">{{ p.body }}</div>
        <div>{{ p.author?.display_name || '已離開的使用者' }}・{{ when(p.created_at) }}・{{ p.comments?.[0]?.count ?? 0 }} 則留言</div>
      </template>
    </van-cell>
  </van-cell-group>
  <p class="tip">請互相尊重，不要張貼他人的個人資料或餵食點的門牌地址。不當內容可以檢舉，由管理員處理。</p>

  <van-popup v-model:show="show" position="bottom" round closeable>
    <van-form style="padding:36px 0 16px" @submit="submit">
      <van-cell-group inset>
        <van-field v-model="title" label="標題" maxlength="80" placeholder="想討論什麼？" :rules="[{ validator: filled, message: '請輸入標題' }]" />
        <van-field v-model="body" label="內容" type="textarea" rows="5" maxlength="2000" show-word-limit :rules="[{ validator: filled, message: '請輸入內容' }]" />
      </van-cell-group>
      <div style="margin:12px 16px"><van-button round block type="primary" native-type="submit" :loading="busy">發布</van-button></div>
    </van-form>
  </van-popup>
</template>

<style scoped>
.excerpt { color: #555; margin: 4px 0; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.tip { margin: 12px 20px 24px; color: #999; font-size: 12px; line-height: 1.6; }
</style>
