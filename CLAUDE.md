# CLAUDE.md

先讀 [`docs/CODEMAP.md`](docs/CODEMAP.md)：目錄、路由與頁面對照、資料表與 RPC、RLS 重點、migration 與正式庫狀態、部署、測試、常見坑都在裡面。

最重要的幾條：
- 資料庫變更只寫在 `supabase/migrations/`，每張表都開 RLS，`service_role` 不進 repo。
- 正式庫判斷 migration 有沒有套用要直接查物件，`list_migrations` 不準（多數是在 SQL Editor 手動貼的）。
- 連接器執行含 drop/delete 或 `apply_migration` 會跳確認視窗逾時，改請使用者自己貼 SQL Editor。
- 必保功能：已餵食／已結紮標記（FR-1.3/1.4）。
- 改了架構、路由、表或 RPC，順手更新 `docs/CODEMAP.md`。
