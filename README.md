# 流浪動物資訊共享與保育警示平台

Vue 3 + Vite + Vant 4 + Leaflet/OSM + Supabase（PostGIS / Auth / Storage / RLS），部署於 Vercel，PWA。

## 快速開始
```bash
npm install
cp .env.example .env   # 填入 Supabase URL 與 anon key；留空則地圖使用假資料
npm run dev
```
定位與 PWA 需要 HTTPS，手機實測請用 Vercel 預覽網址。

## 目錄
- `src/views` 頁面、`src/components` 元件、`src/lib` Supabase 與資料存取
- `supabase/migrations` 資料庫變更（唯一來源）、`supabase/tests` RLS 測試
- `docs/` 權限矩陣與 RPC 介面（前端以此為準）、`docs/acceptance.md` 驗收紀錄
- `scripts/acceptance.mjs` 對真實 Supabase 的四角色權限驗收（`npm run test:acceptance`）
- `.github/workflows/keepalive.yml` 每天喚醒 Supabase，避免免費專案 7 天沒活動被暫停

## 開發規範
- main 永遠可部署；功能開分支，合併前由另一人看過。
- 每個分支 Vercel 會產生預覽網址，用手機實測後才合併。
- 資料庫變更一律寫成 `supabase/migrations` SQL 檔，不在後台手改。
- 每張表建立時就開 RLS；`service_role` 金鑰不進前端、不進 repo；`.env` 已在 `.gitignore`。
- 必保功能：已餵食／已結紮標記（FR-1.3 / FR-1.4），Demo 放最前。
