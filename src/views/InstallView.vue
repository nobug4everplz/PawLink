<script setup>
// 加入主畫面教學（NFR-2）。Android／桌面 Chrome 可以直接跳出安裝視窗；iPhone 只能照步驟手動加
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'

const router = useRouter()
const ua = navigator.userAgent
const isIOS = /iphone|ipad|ipod/i.test(ua) || (/macintosh/i.test(ua) && navigator.maxTouchPoints > 1)
const tab = ref(isIOS ? 'ios' : 'android')
const standalone = window.matchMedia('(display-mode: standalone)').matches || !!window.navigator.standalone
const prompt = ref(window.__pwaPrompt || null)
const onPrompt = (e) => { e.preventDefault(); prompt.value = e }
onMounted(() => window.addEventListener('beforeinstallprompt', onPrompt))
onBeforeUnmount(() => window.removeEventListener('beforeinstallprompt', onPrompt))
async function install() {
  prompt.value.prompt()
  const { outcome } = await prompt.value.userChoice
  if (outcome === 'accepted') showToast('已加入主畫面')
  prompt.value = null; window.__pwaPrompt = null
}
const back = () => (window.history.length > 1 ? router.back() : router.replace('/'))
</script>

<template>
  <van-nav-bar title="加入主畫面" left-arrow @click-left="back" />
  <div class="wrap">
    <van-notice-bar v-if="standalone" :scrollable="false" left-icon="passed" color="#1f7a50" background="#e8f6ef">你已經是從主畫面開啟的了。</van-notice-bar>
    <div class="hero">
      <img src="/pwa-192.png" alt="" width="72" height="72" />
      <p>加入主畫面後可以像 App 一樣全螢幕開啟。沒有網路時也能打開，餵食紀錄會先存在手機，恢復連線後自動補傳。</p>
    </div>
    <div v-if="prompt" class="cta"><van-button type="primary" round block icon="down" @click="install">立即安裝</van-button></div>

    <van-tabs v-model:active="tab">
      <van-tab title="iPhone／iPad" name="ios">
        <ol>
          <li>用 <b>Safari</b> 開啟這個網站（其他瀏覽器或 LINE 內建瀏覽器不行）。</li>
          <li>點畫面下方的<b>分享</b>按鈕（方框加向上箭頭）。</li>
          <li>往下滑，選<b>「加入主畫面」</b>。</li>
          <li>按右上角的<b>「加入」</b>。</li>
        </ol>
      </van-tab>
      <van-tab title="Android" name="android">
        <ol>
          <li>用 <b>Chrome</b> 開啟這個網站。</li>
          <li>點右上角的<b>「⋮」</b>選單。</li>
          <li>選<b>「安裝應用程式」</b>或<b>「加到主畫面」</b>。</li>
          <li>按<b>「安裝」</b>。</li>
        </ol>
      </van-tab>
      <van-tab title="電腦" name="desktop">
        <ol>
          <li>用 <b>Chrome</b> 或 <b>Edge</b> 開啟這個網站。</li>
          <li>點網址列右邊的<b>安裝</b>圖示（螢幕加向下箭頭）。</li>
          <li>按<b>「安裝」</b>。</li>
        </ol>
      </van-tab>
    </van-tabs>
    <p class="note">定位功能第一次使用時會詢問權限，請選「允許」。iPhone 從主畫面開啟後要重新登入一次。</p>
  </div>
</template>

<style scoped>
.wrap { max-width: 720px; margin: 0 auto; padding-bottom: 40px; }
.hero { display: flex; gap: 16px; align-items: center; padding: 20px 20px 12px; }
.hero img { border-radius: 16px; flex: none; }
.hero p { margin: 0; color: #444; line-height: 1.7; font-size: 14px; }
.cta { margin: 4px 20px 12px; }
ol { margin: 16px 20px 0; padding-left: 22px; line-height: 2; color: #333; }
ol li { list-style: decimal; }
.note { margin: 16px 20px 0; color: #999; font-size: 12px; line-height: 1.6; }
</style>
