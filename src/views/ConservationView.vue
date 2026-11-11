<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { SPECIES, WHY, DOS, LINKS } from '../lib/conservationContent'
import { getZones } from '../lib/api'

const router = useRouter()
const zones = ref([])
onMounted(async () => { zones.value = await getZones() })
const back = () => (window.history.length > 1 ? router.back() : router.replace('/'))
</script>

<template>
  <van-nav-bar title="保育宣導" left-arrow @click-left="back" />
  <div class="wrap">
    <section class="hero">
      <h2>餵食之前，先看看這裡住著誰</h2>
      <p>照顧流浪動物和保護野生動物可以同時做到。關鍵是餵食的地點，以及餵完有沒有清理。</p>
    </section>

    <h3>為什麼餵食點要避開保育熱區</h3>
    <ul class="why"><li v-for="w in WHY" :key="w">{{ w }}</li></ul>

    <div class="levels">
      <div class="lv red"><b>紅色警示</b><span>保育熱區範圍內。建議不要設餵食點。</span></div>
      <div class="lv yellow"><b>黃色警示</b><span>熱區外 200 公尺內。餵完就清理，優先結紮。</span></div>
      <div class="lv green"><b>正常</b><span>距離熱區超過 200 公尺。</span></div>
    </div>

    <h3>認識牠們</h3>
    <div v-for="s in SPECIES" :key="s.key" class="card">
      <div class="head"><span class="emoji">{{ s.emoji }}</span>
        <div><b class="name">{{ s.name }}</b><i class="sci">{{ s.sci }}</i><div><van-tag plain type="danger">{{ s.status }}</van-tag></div></div>
      </div>
      <ul><li v-for="f in s.facts" :key="f">{{ f }}</li></ul>
      <a v-if="s.url" class="more" :href="s.url" target="_blank" rel="noopener noreferrer">保育等級與資料來源 ↗</a>
    </div>

    <h3>餵食者可以做的四件事</h3>
    <van-cell-group inset class="group">
      <van-cell v-for="(d, i) in DOS" :key="d.title" :title="`${i + 1}. ${d.title}`" :label="d.text" />
    </van-cell-group>

    <template v-if="zones.length">
      <h3>平台目前標示的保育熱區</h3>
      <van-cell-group inset class="group">
        <van-cell v-for="z in zones" :key="z.id" :title="z.name" :label="z.description || ''" is-link
                  @click="router.push({ name: 'map', query: { zone: z.id } })">
          <template #value>
            <van-tag v-if="z.species" type="danger" plain>{{ z.species }}</van-tag>
            <van-tag v-if="z.is_demo" plain style="margin-left:4px">示意</van-tag>
          </template>
        </van-cell>
      </van-cell-group>
      <p class="note">點一下熱區可以在地圖上查看。標為「示意」的範圍是依公開資料以鄉鎮界線或手繪劃定，不是官方公告的棲地圖，也不代表動物的確切位置。</p>
    </template>

    <h3>支持保育與延伸閱讀</h3>
    <van-cell-group inset class="group">
      <!-- 用真正的 <a> 開新分頁：van-cell 的 url 會在同一頁跳走，裝成 App 時回不來 -->
      <a v-for="l in LINKS" :key="l.url" :href="l.url" target="_blank" rel="noopener noreferrer" class="ext">
        <van-cell :title="l.title" :label="l.desc" is-link>
          <template v-if="l.donate" #value><van-tag type="success">捐款支持</van-tag></template>
        </van-cell>
      </a>
    </van-cell-group>
    <p class="note">以上為外部網站連結。捐款由各單位自行收受與開立收據，本平台不經手任何款項。</p>
  </div>
</template>

<style scoped>
.wrap { padding: 0 0 40px; max-width: 720px; margin: 0 auto; }
.hero { background: #2f9e6b; color: #fff; padding: 20px 20px 18px; }
.hero h2 { margin: 0 0 8px; font-size: 20px; }
.hero p { margin: 0; line-height: 1.6; opacity: .95; }
h3 { margin: 22px 16px 10px; font-size: 16px; }
.why li, .card li { list-style: disc; }
.why, .card ul { list-style: disc; margin: 0; padding: 0 16px 0 36px; line-height: 1.7; color: #333; font-size: 14px; }
.levels { display: grid; gap: 8px; margin: 14px 16px 0; }
.lv { border-radius: 8px; padding: 10px 12px; font-size: 14px; display: flex; gap: 10px; align-items: baseline; }
.lv b { flex: none; }
.lv.red { background: #fdecea; color: #b42318; }
.lv.yellow { background: #fff7d6; color: #8a5a00; }
.lv.green { background: #e8f6ef; color: #1f7a50; }
.card { background: #fff; margin: 0 16px 12px; border-radius: 10px; padding: 14px 0; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
.card .head { display: flex; gap: 12px; align-items: center; padding: 0 16px 8px; }
.emoji { font-size: 38px; }
.name { font-size: 17px; margin-right: 8px; }
.sci { color: #888; font-size: 13px; }
.group { margin: 0 16px; }
.more { display: inline-block; margin: 6px 16px 0; font-size: 13px; color: #1f7a50; }
.ext { display: block; color: inherit; }
.note { margin: 8px 20px 0; color: #999; font-size: 12px; line-height: 1.6; }
</style>
