-- =============================================================
-- 階段 3 測試：匿名通報與頻率限制、通報收件、進度公開、交流空間與檢舉
-- 接在 10、20 之後執行（沿用 test schema、測試帳號與餵食點）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

-- 模擬不同來源 IP、把時間往前撥（測試用，以 superuser 執行）
create function test.ip(p text) returns void language sql as
$$ select set_config('request.headers', json_build_object('x-forwarded-for', p || ', 10.0.0.1')::text, false) $$;
create function test.age_reports(p interval) returns void language sql security definer as
$$ update public.neighbor_reports set created_at = created_at - p $$;
grant execute on function test.ip(text), test.age_reports(interval) to anon, authenticated;

-- spot：OWNER 是 owner、CARE 是照顧者（20 的測試把 CARE 也升成 owner）；spot2：OWNER 與路人是 owner
-- =============================================================
-- 1. 匿名通報與頻率限制（FR-2.1、NFR-6）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.ip('203.0.113.7');
select test.throws(format($$select public.submit_neighbor_report(%L, 'mess', '太短')$$, test.id('spot')), '說明太短被擋下');
select test.throws(format($$select public.submit_neighbor_report(%L, 'spam', '這是一則測試通報內容')$$, test.id('spot')), '不認得的類別被擋下');
select test.throws($$select public.submit_neighbor_report('00000000-0000-0000-0000-0000000000ff', 'mess', '這是一則測試通報內容')$$, '不存在的餵食點被擋下');
select test.throws(format($$insert into public.neighbor_reports (spot_id, category, description, ip_hash) values (%L, 'mess', '直接寫表的通報', 'x')$$, test.id('spot')),
                   '訪客不能繞過 RPC 直接寫 neighbor_reports');

insert into test.ids values ('report', public.submit_neighbor_report(test.id('spot'), 'mess', '  飼料盒沒有收，引來很多蟑螂  '));
select test.ok(test.id('report') is not null, '沒登入的居民可以送出通報');
select test.throws('select * from public.neighbor_reports', '訪客讀不到通報內容');
select test.throws(format($$select public.submit_neighbor_report(%L, 'noise', '馬上再送一次同一個點')$$, test.id('spot')), '60 秒內重複送出被擋下');
select test.throws(format($$select public.submit_neighbor_report(%L, 'noise', '馬上送到另一個餵食點')$$, test.id('spot2')), '60 秒內送到別的點也被擋下');

select test.age_reports(interval '2 minutes');
select test.throws(format($$select public.submit_neighbor_report(%L, 'noise', '兩分鐘後又通報同一個點')$$, test.id('spot')), '同一個點 10 分鐘內只能通報一次');
insert into test.ids values ('report2', public.submit_neighbor_report(test.id('spot2'), 'noise', '半夜餵食聲音很大'));
select test.ok(test.id('report2') is not null, '過了 60 秒可以通報另一個點');

-- 別的 IP 不受影響
select test.ip('198.51.100.9');
insert into test.ids values ('report3', public.submit_neighbor_report(test.id('spot'), 'gathering', '晚上聚集了十幾隻貓'));
select test.ok(test.id('report3') is not null, '不同來源 IP 不受別人的頻率限制影響');

-- 每小時 3 則
select test.ip('203.0.113.7');
select test.age_reports(interval '11 minutes');
select public.submit_neighbor_report(test.id('spot'), 'timing', '清晨五點就來餵食');
select test.age_reports(interval '11 minutes');
select test.throws(format($$select public.submit_neighbor_report(%L, 'other', '一小時內的第四則通報')$$, test.id('spot2')), '同一來源 1 小時內最多 3 則');
select test.age_reports(interval '40 minutes');
select test.ok(public.submit_neighbor_report(test.id('spot2'), 'other', '超過一小時後可以再通報') is not null, '最早的通報超過 1 小時後可以再送');

reset role;
select test.ok((select count(*) = 5 and count(distinct ip_hash) = 2 and bool_and(ip_hash !~ '[.]' and length(ip_hash) = 64)
                from public.neighbor_reports), '只存加鹽雜湊後的 IP，不存原始 IP');
select test.ok((select description = '飼料盒沒有收，引來很多蟑螂' from public.neighbor_reports where id = test.id('report')), '說明前後空白會去掉');

-- 單一餵食點每小時 10 則（來源各不相同）
do $$
declare i int;
begin
  perform test.age_reports(interval '2 hours');
  set role anon;
  for i in 1..10 loop
    perform test.ip('192.0.2.' || i);
    perform public.submit_neighbor_report(test.id('spot2'), 'other', '灌水測試第 ' || i || ' 則');
  end loop;
  reset role;
end $$;
set role anon;
select test.ip('192.0.2.99');
select test.throws(format($$select public.submit_neighbor_report(%L, 'other', '第十一則會被擋下')$$, test.id('spot2')), '單一餵食點 1 小時最多 10 則');
reset role;
delete from public.neighbor_reports where description like '灌水測試%';

-- Turnstile：設定 secret 後沒帶 token 會被擋（本機沒有 http 擴充套件，有 token 也視為驗證失敗）
set role anon;
select test.ok(not public.report_captcha_required(), '沒設定 secret 時不要求人機驗證');
reset role;
insert into private.app_secrets (key, value) values ('turnstile_secret', 'test-secret');
set role anon; select test.ip('192.0.2.200');
select test.ok(public.report_captcha_required(), '設定 secret 後前端會被告知需要人機驗證');
select test.throws(format($$select public.submit_neighbor_report(%L, 'mess', '沒有帶人機驗證的通報')$$, test.id('spot')), '啟用 Turnstile 後沒帶 token 被擋下');
select test.throws(format($$select public.submit_neighbor_report(%L, 'mess', '帶了假的人機驗證', 'fake-token-0123456789')$$, test.id('spot')), '驗證服務連不上或 token 無效時不放行');
select test.throws('select * from private.app_secrets', '訪客讀不到 secret');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws('select * from private.app_secrets', '登入者讀不到 secret');
reset role;
delete from private.app_secrets where key = 'turnstile_secret';

-- =============================================================
-- 2. 通知照顧者：只有該點照顧者看得到（FR-2.2）
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select count(*) from public.neighbor_reports) = 0, '無關的登入者查不到通報內容');
select test.ok((select count(*) from public.get_my_report_inbox()) = 0, '無關的登入者收件匣是空的');
select test.throws('select ip_hash from public.neighbor_reports', '登入者讀不到 ip_hash 欄位');
select test.throws(format($$select public.handle_neighbor_report(%L, 'resolved', '我來亂的')$$, test.id('report')), '無關的登入者不能處理通報');
select test.throws(format($$update public.neighbor_reports set status = 'resolved' where id = %L$$, test.id('report')), '不能繞過 RPC 直接改通報');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok((select count(*) > 0 and bool_and(spot_id = test.id('spot2')) from public.get_my_report_inbox()), 'spot2 的照顧者只看得到 spot2 的通報');
select test.throws(format($$select public.handle_neighbor_report(%L, 'resolved')$$, test.id('report')), '不能處理別的餵食點的通報');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.ok((select count(*) = 3 and bool_and(spot_id = test.id('spot')) from public.get_my_report_inbox()), '照顧者看得到自己照顧點的通報內容');
select test.ok((select spot_name is not null and description = '飼料盒沒有收，引來很多蟑螂' from public.get_my_report_inbox() where id = test.id('report')), '收件匣含餵食點名稱與通報內容');
select public.handle_neighbor_report(test.id('report'), 'acknowledged', '  已收到，今天會去清理  ');
select test.ok((select status = 'acknowledged' and response = '已收到，今天會去清理' and handled_at is not null from public.neighbor_reports where id = test.id('report')),
               '照顧者可回覆並標記處理中');
select public.handle_neighbor_report(test.id('report'), 'resolved', '已清理並加裝有蓋餵食盒');
select test.throws(format($$select public.handle_neighbor_report(%L, 'done')$$, test.id('report')), '不接受未定義的狀態');
select test.throws(format($$select public.handle_neighbor_report(%L, 'resolved', %L)$$, test.id('report'), repeat('長', 301)), '回覆超過 300 字被擋下');

set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.handle_neighbor_report(%L, 'open')$$, test.id('report')), '訪客不能處理通報');
select test.throws('select * from public.get_my_report_inbox()', '訪客沒有收件匣');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select count(distinct spot_id) = 2 from public.get_my_report_inbox()), '管理員看得到所有餵食點的通報');

-- =============================================================
-- 3. 進度公開：訪客看得到統計與處理狀態，看不到內容（FR-2.2）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.ok((select count(*) = 3 from public.get_spot_public_reports(test.id('spot'))), '訪客看得到該點的通報處理進度');
select test.ok((select status = 'resolved' and response = '已清理並加裝有蓋餵食盒' and category = 'mess'
                from public.get_spot_public_reports(test.id('spot')) where id = test.id('report')), '公開進度含類別、狀態與照顧者回覆');
select test.ok((select to_jsonb(r) ?| array['description', 'ip_hash', 'handled_by'] from public.get_spot_public_reports(test.id('spot')) r limit 1) is false,
               '公開進度不含通報內容、來源與處理人');
select test.ok((select clean_rate_30d is not null or feedings_30d = 0 from public.get_spot_summary(test.id('spot'))), '訪客看得到清理率統計');

-- =============================================================
-- 4. 交流空間（FR-2.3）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws('select * from public.posts', '訪客不能讀貼文');
select test.throws($$insert into public.posts (title, body) values ('訪客', '訪客發文')$$, '訪客不能發文');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
with p as (insert into public.posts (title, body) values ('請問乾糧品牌', '大家都餵哪一牌？') returning id)
insert into test.ids select 'post', id from p;
select test.ok((select author_id = auth.uid() and status = 'visible' from public.posts where id = test.id('post')), '登入者可發文，作者自動填入');
select test.throws($$insert into public.posts (title, body, author_id) values ('冒名', '冒名發文', '00000000-0000-0000-0000-00000000000b')$$, '不能冒名發文');
select test.throws($$insert into public.posts (title, body, status) values ('x', 'y', 'hidden')$$, '不能自己指定貼文狀態');
select test.throws($$insert into public.posts (title, body) values ('', '沒有標題')$$, '標題不可空白');
select test.ok(test.affects($$update public.posts set body = '大家都餵哪一牌？求推薦' where id = test.id('post')$$) = 1, '作者可修改自己的貼文');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
with c as (insert into public.comments (post_id, body) values (test.id('post'), '我都買大包裝的') returning id)
insert into test.ids select 'comment', id from c;
select test.ok((select count(*) from public.comments where post_id = test.id('post')) = 1, '登入者可留言');
select test.ok(test.affects($$update public.posts set body = '被改了' where id = test.id('post')$$) = 0, '不能改別人的貼文');
select test.ok(test.affects($$delete from public.posts where id = test.id('post')$$) = 0, '不能刪別人的貼文');
select test.throws($$update public.posts set status = 'hidden' where id = test.id('post')$$, '一般使用者不能隱藏貼文');
select test.throws($$update public.comments set body = 'x' where id = test.id('comment')$$, '留言送出後不能修改');
select test.throws('select * from public.admin_list_flags()', '一般使用者不能看檢舉清單');
select test.throws(format($$select public.moderate_content('post', %L, true)$$, test.id('post')), '一般使用者不能處理檢舉');

-- 檢舉：同一人只能檢舉一次；3 人檢舉自動隱藏
insert into public.content_flags (post_id, reason) values (test.id('post'), '廣告');
select test.throws(format($$insert into public.content_flags (post_id, reason) values (%L, '再檢舉一次')$$, test.id('post')), '同一人不能重複檢舉同一篇');
select test.throws(format($$insert into public.content_flags (post_id, comment_id, reason) values (%L, %L, '兩個目標')$$, test.id('post'), test.id('comment')), '一次只能檢舉一個目標');
select test.throws($$insert into public.content_flags (reason) values ('沒有目標')$$, '檢舉必須有目標');
select test.ok((select count(*) from public.content_flags) = 1, '看得到自己送出的檢舉');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select count(*) from public.content_flags) = 0, '看不到別人的檢舉');
insert into public.content_flags (post_id, reason) values (test.id('post'), '離題');
select test.ok((select status = 'visible' from public.posts where id = test.id('post')), '2 人檢舉還不會隱藏');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
insert into public.content_flags (post_id, reason) values (test.id('post'), '不實資訊');
select test.ok((select count(*) from public.posts where id = test.id('post')) = 0, '3 人檢舉後自動隱藏，其他人看不到');
select test.throws(format($$insert into public.comments (post_id, body) values (%L, '在隱藏的貼文留言')$$, test.id('post')), '隱藏的貼文不能再留言');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select status = 'hidden' from public.posts where id = test.id('post')), '作者看得到自己的貼文被隱藏');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select flag_count = 3 and content_status = 'hidden' and target_type = 'post' and reasons like '%廣告%'
                from public.admin_list_flags() where target_id = test.id('post')), '管理員看得到檢舉清單與理由');
select public.moderate_content('post', test.id('post'), false);
select test.ok((select status = 'visible' from public.posts where id = test.id('post'))
               and (select count(*) from public.admin_list_flags()) = 0, '管理員可恢復貼文並駁回檢舉');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
insert into public.content_flags (comment_id, reason) values (test.id('comment'), '人身攻擊');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select target_type = 'comment' and post_id = test.id('post') from public.admin_list_flags()), '留言也可以被檢舉');
select public.moderate_content('comment', test.id('comment'), true);
select test.ok((select status = 'hidden' from public.comments where id = test.id('comment')), '管理員可隱藏留言');
select test.throws($$select public.moderate_content('post', '00000000-0000-0000-0000-0000000000ff', true)$$, '處理不存在的內容會報錯');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select count(*) from public.comments where post_id = test.id('post')) = 0, '被隱藏的留言其他人看不到');

-- 發文頻率限制
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
do $$ begin for i in 1..5 loop insert into public.posts (title, body) values ('洗版 ' || i, '洗版內容'); end loop; end $$;
select test.throws($$insert into public.posts (title, body) values ('洗版 6', '洗版內容')$$, '1 小時內第 6 篇貼文被擋下');
select test.ok(test.affects($$delete from public.posts where author_id = auth.uid()$$) = 5, '作者可刪除自己的貼文');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok(test.affects($$delete from public.posts where id = test.id('post')$$) = 1, '管理員可刪除任何貼文（留言一併刪除）');

reset role;
\echo '階段 3 測試通過'
