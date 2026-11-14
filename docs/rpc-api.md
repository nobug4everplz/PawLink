# 前端資料介面（第一～三階段、哨兵、輪值、TNR 接力、領養陪伴）

前端用 `supabase-js`。地圖與統計一律走 RPC；其他 CRUD 直接用 `supabase.from('表')`，權限由 RLS 把關。

## 常數

| 規則 | 值 | 位置 |
| --- | --- | --- |
| 腳印顏色 | 6 小時內 `fresh`（綠）、6～24 小時 `recent`（黃）、超過 24 小時或沒紀錄 `hungry`（紅） | `private.footprint_status` |
| 重複點提醒 | 30 公尺 | `find_nearby_spots` 預設值 |
| 重複投餵提醒 | 2 小時 | `check_recent_feeding` 預設值 |
| 清理提醒 | 餵食後 30 分鐘～24 小時 | `get_my_pending_cleanups` |
| 清理率 | 近 30 天 | `get_map_spots`、`get_spot_summary` |
| 訪客位置模糊 | 100 公尺網格 | `private.fuzz_point` |
| 保育警示 | 熱區範圍內 `red`、範圍外 200 公尺內 `yellow`、其他 `none` | `check_conservation_alert` |
| TNR 五階段 | 1 未結紮、2 誘捕中、3 已手術、4 術後照護、5 已原地回置；3 起 `is_sterilized = true` | `animals.tnr_stage` |

## RPC

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `get_map_spots` | 所有人 | `min_lng, min_lat, max_lng, max_lat` | `id, name, lat, lng, is_fuzzed, last_fed_at, footprint, animal_count, sterilized_count, clean_rate_30d`（最多 500 筆） | 地圖頁，地圖移動後依可視範圍呼叫 |
| `get_spot_summary` | 所有人 | `p_spot_id` | 上面欄位＋`description`（訪客為 null）`, status, feedings_30d, cleaned_30d, caretaker_count, is_caretaker` | 餵食點面板、進度公開 |
| `find_nearby_spots` | 登入者 | `p_lat, p_lng, p_radius_m = 30` | `id, name, distance_m, last_fed_at` | 建點前提示「附近已有餵食點，要加入嗎？」 |
| `create_feeding_spot` | 登入者 | `p_name, p_lat, p_lng, p_description?` | 新點 `uuid`（建立者自動成為 owner） | 建點表單 |
| `check_recent_feeding` | 登入者 | `p_spot_id, p_hours = 2` | 0 或 1 列：`log_id, fed_at, fed_by_name, minutes_ago` | 按「記錄餵食」前提示「小明 35 分鐘前餵過」 |
| `record_feeding` | 登入者 | `p_spot_id, p_food_type = 'dry', p_note?, p_fed_at?, p_client_id?` | 紀錄 `uuid` | 記錄餵食；離線補傳時帶 `p_client_id`（前端 `crypto.randomUUID()`）與 `p_fed_at`，重送不會重複 |
| `report_cleanup` | 本人、該點照顧者、管理員 | `p_log_id` | `cleaned_at` | 清理回報按鈕。餵食紀錄不能直接修改，清理只能走這支（0013） |
| `get_my_pending_cleanups` | 登入者 | 無 | `log_id, spot_id, spot_name, fed_at` | 開 App 時提醒「你在 X 點的餵食還沒回報清理」 |
| `set_user_role` | 管理員 | `p_user_id, p_role ('user'/'admin')` | 無 | 階段二管理員後台 |

### 階段 2：保育警示與管理員後台

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `get_conservation_zones` | 所有人 | 無 | `id, name, species, description, is_demo, geojson, buffer_geojson, updated_at`（只有使用中的熱區） | 地圖畫熱區（紅）與 200 公尺警示帶（黃）、宣導頁 |
| `check_conservation_alert` | 所有人 | `p_lat, p_lng` | 一定一列：`level`（`red` 範圍內／`yellow` 範圍外 200 公尺內／`none`）`, zone_id, zone_name, species, distance_m, is_demo` | 建點表單 |
| `check_spot_conservation_alert` | 登入者 | `p_spot_id` | 同上（點不存在回 0 列） | 動物建檔、餵食點面板 |
| `save_conservation_zone` | 管理員 | `p_name, p_geojson, p_species?, p_description?, p_is_demo = true, p_id?` | 熱區 `uuid` | 熱區繪製。`p_geojson` 收 Polygon 或 Feature；自我相交（`ST_IsValid` 不通過）、非單一多邊形、超過 500 個頂點或 10,000 平方公里會被拒絕 |
| `admin_list_users` | 管理員 | `p_search?, p_limit = 50` | `id, display_name, email, role, created_at, spot_count` | 後台使用者清單 |
| `set_user_role` | 管理員 | `p_user_id, p_role` | 無 | 後台角色設定；最後一位管理員不能被降級 |
| `admin_list_spots` | 管理員 | `p_search?, p_limit = 100` | `id, name, status, lat, lng, created_at, owner_names, caretaker_count, alert_level, zone_name`（含停用的點） | 後台餵食點管理 |
| `admin_set_spot_owner` | 管理員 | `p_spot_id, p_user_id` | 無 | 補上沒有 owner 的餵食點 |

熱區的停用、啟用與刪除直接寫 `conservation_zones`（`status` 欄位、`delete`），由 RLS 限制只有管理員可以。

### 階段 3：社區溝通

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `submit_neighbor_report` | 所有人（免登入） | `p_spot_id, p_category, p_description, p_turnstile_token?` | 通報 `uuid` | 匿名通報表單。頻率限制與 Turnstile 見下方 |
| `report_captcha_required` | 所有人 | 無 | `boolean` | 表單要不要顯示 Turnstile |
| `get_spot_public_reports` | 所有人 | `p_spot_id` | `id, category, status, response, created_at, handled_at`（近 180 天、最多 30 則，不含通報內容） | 公開進度頁 |
| `get_my_report_inbox` | 登入者 | 無 | `id, spot_id, spot_name, category, description, status, response, created_at, handled_at` | 照顧者收件匣（只有自己照顧的點；管理員為全部） |
| `handle_neighbor_report` | 該點照顧者、管理員 | `p_report_id, p_status ('open'/'acknowledged'/'resolved'), p_response?` | 無 | 處理通報；回覆會公開 |
| `admin_list_flags` | 管理員 | 無 | `target_type, target_id, post_id, title, excerpt, author_name, content_status, flag_count, reasons, last_flagged` | 後台檢舉清單 |
| `moderate_content` | 管理員 | `p_target_type ('post'/'comment'), p_target_id, p_hide` | 無 | 隱藏內容或駁回檢舉 |

通報類別 `category`：`mess` 環境髒亂、`noise` 噪音、`gathering` 動物聚集、`timing` 餵食時間不當、`other` 其他。

通報頻率限制（以來源 IP 的加鹽雜湊計算，不存原始 IP）：60 秒內 1 則、同一餵食點 10 分鐘內 1 則、1 小時內 3 則；另外每個餵食點 1 小時最多 10 則。

貼文、留言、檢舉直接讀寫 `posts`、`comments`、`content_flags`，由 RLS 把關：每人 1 小時最多 5 篇貼文、30 則留言；同一則內容被 3 個人檢舉會自動隱藏。

Turnstile 的設定步驟見 `docs/turnstile-setup.md`。

### 階段 5 延伸一：失蹤／健康哨兵

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `report_sighting` | 登入者 | `p_animal_id, p_condition?, p_spot_id?, p_note?, p_seen_at?` | `{ sighting_id, alert_id, missing_resolved }` | 身分檔的「回報目擊」。`alert_id` 有值表示發了健康提醒 |
| `get_animal_sightings` | 登入者 | `p_animal_id, p_limit?` | `id, seen_at, condition, note, spot_id, spot_name, reporter_name` | 身分檔的目擊紀錄 |
| `get_my_animal_alerts` | 登入者 | 無 | `id, type, status, animal_id, animal_name, spot_id, spot_name, condition, last_seen_at, threshold_days, note, created_at, updated_at, resolved_at` | 通知頁的「動物提醒」（照顧者、建檔者；管理員為全部） |
| `resolve_animal_alert` | 該動物的照顧者、建檔者、管理員 | `p_alert_id, p_note?, p_mark_missing?` | 無 | 結案；失蹤提醒可順便把動物標記為失蹤 |
| `admin_run_sentinel` | 管理員 | `p_run?`（`false` 只查狀態） | `{ created, scheduled, last_cron_run_at }` | 後台「哨兵」分頁 |

健康狀況 `condition`：`normal` 正常、`limping` 跛腳、`thin` 消瘦、`injured` 受傷。提醒類型 `type`：`missing` 可能失蹤、`health` 健康。

規則依 M1 決策表 3：門檻 T＝max（3 天，平均出現間隔 × 2）。回報受傷／跛腳／消瘦立即發健康提醒；每天 04:00（pg_cron）檢查，超過 T 沒被看到、期間該點有人餵過、而且這次沒出現還沒提醒過，就發「可能失蹤」提醒。`animals.last_seen_at` 是最後出現時間，訪客也讀得到。

### 階段 5 延伸二：餵食輪值與代班

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `create_shift` | 該點照顧者 | `p_spot_id, p_date, p_slot ('morning'/'evening'), p_note?` | 班次 `uuid` | 登記輪值 |
| `cancel_shift` | 排班者（還沒被代、還沒完成）、管理員 | `p_shift_id` | 無 | 取消這一班 |
| `request_shift_cover` | 排班者 | `p_shift_id, p_need?`（`false` 收回） | 無 | 求代班／收回 |
| `claim_shift` | 該點其他照顧者 | `p_shift_id` | 無 | 我來代班。只有第一位成功，其餘得到「已有人接了」；自己該時段有班會得到「時段衝突」 |
| `complete_shift` | 負責這一班的人（排班者或代班者） | `p_shift_id` | 無 | 標記完成（當天記錄餵食也會自動完成） |
| `get_my_shifts` | 登入者 | 無 | `id, spot_id, spot_name, shift_date, time_slot, status, note, user_id, user_name, cover_user_id, cover_name, is_mine, is_my_duty, can_claim` | 輪值表（自己照顧的點，從昨天起） |
| `get_my_shift_spots` | 登入者 | 無 | `id, name` | 登記輪值時可選的餵食點 |

班次狀態 `status`：`scheduled` 已排班、`need_cover` 求代班、`covered` 已代班、`done` 已完成。日期一律是臺灣時間。

### 階段 5 延伸三：TNR 接力

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `open_tnr_case` | 建檔者、該動物出沒點的照顧者、管理員 | `p_animal_id, p_note?` | 案件 `uuid` | 身分檔「發起接力」。建立四個任務，已經走到的階段直接算完成 |
| `cancel_tnr_case` | 發起人、可編輯這隻動物的人 | `p_case_id` | 無 | 取消接力（結紮階段不變） |
| `claim_tnr_task` | 登入者 | `p_task_id` | 無 | 我來。只有第一位成功，其餘得到「已有人認領」 |
| `unclaim_tnr_task` | 認領者；發起人與這隻動物的照顧者也可解除別人的認領 | `p_task_id` | 無 | 放棄或解除認領，回到待認領 |
| `complete_tnr_task` | 認領者 | `p_task_id, p_note?` | 更新後的 `tnr_stage` | 回報完成。前面的步驟要先完成；同一個人一天只能回報同一個案件的一個步驟（管理員不受限）；四步都完成時案件結案 |
| `get_tnr_tasks` | 登入者 | `p_animal_id?` | `task_id, case_id, case_status, case_note, opener_name, animal_id, animal_name, spot_name, step_no, step, status, claimed_by, claimer_name, note, done_at, is_mine, is_ready, can_manage` | 帶動物：最近一個案件的四個任務；不帶：所有進行中案件（看板） |

步驟 `step`：`trap` 誘捕、`vet` 送醫、`recovery` 術後照顧、`release` 放回，完成後 `animals.tnr_stage` 依序變成 2、3、4、5（只往前）。任務狀態：`open` 待認領、`claimed` 已認領、`done` 已完成。案件狀態：`open`、`done`、`cancelled`。

### 階段 5 延伸四：領養陪伴

| 函式 | 誰可呼叫 | 參數 | 回傳 | 用在哪 |
| --- | --- | --- | --- | --- |
| `register_adoption` | 登入者 | `p_animal_id, p_adopted_on?, p_note?` | 領養 `uuid` | 身分檔「我領養了牠」。一般會員是待確認；能編輯這隻動物的人直接生效 |
| `confirm_adoption` | 建檔者、該動物出沒點的照顧者、管理員（不能是領養人本人） | `p_adoption_id` | 無 | 確認登記。確認的人成為陪伴者，建立三份問卷，動物狀態改成 `adopted` |
| `cancel_adoption` | 領養人、陪伴者、可編輯這隻動物的人 | `p_adoption_id` | 無 | 撤回、退回或退養。已生效的話動物狀態改回 `active` |
| `submit_adoption_followup` | 領養人 | `p_followup_id, p_eating_ok, p_health_ok, p_settled_ok, p_note?` | `boolean`（是否有狀況） | 填關懷問卷。到期才能填；三份都填完，紀錄改成 `completed` |
| `get_adoptions` | 登入者 | `p_animal_id?` | `adoption_id, animal_id, animal_name, status, adopted_on, note, adopter_name, buddy_name, my_role, due_count, issue_count, followups` | 帶動物：這隻動物目前的領養紀錄；不帶：跟我有關的（我領養的、我陪伴的、等我確認的） |

領養狀態 `status`：`pending` 待確認、`active` 陪伴中、`completed` 三份問卷都填完、`cancelled` 已取消。`my_role`：`adopter` 領養人、`buddy` 陪伴者、`caretaker` 可以確認或取消的人、`viewer` 其他人（`note`、`followups`、`issue_count` 不提供）。`followups` 是陣列，每筆有 `id, day_offset`（7、30、90）`, due_on, is_due, answered_at, eating_ok, health_ok, settled_ok, has_issue, note`。這個 migration 也修正了 `cancel_tnr_case` 在發起人帳號被刪除後權限檢查失效的問題。

`food_type`：`dry` 乾糧、`wet` 濕食、`mixed` 混合、`other` 其他。

## 範例

```js
// 地圖：依可視範圍取點
const b = map.getBounds()
const { data: spots } = await supabase.rpc('get_map_spots', {
  min_lng: b.getWest(), min_lat: b.getSouth(), max_lng: b.getEast(), max_lat: b.getNorth(),
})

// 建點前檢查 30m
const { data: nearby } = await supabase.rpc('find_nearby_spots', { p_lat: lat, p_lng: lng })
if (nearby.length) { /* 提示加入既有點：supabase.from('spot_caretakers').insert({ spot_id, user_id }) */ }
const { data: spotId } = await supabase.rpc('create_feeding_spot', { p_name, p_lat: lat, p_lng: lng })

// 記錄餵食（含 2 小時提醒）
const { data: recent } = await supabase.rpc('check_recent_feeding', { p_spot_id: spotId })
if (recent.length) { /* 「${recent[0].fed_by_name} ${recent[0].minutes_ago} 分鐘前餵過，確定要再餵？」 */ }
await supabase.rpc('record_feeding', { p_spot_id: spotId, p_food_type: 'dry', p_client_id: crypto.randomUUID() })

// 即時同步（登入者）：有新紀錄就重抓該點摘要
supabase.channel('feeding')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'feeding_logs' },
      (p) => refreshSpot(p.new.spot_id))
  .subscribe()

// 動物建檔 + 連到點 + 照片
const { data: animal } = await supabase.from('animals')
  .insert({ name: '小橘', species: 'cat', sex: 'male', tnr_stage: 1 }).select().single()
await supabase.from('spot_animals').insert({ spot_id: spotId, animal_id: animal.id })
const path = `${animal.id}/${crypto.randomUUID()}.webp`        // 第一層必須是動物 id
await supabase.storage.from('animal-photos').upload(path, compressedBlob)  // 先壓縮、去 GPS
await supabase.from('animal_photos').insert({ animal_id: animal.id, storage_path: path })
const url = supabase.storage.from('animal-photos').getPublicUrl(path).data.publicUrl
```

## 本機測試

```bash
# 需要 PostgreSQL 15+ 與 PostGIS 3；輪值的同時認領測試另外用到內建的 dblink 擴充套件
PGHOST=localhost PGUSER=postgres bash supabase/tests/run_tests.sh
```

測試用 `supabase/tests/00_supabase_mock.sql` 模擬 Supabase 的 anon/authenticated 角色、`auth.uid()` 與 storage，不會進正式資料庫。
正式套用：`supabase link` 後執行 `supabase db push`。
