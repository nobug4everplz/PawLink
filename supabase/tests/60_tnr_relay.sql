-- =============================================================
-- 階段 5 延伸三測試：TNR 接力（處理 3.3）
-- 完成條件：四步完成後動物結紮階段自動更新
-- 接在 10～50 之後執行（沿用 test schema、測試帳號；50 已建立 dblink）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

create function test.task(p_case text, p_step text) returns uuid language sql stable security definer as
$$ select id from public.tnr_tasks where case_id = test.id(p_case) and step = p_step $$;
create function test.stage(p_animal text) returns smallint language sql volatile security definer as
$$ select tnr_stage from public.animals where id = test.id(p_animal) $$;
grant execute on all functions in schema test to anon, authenticated;

-- 準備：OWNER 建三隻動物（未結紮、已手術、已回置）
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
with a as (insert into public.animals (name, tnr_stage) values ('接力貓', 1), ('手術過的貓', 3), ('回置過的貓', 5) returning id, name)
insert into test.ids select case name when '接力貓' then 'tA' when '手術過的貓' then 'tB' else 'tC' end, id from a;

-- =============================================================
-- 1. 發起接力
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.open_tnr_case(%L)$$, test.id('tA')), '訪客不能發起 TNR 接力');
select test.throws('select * from public.tnr_cases', '訪客讀不到案件');
select test.throws('select * from public.tnr_tasks', '訪客讀不到任務');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.open_tnr_case(%L)$$, test.id('tA')), '不是建檔者或照顧者不能發起接力');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws($$select public.open_tnr_case('00000000-0000-0000-0000-0000000000ff')$$, '不存在的動物被擋下');
select test.throws(format($$select public.open_tnr_case(%L)$$, test.id('tC')), '已經回置的動物不能再發起接力');
insert into test.ids values ('case', public.open_tnr_case(test.id('tA'), '  常在便利商店後門出沒  '));
select test.ok((select count(*) = 4 and bool_and(status = 'open') and array_agg(step order by step_no) = array['trap', 'vet', 'recovery', 'release']
                from public.tnr_tasks where case_id = test.id('case')), '發起後建立誘捕、送醫、術後照顧、放回四個待認領任務');
select test.ok((select note = '常在便利商店後門出沒' and status = 'open' from public.tnr_cases where id = test.id('case')), '案件備註去掉前後空白');
select test.throws(format($$select public.open_tnr_case(%L)$$, test.id('tA')), '同一隻動物同時只能有一個進行中的接力');
select test.throws(format($$insert into public.tnr_cases (animal_id) values (%L)$$, test.id('tB')), '不能繞過 RPC 直接建立案件');
select test.throws(format($$update public.tnr_tasks set status = 'done' where case_id = %L$$, test.id('case')), '不能直接改任務狀態');

insert into test.ids values ('caseB', public.open_tnr_case(test.id('tB')));
select test.ok((select array_agg(status order by step_no) = array['done', 'done', 'open', 'open'] from public.tnr_tasks where case_id = test.id('caseB')),
               '動物已經手術過：誘捕與送醫直接算完成，只剩術後照顧與放回');

-- =============================================================
-- 2. 認領（四步可以由不同人認領）
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok((select count(*) = 8 from public.get_tnr_tasks()), '登入者在接力看板看得到進行中案件的待辦任務（含已完成的步驟）');
select public.claim_tnr_task(test.task('case', 'trap'));
select test.ok((select status = 'claimed' and claimed_by = auth.uid() from public.tnr_tasks where id = test.task('case', 'trap')), '任何登入者都可以認領任務');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.claim_tnr_task(%L)$$, test.task('case', 'trap')), '已有人認領的任務不能再認領');
select test.throws(format($$select public.unclaim_tnr_task(%L)$$, test.task('case', 'trap')), '不能替別人放棄任務');
select test.throws(format($$select public.complete_tnr_task(%L)$$, test.task('case', 'trap')), '不是認領者不能回報完成');
select public.claim_tnr_task(test.task('case', 'vet'));
select public.unclaim_tnr_task(test.task('case', 'vet'));
select test.ok((select status = 'open' and claimed_by is null from public.tnr_tasks where id = test.task('case', 'vet')), '認領者可以放棄，任務回到待認領');
select public.claim_tnr_task(test.task('case', 'vet'));
set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select public.claim_tnr_task(test.task('case', 'recovery'));
select test.ok((select count(distinct claimed_by) = 3 from public.tnr_tasks where case_id = test.id('case')), '三個步驟由三個不同的人認領');
reset role;

-- 兩人同時認領同一個任務，只有一人成功
select dblink_connect('c1', 'dbname=' || current_database());
select dblink_connect('c2', 'dbname=' || current_database());
select dblink_exec('c1', 'set role authenticated'); select dblink_exec('c2', 'set role authenticated');
select * from dblink('c1', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :OWNER)) as t(x text);
select * from dblink('c2', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :ADMIN)) as t(x text);
begin;
select id from public.tnr_tasks where id = test.task('case', 'release') for update;
select dblink_send_query('c1', format('select public.claim_tnr_task(%L)', test.task('case', 'release')));
select dblink_send_query('c2', format('select public.claim_tnr_task(%L)', test.task('case', 'release')));
select pg_sleep(0.5);
commit;
create temp table tnr_race (who text, err text);
do $$
begin
  begin perform * from dblink_get_result('c1') as t(x text); insert into tnr_race values ('owner', null);
  exception when others then insert into tnr_race values ('owner', sqlerrm); end;
  begin perform * from dblink_get_result('c2') as t(x text); insert into tnr_race values ('admin', null);
  exception when others then insert into tnr_race values ('admin', sqlerrm); end;
end $$;
select dblink_disconnect('c1'); select dblink_disconnect('c2');
select test.ok((select count(*) filter (where err is null) = 1 and count(*) filter (where err like '%已有人認領%') = 1 from tnr_race),
               '兩人同時認領同一個任務：只有一人成功');
-- 之後的測試讓 OWNER 負責放回
update public.tnr_tasks set claimed_by = :OWNER::uuid where id = test.task('case', 'release');

-- =============================================================
-- 3. 依序完成，結紮階段自動更新
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.complete_tnr_task(%L)$$, test.task('case', 'vet')), '誘捕還沒完成，不能先回報送醫');
select test.ok((select not is_ready from public.get_tnr_tasks(test.id('tA')) where step = 'vet')
           and (select is_ready from public.get_tnr_tasks(test.id('tA')) where step = 'trap'), '看板標示目前輪到哪一步');
select test.ok(test.stage('tA') = 1, '還沒有任何步驟完成時，結紮階段不變');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok(public.complete_tnr_task(test.task('case', 'trap'), ' 用誘捕籠抓到了 ') = 2 and test.stage('tA') = 2, '誘捕完成：結紮階段自動變成 2 誘捕中');
select test.ok((select status = 'done' and done_at is not null and note = '用誘捕籠抓到了' from public.tnr_tasks where id = test.task('case', 'trap')), '任務記下完成時間與備註');
select test.throws(format($$select public.complete_tnr_task(%L)$$, test.task('case', 'trap')), '已完成的任務不能重複回報');
select test.throws(format($$select public.unclaim_tnr_task(%L)$$, test.task('case', 'trap')), '已完成的任務不能放棄');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok(public.complete_tnr_task(test.task('case', 'vet')) = 3, '送醫完成：結紮階段自動變成 3 已手術');
select test.ok((select is_sterilized and tnr_updated_at > now() - interval '1 minute' from public.animals where id = test.id('tA')), '已手術起自動標記已結紮');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.complete_tnr_task(%L)$$, test.task('case', 'release')), '術後照顧還沒完成，不能先回報放回');
set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.ok(public.complete_tnr_task(test.task('case', 'recovery')) = 4, '術後照顧完成：結紮階段自動變成 4 術後照護');
select test.ok((select status = 'open' from public.tnr_cases where id = test.id('case')), '還有步驟沒完成時案件維持進行中');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok(public.complete_tnr_task(test.task('case', 'release')) = 5 and test.stage('tA') = 5, '四步都完成：結紮階段自動變成 5 已原地回置');
select test.ok((select status = 'done' and closed_at is not null from public.tnr_cases where id = test.id('case')), '四步都完成後案件自動結案');
select test.ok((select count(*) = 4 and bool_and(case_status = 'done' and status = 'done') from public.get_tnr_tasks(test.id('tA'))), '身分檔看得到已結案的接力紀錄');
select test.ok((select count(*) = 4 and bool_and(animal_name = '手術過的貓') from public.get_tnr_tasks()), '結案的案件不再出現在接力看板');
select test.throws(format($$select public.open_tnr_case(%L)$$, test.id('tA')), '完成回置之後不能再發起接力');

-- 階段不會往回：照顧者先手動把階段改到 4，再完成較前面的步驟
select public.claim_tnr_task(test.task('caseB', 'recovery'));
update public.animals set tnr_stage = 5 where id = test.id('tB');
select test.ok(public.complete_tnr_task(test.task('caseB', 'recovery')) = 5, '完成較前面的步驟不會把結紮階段往回調');
update public.animals set tnr_stage = 4 where id = test.id('tB');

-- =============================================================
-- 4. 取消
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select public.claim_tnr_task(test.task('caseB', 'release'));
select test.throws(format($$select public.cancel_tnr_case(%L)$$, test.id('caseB')), '不是發起人或照顧者不能取消案件');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.cancel_tnr_case(test.id('caseB'));
select test.ok((select status = 'cancelled' and closed_at is not null from public.tnr_cases where id = test.id('caseB')) and test.stage('tB') = 4,
               '發起人可以取消案件，動物的結紮階段不變');
select test.throws(format($$select public.cancel_tnr_case(%L)$$, test.id('caseB')), '已結束的案件不能再取消');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.complete_tnr_task(%L)$$, test.task('caseB', 'release')), '案件取消後不能再回報完成');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.claim_tnr_task(%L)$$, test.task('caseB', 'recovery')), '案件取消後不能再認領');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('caseB2', public.open_tnr_case(test.id('tB')));
select test.ok((select array_agg(status order by step_no) = array['done', 'done', 'done', 'open'] from public.tnr_tasks where case_id = test.id('caseB2')),
               '取消後可以重新發起，依目前階段只剩放回');
select test.ok((select bool_and(can_manage) from public.get_tnr_tasks(test.id('tB'))), '發起人在任務清單上有管理權');
reset role;

\echo '階段 5 TNR 接力測試通過'
