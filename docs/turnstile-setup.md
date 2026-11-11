# 啟用 Turnstile 人機驗證（選配）

匿名通報表單預設只靠頻率限制擋灌水。要再加上 Cloudflare Turnstile，照下面三步做。三步都完成前不要只做一半：資料庫一旦有 secret，沒帶驗證的通報就會被拒絕。

1. **申請金鑰**：到 Cloudflare 後台的 Turnstile 新增一個 widget，網域填正式站網域（Vercel 預覽網址也要用的話一併加上）。會拿到 site key（公開）與 secret key（機密）。
2. **前端**：在 Vercel 專案的環境變數加上 `VITE_TURNSTILE_SITE_KEY=<site key>`，重新部署。
3. **資料庫**：在 Supabase 的 SQL Editor 執行（secret 不要寫進 repo 或聊天紀錄以外的任何檔案）：

```sql
insert into private.app_secrets (key, value) values ('turnstile_secret', '<secret key>')
on conflict (key) do update set value = excluded.value, updated_at = now();
```

停用：

```sql
delete from private.app_secrets where key = 'turnstile_secret';
```

## 運作方式

- 表單載入時呼叫 `report_captcha_required()`，為 true 才顯示驗證元件。
- 送出時 `submit_neighbor_report()` 先做頻率限制，再用資料庫的 `http` 擴充套件向 Cloudflare 驗證 token。驗證失敗、逾時或擴充套件不存在都視為沒通過。
- 驗收腳本拿不到有效 token，啟用後會自動略過需要送出通報的項目。

## 還沒驗證的部分

向 Cloudflare 驗證這一段只在本機測過「沒帶 token 與連不上時會拒絕」，還沒有用真的金鑰跑過成功的情況。啟用後請先自己送一則通報確認可以成功，不行就先用上面的 SQL 停用。
