# PawLink 程式碼脈絡速查

給之後接手的人（包括 Claude）用：先看這份，不用每次重新翻整個 repo。
內容以 2026-11-16 的 main（PR #23 合併後）為準；改了架構請順手更新這份。

細節的權威來源：
- 權限：[`docs/permission-matrix.md`](permission-matrix.md)
- RPC 參數與回傳：[`docs/rpc-api.md`](rpc-api.md)
- 設計決定 D1～D60：[`docs/decisions.md`](decisions.md)
- 各階段驗收紀錄與已知限制：[`docs/acceptance.md`](acceptance.md)

## 1. 技術與部署

| 項目 | 內容 |
| --- | --- |
| 前端 | Vue 3 + Vite 8 + Vant 4（`unplugin-vue-components` 按需載入）+ vue-router 5 |
| 地圖 | Leaflet 1.9 + OSM 圖磚、`leaflet.markercluster`；熱區繪製用 Geoman（獨立 chunk，只有後台載） |
| 後端 | Supabase：Postgres + PostGIS、Auth（Email＋密碼）、Storage、Realtime、pg_cron |
| 部署 | Vercel，push 到 main 自動部署。正式站 https://paw-link-zeta.vercel.app/ |
| Supabase 專案 | ID `kelrouzoxxogvmvrvhlr`（首爾區），URL `https://kelrouzoxxogvmvrvhlr.supabase.co` |
| PWA | `vite-plugin-pwa`（設定在 `vite.config.js`），`registerType: autoUpdate` |
| CI | `.github/workflows/build.yml`：PR 與 main 跑 `npm ci && npm run build && npm audit --audit-level=high` |
| 喚醒 | `.github/workflows/keepalive.yml`：每天台灣 09:17 呼叫 `get_map_spots`，避免免費專案 7 天沒動被暫停 |

環境變數（`.env.example`）：`VITE_SUPABASE_URL`、`VITE_SUPABASE_ANON_KEY`（publishable key）、選填 `VITE_TURNSTILE_SITE_KEY`。
沒設 Supabase 時 `src/lib/supabase.js` 匯出 `null`，地圖改用 `mockSpots.js` 假資料。`service_role` 絕不進 repo 或前端。

## 2. 目錄

```
src/
  main.js            掛 router、Vant 繁中語系、全域錯誤 toast、離線佇列與更新檢查
  App.vue            外殼（router-view + 底部分頁列）
  style.css          設計變數 --pl-*（綠=剛餵/已結紮、琥珀=一陣子前/進行中、紅=久未餵/警示）與 Vant 覆寫
  router/index.js    所有路由；meta.auth 要登入、meta.admin 要管理員、meta.tab 對應底部分頁
  views/             頁面（見第 3 節）
  components/        AppTabbar、SpotPanel、ConservationAlert、TnrSteps、TurnstileWidget、footprintIcon.js
  lib/
    supabase.js      建立 client（沒設定就是 null）
    api.js           幾乎所有資料存取都在這裡（RPC 與直接查表），也放各種狀態常數與中文標籤
    auth.js          auth 狀態（user、profile）、isAdmin()、登入註冊登出
    spots.js         get_map_spots + localStorage 快取（離線顯示上次載入的點，最多 600 個，登出清掉）
    offlineQueue.js  離線餵食紀錄（IndexedDB、建立時產生 UUID、恢復連線自動補傳、永久性錯誤才丟）
    badges.js        底部分頁列與「我的」頁共用的待辦數字
    leaflet.js       設 window.L、baseLayer()（OSM 圖磚、CORS、失敗重試兩次）、loadCluster()、loadGeoman()
    update.js        SW 註冊與新版接手、分頁程式載入失敗時重整（isChunkError / reloadForUpdate）
    image.js         照片壓縮（最長邊 1280、webp、去 EXIF/GPS）
    conservationContent.js  宣導頁的物種、文案、外部連結（組員可直接改）
    mockSpots.js     沒接 Supabase 時的假資料
supabase/
  migrations/        資料庫變更唯一來源（見第 5 節）
  tests/             本機 SQL 測試（見第 7 節）
scripts/acceptance.mjs  對正式 Supabase 的四角色驗收（只用 anon key）
docs/                權限矩陣、RPC、決策、驗收、Turnstile 設定、本檔
vercel.json          SPA rewrite 到 index.html + 安全標頭
```

## 3. 路由、頁面與功能對照

底部分頁（`AppTabbar.vue`，`meta.tab`）：地圖 map／保育 conservation／交流 community／通知 inbox／我的 me。
輪值、TNR 接力、領養、後台、安裝教學、登出的入口都在「我的」頁。

| 路由 | 頁面 | 階段 | 功能 | 登入 |
| --- | --- | --- | --- | --- |
| `/` | MapView + SpotPanel | 1 | 地圖、腳印顏色、叢集、定位、長按/＋建點、點面板（記錄餵食、2 小時重複提醒、清理回報、動物清單、加入照顧）、Realtime | 否（訪客位置模糊） |
| `/login` | LoginView | 1 | Email＋密碼登入註冊，`?redirect=` 回原頁 | — |
| `/spots/new` | SpotNewView | 1/2 | 建點：30 公尺內舊點提示加入、保育熱區三層警示（ConservationAlert） | 是 |
| `/spots/:id/animals/new` | AnimalNewView | 1 | 動物建檔（`create_animal`）、照片上傳 | 是 |
| `/animals/:id` | AnimalView + TnrSteps | 1/5 | 身分檔、照片、結紮五階段、回報目擊、發起 TNR 接力、我領養了牠 | 否 |
| `/conservation` | ConservationView | 2 | 保育宣導（內容在 conservationContent.js） | 否 |
| `/admin` | AdminView | 2/3/5 | 後台分頁：使用者角色、保育熱區、餵食點管理、檢舉審核、哨兵手動執行 | 管理員 |
| `/admin/zones/:id` | ZoneEditView | 2 | Geoman 畫熱區多邊形（`new` 為新增） | 管理員 |
| `/spots/:id/report` | ReportView + TurnstileWidget | 3 | 居民匿名干擾通報（頻率限制、選配 Turnstile） | 否 |
| `/spots/:id/progress` | SpotProgressView | 3 | 通報公開進度（只顯示類別、狀態、照顧者回覆） | 否 |
| `/reports` | InboxView | 3/5 | 照顧者收件匣：居民通報＋動物提醒（哨兵） | 是 |
| `/community`、`/community/:id` | CommunityView、PostView | 3 | 交流空間：發文、留言、檢舉（3 人檢舉自動隱藏） | 是 |
| `/install` | InstallView | 4 | 加入主畫面教學（Android 用 `window.__pwaPrompt`） | 否 |
| `/shifts` | ShiftsView | 5-2 | 輪值表：登記、求代班、我來代班、完成 | 是 |
| `/tnr` | TnrView | 5-3 | TNR 接力看板：認領／放棄／完成四步 | 是 |
| `/adoptions` | AdoptionView | 5-4 | 領養確認、第 7/30/90 天關懷問卷 | 是 |
| `/me` | MeView | — | 我的：各功能入口、待辦數字、登出、最下面版本字樣（commit 前七碼＋建置時間） | 否 |

路由守衛只是介面擋門，真正權限一律在 RLS／RPC。

## 4. 資料庫

### 資料表（public 19 張，全部開 RLS；另有 private 兩張）

| 表 | migration | 用途 |
| --- | --- | --- |
| profiles | 0001 | 使用者暱稱、`role`（user/admin）；註冊時 trigger `handle_new_user` 建立 |
| feeding_spots | 0002 | 餵食點（geography 點、`status` active/inactive，停用取代刪除） |
| spot_caretakers | 0002 | 照顧者（以點為單位，owner/caretaker；建點者自動 owner） |
| animals | 0002 | 動物身分檔（`tnr_stage` 1～5、`is_sterilized` 由階段 ≥3 推導、`tnr_stage_changed_at` 一天限改一次） |
| spot_animals | 0002 | 動物出沒點（多對多） |
| feeding_logs | 0002 | 餵食紀錄（client UUID 去重、清理狀態；不能直接 UPDATE） |
| animal_photos | 0002 | 動物照片（每隻上限由 0014 trigger 限制） |
| conservation_zones | 0006 | 保育熱區多邊形（`is_demo` 示意；預設 5 處由 000810 種子寫入） |
| neighbor_reports | 0007 | 居民匿名通報 |
| posts、comments、content_flags | 0007 | 交流空間與檢舉 |
| sightings、animal_alerts | 0009 | 目擊回報、哨兵提醒（失蹤／健康） |
| feeding_shifts | 0010 | 輪值班表（早/晚） |
| tnr_cases、tnr_tasks | 0011 | TNR 接力案件與四步（trap/vet/recovery/release） |
| adoptions、adoption_followups | 0012 | 領養登記與關懷問卷 |
| private.app_secrets | 0007 | Turnstile secret、IP 雜湊鹽；前端讀不到 |
| private.sentinel_runs | 0009 | 哨兵執行紀錄 |

Storage：bucket `animal-photos`（公開讀，路徑以動物 id 開頭，寫入要能編輯該動物）。
Realtime：`feeding_logs` 加在 `supabase_realtime` publication（前端 `subscribeFeeding`，有節流）。
pg_cron：`pawlink-sentinel-daily`，UTC 20:00（台灣 04:00）跑 `private.run_missing_sentinel()`，正式庫已啟用。

### RPC（前端呼叫的，都包在 `src/lib/api.js`）

- 階段 1：`get_map_spots`（spots.js）、`get_spot_summary`、`find_nearby_spots`、`create_feeding_spot`、`check_recent_feeding`、`record_feeding`、`report_cleanup`、`get_my_pending_cleanups`、`create_animal`（0014 加入）
- 階段 2：`get_conservation_zones`、`check_conservation_alert`、`check_spot_conservation_alert`、`save_conservation_zone`、`admin_list_users`、`set_user_role`、`admin_list_spots`、`admin_set_spot_owner`
- 階段 3：`submit_neighbor_report`、`report_captcha_required`、`get_spot_public_reports`、`get_my_report_inbox`、`handle_neighbor_report`、`admin_list_flags`、`moderate_content`
- 哨兵：`report_sighting`、`get_animal_sightings`、`get_my_animal_alerts`、`resolve_animal_alert`、`admin_run_sentinel`
- 輪值：`get_my_shifts`、`get_my_shift_spots`、`create_shift`、`cancel_shift`、`request_shift_cover`、`claim_shift`（資料列鎖，同時認領只有一人成功）、`complete_shift`
- TNR：`get_tnr_tasks`、`open_tnr_case`、`cancel_tnr_case`、`claim_tnr_task`、`unclaim_tnr_task`、`complete_tnr_task`
- 領養：`get_adoptions`、`register_adoption`、`confirm_adoption`、`cancel_adoption`、`submit_adoption_followup`

仍直接查表的：`feeding_spots`（停用/啟用）、`spot_caretakers`（加入照顧）、`animals`（讀、改階段）、`spot_animals`、`animal_photos`、`conservation_zones`（後台列表、刪除、狀態）、`posts`、`comments`、`content_flags`、`profiles`（auth.js）。

### RLS 重點

- 權限判斷函式都在 `private` schema：`is_admin()`、`is_spot_owner()`、`is_spot_caretaker()`、`can_edit_animal()`（建檔者、出沒點照顧者、管理員）。
- 訪客（anon）讀點只能透過 RPC，位置吸附到 TWD97 100 公尺網格（`private.fuzz_point`），看不到描述與餵食者。
- 角色只能用 `set_user_role()` 改，至少保留一位管理員；自己不能升權。
- 0013 起六張表 INSERT 改欄位層級授權，`created_at` 等系統欄位只能用預設值；`feeding_logs` 不能直接 UPDATE。
- 結紮階段：authenticated 角色每隻每天（台灣時間）手動改一次，管理員與 TNR 接力不受限；接力同一人一天只能回報同一案一步。
- 2026-11-14 審查時正式庫 anon 可執行的函式只有預期的 7 支；新增 RPC 記得 `revoke ... from anon` 再視需要 grant。

## 5. Migration 清單與正式庫狀態

| 編號 | 檔案 | 內容 | 正式庫 |
| --- | --- | --- | --- |
| 0001 | 20261111000100_extensions_and_profiles | PostGIS、profiles、private schema | ✅ |
| 0002 | 20261111000200_core_tables | 階段 1 核心六表＋animal_photos | ✅ |
| 0003 | 20261111000300_rls_policies | 階段 1 RLS 與權限函式 | ✅ |
| 0004 | 20261111000400_rpc_functions | 階段 1 RPC | ✅ |
| 0005 | 20261111000500_storage_and_realtime | Storage bucket、Realtime | ✅ |
| 0006 | 20261111000600_conservation_zones | 保育熱區、後台 RPC | ✅ |
| 0007 | 20261111000700_community | 通報、交流、檢舉、Turnstile、頻率限制 | ✅ |
| 0008 | 20261111000810_seed_conservation_zones | 預設 5 處示意熱區 | ✅ |
| 0009 | 20261111000900_sentinel | 哨兵＋pg_cron | ✅ |
| 0010 | 20261111001000_shifts | 輪值代班 | ✅ |
| 0011 | 20261111001100_tnr_relay | TNR 接力 | ✅ |
| 0012 | 20261111001200_adoption | 領養陪伴 | ✅ |
| 0013 | 20261114000100_review_fixes | 審查修補（結紮一天一次、欄位層級 INSERT 等） | ✅ |
| 0014 | 20261114000200_low_severity_fixes | 低風險修補（`create_animal`、照片上限等） | ✅ |

2026-11-16 以 SQL 逐一確認物件都存在。注意：**`list_migrations` 只列得到 2 筆**（其餘是在 SQL Editor 手動貼的，沒寫進 `supabase_migrations` 紀錄表），判斷有沒有套用要直接查物件，例如：

```sql
select to_regclass('public.adoptions') is not null,
       exists(select 1 from information_schema.columns where table_name='animals' and column_name='tnr_stage_changed_at'),
       exists(select 1 from pg_proc where proname='create_animal');
```

新 migration：檔名用 `YYYYMMDDHHMMSS_name.sql` 放 `supabase/migrations/`，可重複執行（`create or replace`、`if not exists`），本機測試過再上正式庫。

## 6. 正式庫操作規則

- SQL 操作由 Claude 用 Supabase 連接器執行，執行前先查哪些已套用。
- **連接器的 `apply_migration`／含 drop、delete 的 SQL 會在 Supabase 端跳確認視窗，60 秒逾時**，即使使用者在討論串同意也一樣。遇到就把 SQL 給使用者，請他自己貼 SQL Editor。唯讀查詢用 `execute_sql` 沒問題。
- Auth 已關閉 Confirm email（驗收腳本靠註冊後直接拿 session）。
- 管理員只能由現有管理員在後台設定，或在 SQL Editor 改 `profiles.role`。

## 7. 測試怎麼跑

| 種類 | 指令 | 備註 |
| --- | --- | --- |
| 建置 | `npm ci && npm run build` | 與 CI 相同 |
| 本機 SQL 測試 | `supabase/tests/run_tests.sh` | 需 PostgreSQL 15+、PostGIS 3、dblink。雲端容器：`apt-get install -y postgresql-16-postgis-3 && pg_ctlcluster 16 main start`，再 `su postgres -c 'bash supabase/tests/run_tests.sh'`。2026-11-15 共 480 項全過 |
| 正式庫四角色驗收 | `SUPABASE_URL=... SUPABASE_ANON_KEY=... QA_PASSWORD=... npm run test:acceptance` | QA 帳號 `pawlink-qa-{owner,user,care,admin}@<QA_EMAIL_DOMAIN>`；設定在專案檔案 `qa/qa.env`（不進 repo）。測試資料放外海 (25.300,122.200)，結束刪除。會清掉 QA 帳號建的動物與餵食紀錄 |
| 介面截圖 | Playwright（雲端已預裝） | 見第 8 節的 OSM 與 SW 注意事項 |

組員手動測試清單：專案檔案 `qa/PawLink組員測試清單.xlsx`（87 案例），Bug 一律開 GitHub issue，標題「[案例編號] 一句話」。

## 8. 常見坑

- **OSM 圖磚**：雲端容器連不到 `tile.openstreetmap.org`，Playwright 要攔截並回替代圖；攔 SW 發出的請求要設 `PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS=1`。真實底圖觀感只能請使用者在手機看。
- **圖磚快取**：SW 快取名是 `osm-tiles-v2`。改圖磚載入方式（例如 CORS 設定）一定要換快取名稱，否則手機會拿舊的不透明回應，看過的區域反而載不出來。
- **iPhone 輸入框**：字級小於 16px 會在聚焦時放大整頁不縮回，輸入框一律 16px。
- **Vant 樣式**：按需載入，覆寫用 `--van-*` 變數或選擇器前加 `body`；Toast 曾被 Popup 白底蓋成白底白字，已用 `body .van-toast` 固定。不要寫死 Vant 預設藍 `#1989fa`，用 `--pl-*`。
- **新版部署後舊頁面**：Vercel 對不存在的 chunk 回 index.html，靠 `update.js` 的 `router.onError` 重整。使用者說看到舊畫面時先請他完全關掉 App 再開。
- **Vercel 偶爾沒建正式部署**（#22 發生過）：合併後要確認正式站，看「我的」頁最下面的版本字樣或 `/sw.js`。
- **Leaflet 外掛**：markercluster、Geoman 依賴全域 `L`，一律從 `lib/leaflet.js` 動態載入，不要直接 import。
- **時間**：資料庫是 UTC，所有「今天」用台灣時間（`private.today_tw()`）；前端選日期也用台灣時間。
- **頻率限制以 IP 計**：同一個 Wi-Fi 共用額度，測通報用 4G。
- **測試資料**：組員測試資料命名「測試-名字-」開頭，Demo 前統一清掉（含 QA 帳號資料）。
- **data-test 選擇器**：feed、feed-submit、stat-feed、stat-ster、ster-card、next-stage、tab-*、logout、me-login。
