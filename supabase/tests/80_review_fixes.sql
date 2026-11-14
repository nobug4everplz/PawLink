-- =============================================================
-- 0013 審查修補測試
--   結紮階段一天只能改一次、TNR 接力一人一天一步與解除認領、
--   不能自帶系統欄位、餵食紀錄不能直接修改
-- 接在 10～70 之後執行（沿用 test schema、測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

create function test.changed_at(p_animal text) returns timestamptz language sql volatile security definer as
$$ select tnr_stage_changed_at from public.animals where id = test.id(p_animal) $$;
create function test.task_status(p_case text, p_step text) returns text language sql volatile security definer as
$$ select status from public.tnr_tasks where case_id = test.id(p_case) and step = p_step $$;
grant execute on all functions in schema test to anon, authenticated;

-- =============================================================
-- 1. 結紮階段一天只能改一次
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
with a as (insert into public.animals (name, tnr_stage) values ('一天一次貓', 2), ('接力限制貓', 1) returning id, name)
insert into test.ids select case name when '一天一次貓' then 'rA' else 'rB' end, id from a;
select test.ok(test.changed_at('rA') is null, '建檔不算修改：建檔當天還可以改一次');
select test.ok(test.affects($$update public.animals set tnr_stage = 3 where id = test.id('rA')$$) = 1, '當天第一次修改結紮階段成功');
select test.ok(test.changed_at('rA') is not null, '修改後記下修改時間');
select test.throws($$update public.animals set tnr_stage = 4 where id = test.id('rA')$$, '同一天第二次修改被擋');
select test.throws($$update public.animals set tnr_stage = 1 where id = test.id('rA')$$, '同一天也不能改回去');
select test.ok(test.affects($$update public.animals set coat = '橘白' where id = test.id('rA')$$) = 1, '其他欄位不受限制');
select test.ok(test.affects($$update public.animals set tnr_stage = 3 where id = test.id('rA')$$) = 1, '送出相同的階段不算修改');
select test.throws($$update public.animals set tnr_stage_changed_at = null where id = test.id('rA')$$, '不能自己清掉修改時間');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok(test.affects($$update public.animals set tnr_stage = 4 where id = test.id('rA')$$) = 1, '管理員不受一天一次限制');

-- 隔天（把修改時間往前調一天）就可以再改
reset role;
update public.animals set tnr_stage_changed_at = now() - interval '1 day' where id = test.id('rA');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok(test.affects($$update public.animals set tnr_stage = 5 where id = test.id('rA')$$) = 1, '隔天可以再改一次');
select test.throws($$update public.animals set tnr_stage = 4 where id = test.id('rA')$$, '改完當天又不能再改');
select test.throws($$insert into public.animals (name, tnr_stage_changed_at) values ('x', now())$$, '建檔時不能自帶修改時間');

-- =============================================================
-- 2. TNR 接力：一人一天一步、解除別人的認領
-- =============================================================
insert into test.ids values ('rCase', public.open_tnr_case(test.id('rB')));
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select public.claim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'trap'));
select public.claim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet'));
select test.ok(public.complete_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'trap')) = 2, '第一步回報完成');
select test.throws($$select public.complete_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet'))$$,
                   '同一個人同一天不能在同一個案件回報第二步');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws($$select public.unclaim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet'))$$,
                   '無關的人不能解除別人的認領');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.unclaim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet'));
select test.ok(test.task_status('rCase', 'vet') = 'open', '發起人可以解除別人的認領，任務回到待認領');
select test.throws($$select public.unclaim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'trap'))$$, '已完成的任務不能解除');
select public.claim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet'));
select test.ok(public.complete_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'vet')) = 3,
               '換另一個人當天可以回報下一步（接力不受一天一次的手動修改限制）');
select test.throws($$update public.animals set tnr_stage = 1 where id = test.id('rB')$$, '接力推進過的當天，不能再手動修改');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select public.claim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'recovery'));
select public.claim_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'release'));
select public.complete_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'recovery'));
select test.ok(public.complete_tnr_task((select id from public.tnr_tasks where case_id = test.id('rCase') and step = 'release')) = 5, '管理員不受一人一天一步限制');

-- =============================================================
-- 3. 不能自帶系統欄位
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws($$insert into public.feeding_logs (spot_id, fed_at, created_at) values (test.id('spot'), now() + interval '1 year', now() + interval '1 year')$$,
                   '不能自帶 created_at 把餵食時間填成未來');
select test.throws($$insert into public.feeding_logs (spot_id, cleaned_at, cleaned_by) values (test.id('spot'), now(), auth.uid())$$, '新增時不能直接填清理時間');
select test.throws($$insert into public.feeding_logs (spot_id, fed_at) values (test.id('spot'), now() + interval '1 day')$$, '未來的餵食時間仍被檢查限制擋下');
select test.throws($$insert into public.feeding_spots (name, location, created_at) values ('x', 'SRID=4326;POINT(121.5 25)', now() - interval '1 year')$$, '建點不能自帶 created_at');
select test.throws($$insert into public.spot_caretakers (spot_id, user_id, joined_at) values (test.id('spot2'), auth.uid(), now() - interval '1 year')$$, '加入照顧者不能自帶加入時間');
select test.ok(public.record_feeding(test.id('spot'), 'dry', '0013 測試') is not null, '正常記錄餵食不受影響');
insert into test.ids values ('rLog', (select id from public.feeding_logs where note = '0013 測試'));
select test.ok(test.affects($$insert into public.feeding_logs (spot_id, food_type) values (test.id('spot'), 'wet')$$) = 1, '直接新增（只帶允許的欄位）仍然可以');

-- =============================================================
-- 4. 餵食紀錄不能直接修改，清理只能走 report_cleanup
-- =============================================================
select test.throws($$update public.feeding_logs set note = '亂改' where id = test.id('rLog')$$, '本人也不能直接改餵食紀錄的備註');
select test.throws($$update public.feeding_logs set cleaned_at = now() + interval '1 hour', cleaned_by = auth.uid() where id = test.id('rLog')$$, '不能直接填任意清理時間');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws($$select public.report_cleanup(test.id('rLog'))$$, '非本人、非照顧者不能回報清理');
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws($$select public.report_cleanup(test.id('rLog'))$$, '訪客不能回報清理');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok(public.report_cleanup(test.id('rLog')) is not null, '該點照顧者可以代為回報清理');
select test.throws($$update public.feeding_logs set cleaned_at = null, cleaned_by = null where id = test.id('rLog')$$, '不能清掉別人的清理回報');
select test.throws($$select public.report_cleanup(test.id('rLog'))$$, '同一筆不能重複回報');
reset role;
select test.ok((select cleaned_by = :OWNER::uuid from public.feeding_logs where id = test.id('rLog')), '清理回報記在回報者名下');

\echo '0013 審查修補測試通過'
