import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import Components from 'unplugin-vue-components/vite'
import { VantResolver } from 'unplugin-vue-components/resolvers'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    vue(),
    Components({ resolvers: [VantResolver()] }),
    // PWA（NFR-2）：可加入主畫面；離線時仍能開啟 App 外殼，餵食紀錄先存在手機（見 src/lib/offlineQueue.js）
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.png', 'apple-touch-icon.png'],
      manifest: {
        name: '流浪動物資訊共享與保育警示平台',
        short_name: 'PawLink',
        description: '餵食點地圖、餵食與清理紀錄、結紮進度與保育警示',
        lang: 'zh-Hant',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        orientation: 'portrait',
        theme_color: '#2f9e6b',
        background_color: '#ffffff',
        icons: [
          { src: 'pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'pwa-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'pwa-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,png,svg,woff2}'],
        navigateFallback: '/index.html',
        cleanupOutdatedCaches: true,
        runtimeCaching: [
          {
            // 看過的地圖圖磚留在手機，離線時還看得到附近的地圖
            urlPattern: /^https:\/\/tile\.openstreetmap\.org\/.*/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'osm-tiles',
              expiration: { maxEntries: 400, maxAgeSeconds: 7 * 24 * 3600 },
              // 圖磚以 CORS 載入（tileLayer 的 crossOrigin），只快取看得到狀態的回應；
              // 不透明回應在 Chrome 每筆會以數 MB 計入配額，會擠壓離線紀錄的空間
              cacheableResponse: { statuses: [200] },
            },
          },
          {
            // 動物照片
            urlPattern: /\/storage\/v1\/object\/public\/animal-photos\/.*/i,
            handler: 'StaleWhileRevalidate',
            options: { cacheName: 'animal-photos', expiration: { maxEntries: 120, maxAgeSeconds: 30 * 24 * 3600 } },
          },
          // Supabase 的 API 不經 service worker 快取：權限相關的資料不留在共用快取裡
        ],
      },
    }),
  ],
})
