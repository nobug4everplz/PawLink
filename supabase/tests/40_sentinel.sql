-- =============================================================
-- 階段 5 延伸一測試：失蹤／健康哨兵（M1 決策表 3 的五條規則與門檻邊界值）
-- 接在 10、20、30 之後執行（沿用 test schema 與測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

-- 測試用（superuser 權限）：數提醒、把最後出現時間往前撥、補一筆過去的餵食、在指定時間跑一次檢查
create function test.alerts(p_animal text, p_type text, p_status text default null) returns int
language sql security definer as
$$ select count(*)::int from public.animal_alerts
   where animal_id = test.id(p_animal) and type = p_type and (p_status is null or status = p_status) $$;
create function test.last_seen(p_animal text, p_ago interval) returns void language sql security definer as
$$ update public.animals set last_seen_at = now() - p_ago where id = test.id(p_animal) $$;
create function test.fed(p_spot text, p_ago interval) returns void language sql security definer as
$$ insert into public.feeding_logs (spot_id, user_id, fed_at, created_at)
   values (test.id(p_spot), '00000000-0000-0000-0000-00000000000b', now() - p_ago, now() - p_ago) $$;
create function test.sighted(p_animal text, p_ago interval) returns void language sql security definer as
$$ insert into public.sightings (animal_id, seen_at, created_at, reported_by)
   values (test.id(p_animal), now() - p_ago, now() - p_ago, '00000000-0000-0000-0000-00000000000d') $$;
create function test.run_at(p_ago interval) returns int language sql security definer as
$$ select private.run_missing_sentinel(now() - p_ago, 'test') $$;
grant execute on all functions in schema test to anon, authenticated;

-- 準備：OWNER 建兩個餵食點（只有 OWNER 是照顧者）與六隻動物
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('sspot', public.create_feeding_spot('哨兵測試點', 23.9001, 120.9001));
insert into test.ids values ('sspot2', public.create_feeding_spot('哨兵測試點二', 23.9101, 120.9001));
with a as (insert into public.animals (name) values ('健康貓'), ('邊界貓'), ('沒人餵貓'), ('規律貓'), ('已送養貓'), ('循環貓')
           returning id, name)
insert into test.ids select case name when '健康貓' then 'aH' when '邊界貓' then 'aM' when '沒人餵貓' then 'aN'
                                     when '規律貓' then 'aP' when '已送養貓' then 'aQ' else 'aR' end, id from a;
insert into public.spot_animals (spot_id, animal_id)
select test.id('sspot'), v from test.ids where k in ('aH', 'aM', 'aN', 'aP', 'aQ', 'aR');
select test.ok((select last_seen_at is not null and last_seen_at >= created_at - interval '1 second' from public.animals where id = test.id('aH')),
               '建檔當下算第一次出現（last_seen_at 有值）');
select test.throws(format($$update public.animals set last_seen_at = now() - interval '1 year' where id = %L$$, test.id('aH')),
                   '使用者不能自己改最後出現時間');

-- =============================================================
-- 1. 目擊回報的權限與檢查（FR-13）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.report_sighting(%L)$$, test.id('aH')), '訪客不能回報目擊');
select test.throws('select * from public.sightings', '訪客讀不到目擊紀錄');
select test.throws('select * from public.animal_alerts', '訪客讀不到提醒');
select test.throws(format($$select * from public.get_animal_sightings(%L)$$, test.id('aH')), '訪客不能查目擊紀錄');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.report_sighting(%L, 'sick')$$, test.id('aH')), '不認得的健康狀況被擋下');
select test.throws($$select public.report_sighting('00000000-0000-0000-0000-0000000000ff')$$, '不存在的動物被擋下');
select test.throws(format($$select public.report_sighting(%L, 'normal', null, null, now() + interval '1 hour')$$, test.id('aH')), '未來的目擊時間被擋下');
select test.throws(format($$select public.report_sighting(%L, 'normal', null, null, now() - interval '8 days')$$, test.id('aH')), '超過 7 天前的目擊被擋下');
select test.throws(format($$select public.report_sighting(%L, 'normal', %L)$$, test.id('aH'), test.id('sspot2')), '動物不在的餵食點被擋下');
select test.throws(format($$select public.report_sighting(%L, 'normal', null, %L)$$, test.id('aH'), repeat('字', 201)), '備註超過 200 字被擋下');
select test.throws(format($$insert into public.sightings (animal_id) values (%L)$$, test.id('aH')), '不能繞過 RPC 直接寫 sightings');
select test.throws(format($$insert into public.animal_alerts (animal_id, type) values (%L, 'health')$$, test.id('aH')), '不能直接寫 animal_alerts');

select test.last_seen('aH', interval '2 days');
select public.report_sighting(test.id('aH'), 'normal', null, '  在機車下睡覺  ') as r \gset
select test.ok((:'r'::jsonb ->> 'sighting_id') is not null and (:'r'::jsonb ->> 'alert_id') is null, '登入者可以回報目擊；狀況正常不發提醒（規則 1 的 N）');
select test.ok((select spot_id = test.id('sspot') and note = '在機車下睡覺' and reported_by = auth.uid() from public.sightings where id = (:'r'::jsonb ->> 'sighting_id')::uuid),
               '只有一個出沒點時自動帶入餵食點，備註去掉前後空白');
select test.ok((select last_seen_at > now() - interval '1 minute' from public.animals where id = test.id('aH')), '回報後更新最後出現時間');
select test.throws(format($$select public.report_sighting(%L)$$, test.id('aH')), '同一人 10 分鐘內重複回報同一隻被擋下');
select test.ok((select count(*) = 1 and bool_and(reporter_name is not null and spot_name = '哨兵測試點') from public.get_animal_sightings(test.id('aH'))),
               '登入者可查目擊紀錄（含回報者暱稱與餵食點）');

-- =============================================================
-- 2. 規則 1：受傷／跛腳／消瘦立即發健康提醒
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select public.report_sighting(test.id('aH'), 'limping') as r \gset
select test.ok((:'r'::jsonb ->> 'alert_id') is not null and test.alerts('aH', 'health', 'open') = 1, '規則 1：回報跛腳，立即發健康提醒');
select test.ok((select count(*) = 0 from public.animal_alerts), '回報者不是照顧者，看不到提醒內容');
select test.throws(format($$select public.resolve_animal_alert(%L)$$, (:'r'::jsonb ->> 'alert_id')), '不是照顧者不能處理提醒');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select public.report_sighting(test.id('aH'), 'injured', test.id('sspot'), '後腳有傷口') as r2 \gset
select test.ok((:'r2'::jsonb ->> 'alert_id') = (:'r'::jsonb ->> 'alert_id') and test.alerts('aH', 'health') = 1,
               '已有未處理的健康提醒時更新同一則，不重複開');
select test.ok((select count(*) = 0 from public.get_my_animal_alerts()), '別的餵食點的照顧者看不到這則提醒');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select public.report_sighting(test.id('aM'), 'thin') as r3 \gset
select test.ok(test.alerts('aM', 'health', 'open') = 1, '規則 1：回報消瘦，立即發健康提醒');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select count(*) = 2 and bool_and(type = 'health' and spot_name = '哨兵測試點') from public.get_my_animal_alerts()),
               '該點照顧者看得到兩則健康提醒');
select test.ok((select condition = 'injured' and animal_name = '健康貓' from public.get_my_animal_alerts() where animal_id = test.id('aH')),
               '提醒顯示最新一次回報的狀況');
select test.throws(format($$select public.resolve_animal_alert(%L, null, true)$$, (:'r'::jsonb ->> 'alert_id')), '健康提醒不能標記為失蹤');
select public.resolve_animal_alert((:'r'::jsonb ->> 'alert_id')::uuid, ' 已帶去看醫生 ');
select test.ok((select status = 'resolved' and note = '已帶去看醫生' and resolved_by = auth.uid() and resolved_at is not null
                from public.animal_alerts where id = (:'r'::jsonb ->> 'alert_id')::uuid), '照顧者可以把提醒標記為已處理並留備註');
select public.resolve_animal_alert((:'r3'::jsonb ->> 'alert_id')::uuid);

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select count(*) >= 2 from public.get_my_animal_alerts()), '管理員看得到所有提醒');
reset role;
update public.sightings set created_at = created_at - interval '1 hour';

-- =============================================================
-- 3. 規則 2、3、5：門檻 T 的邊界值（沒有目擊紀錄時 T＝3 天）
-- =============================================================
-- 邊界值要用同一個「現在」，所以 3～5 節包在同一個交易裡
begin;
-- 邊界貓：最後出現在 20 天前，19 天前有人在該點餵過
delete from public.sightings where animal_id = test.id('aM');
select test.last_seen('aM', interval '20 days');
select test.last_seen('aH', interval '0');
select test.fed('sspot', interval '19 days');
select test.run_at(interval '17 days');
select test.ok(test.alerts('aM', 'missing') = 0, '規則 5：剛好 3 天（沒有超過 T）不提醒');
select test.run_at(interval '17 days' - interval '1 minute');
select test.ok(test.alerts('aM', 'missing', 'open') = 1, '規則 2：超過 3 天未出現、期間該點有人餵過，發可能失蹤提醒');
select test.ok((select threshold_days = 3.0 and spot_id = test.id('sspot') and last_seen_at < now() - interval '19 days'
                from public.animal_alerts where animal_id = test.id('aM') and type = 'missing'), '提醒記下門檻天數、餵食點與最後出現時間');
select test.run_at(interval '10 days');
select test.ok(test.alerts('aM', 'missing') = 1, '規則 3：已有未處理的提醒，不重複提醒');
select test.ok(test.alerts('aH', 'missing') = 0, '規則 5：最近才出現過的動物不提醒');

-- =============================================================
-- 4. 規則 4：超過 T 但期間該點沒人餵過，不提醒
-- =============================================================
-- 沒人餵貓：最後出現在 18 天前；該點最後一次餵食是 19 天前（在牠最後出現之前）
update public.spot_animals set spot_id = test.id('sspot2') where animal_id = test.id('aN');
select test.last_seen('aN', interval '18 days');
select test.fed('sspot2', interval '19 days');
select test.run_at(interval '5 days');
select test.ok(test.alerts('aN', 'missing') = 0, '規則 4：超過 T 但期間沒人餵過（之前的餵食不算），不提醒');
select test.ok(test.alerts('aM', 'missing') = 1 and test.alerts('aN', 'missing') = 0, '別的餵食點有人餵過不算數');
select test.fed('sspot2', interval '6 days');
select test.run_at(interval '5 days');
select test.ok(test.alerts('aN', 'missing', 'open') = 1, '該點有人餵過之後，下一次檢查就會提醒');

-- =============================================================
-- 5. 門檻 T＝max（3 天，平均出現間隔 × 2）
-- =============================================================
-- 規律貓：25、20、15 天前各被看到一次，平均間隔 5 天，T＝10 天
select test.sighted('aP', interval '25 days'); select test.sighted('aP', interval '20 days'); select test.sighted('aP', interval '15 days');
select test.last_seen('aP', interval '15 days');
select test.fed('sspot', interval '6 days');
select test.ok(private.sentinel_threshold(test.id('aP')) = interval '10 days', '平均間隔 5 天時門檻是 10 天');
select test.run_at(interval '5 days');
select test.ok(test.alerts('aP', 'missing') = 0, '規則 5：剛好 10 天（沒有超過 T）不提醒');
select test.run_at(interval '5 days' - interval '1 minute');
select test.ok(test.alerts('aP', 'missing', 'open') = 1 and (select threshold_days = 10.0 from public.animal_alerts where animal_id = test.id('aP')),
               '規則 2：超過 10 天才提醒，門檻記為 10 天');
-- 循環貓：每天都被看到，平均間隔 1 天，T 仍是 3 天
select test.sighted('aR', interval '12 days'); select test.sighted('aR', interval '11 days'); select test.sighted('aR', interval '10 days');
select test.last_seen('aR', interval '10 days');
select test.ok(private.sentinel_threshold(test.id('aR')) = interval '3 days', '平均間隔很短時門檻不低於 3 天');
-- 已送養貓：不是 active 的動物不檢查
select test.last_seen('aQ', interval '20 days');
update public.animals set status = 'adopted' where id = test.id('aQ');
select test.run_at(interval '0');
select test.ok(test.alerts('aQ', 'missing') = 0, '已送養、已失蹤、已死亡的動物不檢查');
select test.ok(test.alerts('aR', 'missing', 'open') = 1, '循環貓超過 3 天未出現被提醒');
commit;

-- =============================================================
-- 6. 提醒的後續：結案、標記失蹤、再被看到
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.resolve_animal_alert((select id from public.animal_alerts where animal_id = test.id('aR') and type = 'missing'), '可能只是躲起來');
reset role;
select test.run_at(interval '0');
select test.ok(test.alerts('aR', 'missing') = 1, '照顧者結案後，同一次沒出現不會再提醒');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select public.report_sighting(test.id('aM'), 'normal') as r4 \gset
select test.ok((:'r4'::jsonb ->> 'missing_resolved')::int = 1 and test.alerts('aM', 'missing', 'open') = 0, '又被看到時，可能失蹤的提醒自動結案');
select public.report_sighting(test.id('aR')) as r5 \gset
reset role;
select test.ok((select note = '有人回報看到牠，自動結案' from public.animal_alerts where animal_id = test.id('aM') and type = 'missing'), '自動結案會留下說明');
-- 循環貓再次沒出現：算新的一次，會再提醒
update public.sightings set seen_at = seen_at - interval '9 days', created_at = created_at - interval '9 days'
 where id = (:'r5'::jsonb ->> 'sighting_id')::uuid;
select test.last_seen('aR', interval '9 days');
select test.fed('sspot', interval '1 day');
select test.run_at(interval '0');
select test.ok(test.alerts('aR', 'missing') = 2 and test.alerts('aR', 'missing', 'open') = 1, '再被看到之後又沒出現，會發新的提醒');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.resolve_animal_alert((select id from public.animal_alerts where animal_id = test.id('aR') and status = 'open'), null, true);
select test.ok((select status = 'missing' from public.animals where id = test.id('aR')), '照顧者可以在結案時把動物標記為失蹤');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select public.report_sighting(test.id('aR'), 'thin');
select test.ok((select status = 'active' from public.animals where id = test.id('aR')), '失蹤的動物被回報目擊後恢復為正常狀態');
reset role;
select test.ok(test.alerts('aR', 'health', 'open') = 1, '找回來但消瘦，同時發健康提醒');

-- =============================================================
-- 7. 頻率限制、管理員手動執行
-- =============================================================
insert into public.sightings (animal_id, reported_by) select test.id('aQ'), :STRANGER::uuid from generate_series(1, 29);
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.report_sighting(%L)$$, test.id('aP')), '同一人 1 小時內最多回報 30 次');
select test.throws('select public.admin_run_sentinel()', '一般使用者不能手動執行哨兵檢查');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select public.admin_run_sentinel() as run \gset
select test.ok((:'run'::jsonb ->> 'created')::int = 0 and (:'run'::jsonb ->> 'scheduled') is not null, '管理員可手動執行檢查並看到排程狀態');
select test.ok((public.admin_run_sentinel(false) ->> 'created') is null, '只查排程狀態時不執行檢查');
reset role;
select test.ok((select count(*) filter (where source = 'manual') = 1 and count(*) filter (where source = 'test') >= 10 from private.sentinel_runs), '每次檢查都留下執行紀錄');

\echo '階段 5 哨兵測試通過'
