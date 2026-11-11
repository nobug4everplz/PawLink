-- =============================================================
-- 階段 5 延伸二測試：餵食輪值與代班（處理 2.3、2.4 與代班決策樹）
-- 完成條件：兩人同時認領只有一人成功（第 4 節用兩條連線真的同時送出）
-- 接在 10～40 之後執行（沿用 test schema 與測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

create function test.shift(p_k text) returns public.feeding_shifts language sql security definer as
$$ select f from public.feeding_shifts f where id = test.id(p_k) $$;
create function test.d(p_days int) returns date language sql stable as
$$ select (now() at time zone 'Asia/Taipei')::date + p_days $$;
grant execute on all functions in schema test to anon, authenticated;

-- 準備：兩個餵食點。A：OWNER、CARE、USER 都是照顧者；B：OWNER、CARE 是照顧者。STRANGER 都不是
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('shA', public.create_feeding_spot('輪值測試點 A', 23.7001, 120.7001));
insert into test.ids values ('shB', public.create_feeding_spot('輪值測試點 B', 23.7101, 120.7001));
set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
insert into public.spot_caretakers (spot_id, user_id) values (test.id('shA'), auth.uid()), (test.id('shB'), auth.uid());
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
insert into public.spot_caretakers (spot_id, user_id) values (test.id('shA'), auth.uid());

-- =============================================================
-- 1. 登記輪值（處理 2.3）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(1)), '訪客不能登記輪值');
select test.throws('select * from public.feeding_shifts', '訪客讀不到班表');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(1)), '不是該點照顧者不能登記輪值');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.create_shift(%L, %L, 'noon')$$, test.id('shA'), test.d(1)), '不認得的時段被擋下');
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(-1)), '過去的日期被擋下');
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(31)), '超過 30 天後的日期被擋下');
select test.throws(format($$select public.create_shift('00000000-0000-0000-0000-0000000000ff', %L, 'morning')$$, test.d(1)), '不存在的餵食點被擋下');
select test.throws(format($$insert into public.feeding_shifts (spot_id, shift_date, time_slot) values (%L, %L, 'morning')$$, test.id('shA'), test.d(1)),
                   '不能繞過 RPC 直接寫班表');

insert into test.ids values ('s1', public.create_shift(test.id('shA'), test.d(1), 'morning', '  帶乾糧  '));
select test.ok((select (f).status = 'scheduled' and (f).user_id = auth.uid() and (f).note = '帶乾糧' from test.shift('s1') f), '照顧者可以登記輪值');
select test.ok(public.create_shift(test.id('shA'), test.d(30), 'evening') is not null, '第 30 天還可以登記（邊界）');
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shB'), test.d(1)), '同一人同時段不可重複排班（另一個餵食點也不行）');
select test.ok(public.create_shift(test.id('shB'), test.d(1), 'evening') is not null, '同一天不同時段可以排');
select test.ok(public.create_shift(test.id('shB'), test.d(2), 'morning') is not null, '不同天同時段可以排');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(1)), '同一個點同一時段已有人排班時被擋下');
select test.ok((select count(*) = 4 from public.feeding_shifts), '同一個點的照顧者看得到班表');
select test.throws(format($$update public.feeding_shifts set status = 'done' where id = %L$$, test.id('s1')), '不能直接改班表');
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok((select count(*) = 0 from public.feeding_shifts) and (select count(*) = 0 from public.get_my_shifts()), '不是照顧者看不到班表');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select count(*) = 2 from public.get_my_shifts()), '只看得到自己照顧的點的班（A 點 2 班）');
select test.ok((select count(*) = 1 and bool_and(name = '輪值測試點 A') from public.get_my_shift_spots()), '可登記的餵食點只列出自己照顧的');

-- =============================================================
-- 2. 求代班與收回
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.throws(format($$select public.request_shift_cover(%L)$$, test.id('s1')), '不能替別人的班求代班');
select test.throws(format($$select public.cancel_shift(%L)$$, test.id('s1')), '不能取消別人的班');
select test.throws(format($$select public.claim_shift(%L)$$, test.id('s1')), '決策樹：班次不是求代班，認領被拒（已有人接了）');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.request_shift_cover(test.id('s1'));
select test.ok((select (f).status = 'need_cover' and (f).cover_requested_at is not null from test.shift('s1') f), '排班者可以求代班');
select test.throws(format($$select public.request_shift_cover(%L)$$, test.id('s1')), '已經在求代班時不能重複送出');
select test.throws(format($$select public.claim_shift(%L)$$, test.id('s1')), '不能代自己的班');
select public.request_shift_cover(test.id('s1'), false);
select test.ok((select (f).status = 'scheduled' and (f).cover_requested_at is null from test.shift('s1') f), '還沒人接之前可以收回請求');
select public.request_shift_cover(test.id('s1'));

-- =============================================================
-- 3. 認領代班（決策樹）
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws(format($$select public.claim_shift(%L)$$, test.id('s1')), '不是該點照顧者不能認領');

-- CARE 同一時段在 B 點已有班 → 時段衝突
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.cancel_shift((select id from public.feeding_shifts where spot_id = test.id('shB') and shift_date = test.d(2)));
select test.ok((select count(*) = 3 from public.feeding_shifts), '排班者可以取消自己還沒被代的班');
set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
insert into test.ids values ('s_care', public.create_shift(test.id('shB'), test.d(1), 'morning'));
select test.throws(format($$select public.claim_shift(%L)$$, test.id('s1')), '決策樹：認領者該時段已有其他班，拒絕並提示時段衝突');
select test.ok((select (f).status = 'need_cover' and (f).cover_user_id is null from test.shift('s1') f), '被拒絕後班次維持求代班');
select test.ok((select can_claim and not is_mine from public.get_my_shifts() where id = test.id('s1')), '班表標示這一班可以認領');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select public.claim_shift(test.id('s1'));
select test.ok((select (f).status = 'covered' and (f).cover_user_id = auth.uid() and (f).covered_at is not null from test.shift('s1') f),
               '決策樹：沒有衝突，班次改為已代班並記錄代班者');
select test.ok((select is_my_duty and not is_mine and not can_claim and cover_name is not null from public.get_my_shifts() where id = test.id('s1')), '代班者的班表顯示這一班由自己負責');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select public.cancel_shift(test.id('s_care'));
select test.throws(format($$select public.claim_shift(%L)$$, test.id('s1')), '決策樹：已經被認領，第二個人被拒（已有人接了）');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.ok((select status = 'covered' and cover_name is not null and is_mine and not is_my_duty from public.get_my_shifts() where id = test.id('s1')),
               '原排班者在班表看到已由誰代班（站內通知）');
select test.throws(format($$select public.request_shift_cover(%L, false)$$, test.id('s1')), '已有人接了之後不能收回');
select test.throws(format($$select public.cancel_shift(%L)$$, test.id('s1')), '已有人代班的班不能取消');
select test.ok(public.create_shift(test.id('shB'), test.d(1), 'morning') is not null, '班被代走之後，原排班者同時段可以排別的班');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.create_shift(%L, %L, 'morning')$$, test.id('shA'), test.d(1)), '代班者同時段不能再排別的班');
reset role;

-- =============================================================
-- 4. 兩人同時認領只有一人成功（兩條連線真的同時送出）
-- =============================================================
create extension if not exists dblink;
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('race', public.create_shift(test.id('shA'), test.d(5), 'evening'));
select public.request_shift_cover(test.id('race'));
reset role;

select dblink_connect('c1', 'dbname=' || current_database());
select dblink_connect('c2', 'dbname=' || current_database());
select dblink_exec('c1', 'set role authenticated');
select dblink_exec('c2', 'set role authenticated');
select * from dblink('c1', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :CARE)) as t(x text);
select * from dblink('c2', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :USER)) as t(x text);

-- 先握住這一班的鎖，讓兩個認領都卡在同一個點，再同時放行
begin;
select id from public.feeding_shifts where id = test.id('race') for update;
select dblink_send_query('c1', format('select public.claim_shift(%L)', test.id('race')));
select dblink_send_query('c2', format('select public.claim_shift(%L)', test.id('race')));
select pg_sleep(0.5);
select test.ok((select count(*) = 2 from pg_stat_activity where wait_event_type = 'Lock' and query like '%claim_shift%' and pid <> pg_backend_pid()),
               '兩個認領同時在等同一班');
commit;

create temp table race_result (who text, err text);
do $$
declare v_err text;
begin
  begin
    perform * from dblink_get_result('c1') as t(x text);
    insert into race_result values ('care', null);
  exception when others then insert into race_result values ('care', sqlerrm);
  end;
  begin
    perform * from dblink_get_result('c2') as t(x text);
    insert into race_result values ('user', null);
  exception when others then insert into race_result values ('user', sqlerrm);
  end;
end $$;
select dblink_disconnect('c1'); select dblink_disconnect('c2');

select test.ok((select count(*) filter (where err is null) = 1 and count(*) filter (where err like '%已有人接了%') = 1 from race_result),
               '兩人同時認領：只有一人成功，另一人看到「已有人接了」');
select test.ok((select (f).status = 'covered'
                  and (f).cover_user_id = (select case who when 'care' then :CARE::uuid else :USER::uuid end from race_result where err is null)
                from test.shift('race') f), '班次記錄的代班者就是成功的那一位');

-- 同一個人同時送出兩個同時段的登記，也只有一個成功
select dblink_connect('c1', 'dbname=' || current_database());
select dblink_connect('c2', 'dbname=' || current_database());
select dblink_exec('c1', 'set role authenticated'); select dblink_exec('c2', 'set role authenticated');
select * from dblink('c1', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :CARE)) as t(x text);
select * from dblink('c2', format($$select set_config('request.jwt.claim.sub', %L, false)$$, :CARE)) as t(x text);
select dblink_send_query('c1', format('select pg_sleep(0.3), public.create_shift(%L, %L, %L)', test.id('shA'), test.d(7), 'morning'));
select dblink_send_query('c2', format('select pg_sleep(0.3), public.create_shift(%L, %L, %L)', test.id('shB'), test.d(7), 'morning'));
truncate race_result;
do $$
begin
  begin perform * from dblink_get_result('c1') as t(a text, b text); insert into race_result values ('A', null);
  exception when others then insert into race_result values ('A', sqlerrm); end;
  begin perform * from dblink_get_result('c2') as t(a text, b text); insert into race_result values ('B', null);
  exception when others then insert into race_result values ('B', sqlerrm); end;
end $$;
select dblink_disconnect('c1'); select dblink_disconnect('c2');
select test.ok((select count(*) filter (where err is null) = 1 and count(*) filter (where err like '%已經有班%') = 1 from race_result),
               '同一人同時登記兩個點的同一時段：只有一個成功');

-- =============================================================
-- 5. 完成
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.complete_shift(%L)$$, test.id('s1')), '班被代走後，原排班者不能標記完成');
insert into test.ids values ('today_m', public.create_shift(test.id('shA'), test.d(0), 'morning'));
insert into test.ids values ('today_e', public.create_shift(test.id('shA'), test.d(0), 'evening'));
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.complete_shift(%L)$$, test.id('s1')), '還沒到日期的班不能標記完成');
select test.throws(format($$select public.complete_shift(%L)$$, test.id('today_m')), '不能替別人標記完成');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select public.complete_shift(test.id('today_m'));
select test.ok((select (f).status = 'done' and (f).done_at is not null from test.shift('today_m') f), '負責的人可以標記完成');
select test.throws(format($$select public.request_shift_cover(%L)$$, test.id('today_m')), '已完成的班不能求代班');
select public.record_feeding(test.id('shA'));
select test.ok((select (f).status = 'done' from test.shift('today_e') f), '記錄餵食時自動把自己當天在這個點的班標記完成');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select count(*) >= 6 from public.feeding_shifts), '管理員看得到所有班表');
select public.cancel_shift(test.id('s1'));
select test.ok((select count(*) = 0 from public.feeding_shifts where id = test.id('s1')), '管理員可以刪除已代班的班');
reset role;

\echo '階段 5 輪值代班測試通過'
