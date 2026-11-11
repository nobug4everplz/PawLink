-- =============================================================
-- 階段 5 延伸四測試：領養陪伴（處理 3.4）
-- 完成條件：登記領養後第 7、30、90 天產生提醒
-- 接在 10～60 之後執行（沿用 test schema、測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

create function test.fu(p_ad text, p_day int) returns uuid language sql stable security definer as
$$ select id from public.adoption_followups where adoption_id = test.id(p_ad) and day_offset = p_day $$;
create function test.ad(p_ad text) returns public.adoptions language sql volatile security definer as
$$ select * from public.adoptions where id = test.id(p_ad) $$;
create function test.astatus(p_animal text) returns text language sql volatile security definer as
$$ select status from public.animals where id = test.id(p_animal) $$;
create function test.today() returns date language sql stable security definer as
$$ select (now() at time zone 'Asia/Taipei')::date $$;
grant execute on all functions in schema test to anon, authenticated;

-- 準備：OWNER 建四隻動物
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
with a as (insert into public.animals (name, status) values ('領養貓', 'active'), ('自己養的貓', 'active'), ('離世的貓', 'deceased'), ('退回的貓', 'active') returning id, name)
insert into test.ids select case name when '領養貓' then 'aA' when '自己養的貓' then 'aB' when '離世的貓' then 'aC' else 'aD' end, id from a;

-- =============================================================
-- 1. 登記
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.register_adoption(%L)$$, test.id('aA')), '訪客不能登記領養');
select test.throws('select * from public.adoptions', '訪客讀不到領養紀錄');
select test.throws('select * from public.get_adoptions()', '訪客不能呼叫領養清單');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws('select * from public.adoptions', '登入者也不能直接讀領養表');
select test.throws('select * from public.adoption_followups', '登入者也不能直接讀問卷表');
select test.throws(format($$insert into public.adoptions (animal_id, adopted_on) values (%L, current_date)$$, test.id('aA')), '不能繞過 RPC 直接建立領養紀錄');
select test.throws($$select public.register_adoption('00000000-0000-0000-0000-0000000000ff')$$, '不存在的動物被擋下');
select test.throws(format($$select public.register_adoption(%L)$$, test.id('aC')), '離世的動物不能登記領養');
select test.throws(format($$select public.register_adoption(%L, %L)$$, test.id('aA'), test.today() + 1), '領養日期不能是未來');
select test.throws(format($$select public.register_adoption(%L, %L)$$, test.id('aA'), test.today() - 366), '領養日期不能超過一年前');
select test.throws(format($$select public.register_adoption(%L, null, %L)$$, test.id('aA'), repeat('字', 201)), '備註超過 200 字被擋下');

-- USER 在 100 天前領養了「領養貓」
insert into test.ids values ('ad', public.register_adoption(test.id('aA'), test.today() - 100, '  帶回家了  '));
select test.ok((select status = 'pending' and buddy_id is null and note = '帶回家了' and adopter_id = :USER::uuid from test.ad('ad')), '一般會員登記後是待確認，備註去掉前後空白');
select test.ok(test.astatus('aA') = 'active' and (select count(*) = 0 from public.get_adoptions() g, jsonb_array_elements(g.followups)),
               '待確認時動物狀態不變，也還沒有問卷');
select test.ok((select count(*) = 1 and bool_and(my_role = 'adopter' and due_count = 0) from public.get_adoptions()), '領養人在自己的清單看得到這筆登記');
select test.throws(format($$select public.confirm_adoption(%L)$$, test.id('ad')), '領養人不能自己確認');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.register_adoption(%L)$$, test.id('aA')), '同一隻動物已有人登記時不能再登記');
select test.throws(format($$select public.confirm_adoption(%L)$$, test.id('ad')), '不相關的人不能確認');
select test.throws(format($$select public.cancel_adoption(%L)$$, test.id('ad')), '不相關的人不能取消');
select test.ok((select count(*) = 0 from public.get_adoptions()), '不相關的人的清單沒有這筆');
select test.ok((select count(*) = 1 and bool_and(my_role = 'viewer' and note is null and followups = '[]'::jsonb and adopter_name is not null)
                from public.get_adoptions(test.id('aA'))), '其他登入者在動物頁只看得到狀態與領養人暱稱');

-- =============================================================
-- 2. 確認，產生第 7、30、90 天問卷
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select count(*) = 1 and bool_and(my_role = 'caretaker' and status = 'pending') from public.get_adoptions()), '建檔者的清單看得到等他確認的登記');
select public.confirm_adoption(test.id('ad'));
select test.ok((select status = 'active' and buddy_id = :OWNER::uuid from test.ad('ad')), '建檔者確認後生效，確認的人成為陪伴者');
select test.ok(test.astatus('aA') = 'adopted', '確認後動物狀態自動變成已領養');
reset role;
select test.ok((select array_agg(day_offset order by day_offset) = array[7, 30, 90]::smallint[]
                   and array_agg(due_on order by day_offset) = array[test.today() - 93, test.today() - 70, test.today() - 10]
                from public.adoption_followups where adoption_id = test.id('ad')), '確認後產生第 7、30、90 天三份問卷，到期日依領養日期計算');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.confirm_adoption(%L)$$, test.id('ad')), '已確認的登記不能重複確認');
select test.ok((select my_role = 'buddy' and due_count = 3 and issue_count = 0 and jsonb_array_length(followups) = 3 from public.get_adoptions()), '陪伴者看得到三份到期的問卷');
select test.throws(format($$select public.submit_adoption_followup(%L, true, true, true)$$, test.fu('ad', 7)), '陪伴者不能代填問卷');

-- 被哨兵標成失蹤的動物不會被提醒：已領養的動物不在哨兵檢查範圍
reset role;
select test.ok((select count(*) = 0 from public.animal_alerts where animal_id = test.id('aA') and status = 'open'), '已領養的動物沒有未處理的哨兵提醒');

-- =============================================================
-- 3. 填問卷
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select due_count = 3 from public.get_adoptions()), '領養人的清單顯示有三份問卷到期');
select test.throws(format($$select public.submit_adoption_followup(%L, true, null, true)$$, test.fu('ad', 7)), '三題都要回答');
select test.throws(format($$select public.submit_adoption_followup(%L, true, true, true, %L)$$, test.fu('ad', 7), repeat('字', 301)), '補充說明超過 300 字被擋下');
select test.ok(public.submit_adoption_followup(test.fu('ad', 7), true, true, true, ' 適應得很好 ') = false, '三題都答「是」：沒有狀況');
select test.throws(format($$select public.submit_adoption_followup(%L, true, true, true)$$, test.fu('ad', 7)), '填過的問卷不能再填');
select test.ok(public.submit_adoption_followup(test.fu('ad', 30), true, false, true, '最近打噴嚏') = true, '有一題答「否」：標成有狀況');
select test.ok((select due_count = 1 and issue_count = 1 and status = 'active' from public.get_adoptions()), '還有一份沒填時維持陪伴中');
select test.ok((select (f ->> 'has_issue')::boolean and f ->> 'note' = '最近打噴嚏' and not (f ->> 'is_due')::boolean
                from public.get_adoptions() g, jsonb_array_elements(g.followups) f where (f ->> 'day_offset')::int = 30), '清單帶出問卷回答與補充說明');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select issue_count = 1 from public.get_adoptions()), '陪伴者看得到有狀況的問卷');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok((select issue_count = 0 and due_count = 1 and followups = '[]'::jsonb from public.get_adoptions(test.id('aA'))), '其他人看不到問卷內容與狀況');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok(public.submit_adoption_followup(test.fu('ad', 90), true, true, true) = false
           and (select status = 'completed' and closed_at is not null from test.ad('ad')), '三份都填完：領養紀錄自動完成');
select test.ok(test.astatus('aA') = 'adopted' and (select due_count = 0 from public.get_adoptions()), '完成後動物仍是已領養，沒有待填問卷');
select test.throws(format($$select public.register_adoption(%L)$$, test.id('aA')), '已完成領養的動物不能再登記');

-- =============================================================
-- 4. 還沒到期、照顧者自己領養
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('adB', public.register_adoption(test.id('aB'), test.today() - 7));
select test.ok((select status = 'active' and buddy_id is null from test.ad('adB')) and test.astatus('aB') = 'adopted', '建檔者自己領養：直接生效，不需要再確認');
select test.ok((select due_count = 1 from public.get_adoptions() where animal_id = test.id('aB')), '領養滿 7 天當天，第 7 天問卷到期');
select test.throws(format($$select public.submit_adoption_followup(%L, true, true, true)$$, test.fu('adB', 30)), '還沒到期的問卷不能先填');
select test.ok(public.submit_adoption_followup(test.fu('adB', 7), true, true, false) = true, '到期當天可以填');
select test.ok((select status = 'active' and due_count = 0 from public.get_adoptions() where animal_id = test.id('aB')), '後面兩份還沒到期，維持陪伴中');

-- =============================================================
-- 5. 取消與退養
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
insert into test.ids values ('adD', public.register_adoption(test.id('aD')));
select public.cancel_adoption(test.id('adD'));
select test.ok((select status = 'cancelled' from test.ad('adD')) and test.astatus('aD') = 'active', '領養人可以撤回待確認的登記');
select test.throws(format($$select public.cancel_adoption(%L)$$, test.id('adD')), '已取消的登記不能再取消');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.confirm_adoption(%L)$$, test.id('adD')), '已取消的登記不能確認');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
insert into test.ids values ('adD2', public.register_adoption(test.id('aD'), test.today() - 10));
select test.ok((select status = 'pending' from test.ad('adD2')), '取消後別人可以重新登記');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select public.confirm_adoption(test.id('adD2'));
select test.ok((select buddy_id = :ADMIN::uuid from test.ad('adD2')) and test.astatus('aD') = 'adopted', '管理員也可以確認');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.cancel_adoption(test.id('adD2'));
select test.ok((select status = 'cancelled' from test.ad('adD2')) and test.astatus('aD') = 'active', '照顧者登記退養：動物回到一般狀態');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.submit_adoption_followup(%L, true, true, true)$$, test.fu('adD2', 7)), '退養後不能再填問卷');
select test.ok((select count(*) = 0 from public.get_adoptions(test.id('aD'))), '退養後動物頁不再顯示領養紀錄');

-- =============================================================
-- 6. 補 TNR 接力：發起人帳號被刪除（opened_by 變空值）後，不相關的人仍然不能取消案件
-- =============================================================
reset role;
update public.tnr_cases set opened_by = null where id = test.id('caseB2');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.cancel_tnr_case(%L)$$, test.id('caseB2')), '發起人是空值時，不相關的人不能取消 TNR 案件');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.cancel_tnr_case(test.id('caseB2'));
select test.ok((select status = 'cancelled' from public.tnr_cases where id = test.id('caseB2')), '照顧者仍然可以取消');
reset role;

\echo '階段 5 領養陪伴測試通過'
