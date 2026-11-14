-- =============================================================
-- 四角色權限與規則自動測試（對照 docs/permission-matrix.md）
-- 任何一項失敗會 raise exception 並中止（run_tests.sh 以 ON_ERROR_STOP 執行）
-- 角色切換：set role anon/authenticated + request.jwt.claim.sub
-- =============================================================
\set QUIET on
set client_min_messages = notice;

create schema test;
grant usage on schema test to anon, authenticated;

create function test.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok - %', label;
end $$;

create function test.throws(sql text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    raise notice 'ok - % （被擋：%）', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL: % —— 應該被擋下卻成功了', label;
end $$;

create function test.affects(sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- 往北偏移 d 公尺的緯度
create function test.north(lat double precision, d double precision) returns double precision
language sql immutable as $$ select lat + d / 111320.0 $$;

create table test.ids (k text primary key, v uuid);
grant all on test.ids to anon, authenticated;
create function test.id(k text) returns uuid language sql stable as $$ select v from test.ids where ids.k = id.k $$;
grant execute on all functions in schema test to anon, authenticated;

-- ---------- 測試帳號 ----------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.tw',    '{"display_name":"管理員"}'),
  ('00000000-0000-0000-0000-00000000000b', 'owner@test.tw',    '{"display_name":"建點者"}'),
  ('00000000-0000-0000-0000-00000000000c', 'care@test.tw',     '{"display_name":"照顧者"}'),
  ('00000000-0000-0000-0000-00000000000d', 'user@test.tw',     '{}'),
  ('00000000-0000-0000-0000-00000000000e', 'stranger@test.tw', '{"display_name":"路人"}');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';

select test.ok((select display_name from public.profiles where id = '00000000-0000-0000-0000-00000000000d') = '使用者0000',
               '註冊時自動建立 profile，沒填暱稱用「使用者＋編號」（不用 email 前綴）');

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

-- 台北 101 附近
\set LAT 25.0339
\set LNG 121.5645

-- =============================================================
-- 1. profiles
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws('select * from public.profiles', '訪客讀不到 profiles');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select count(*) from public.profiles) = 5, '登入者讀得到所有 profiles');
select test.ok(test.affects($$update public.profiles set display_name = '小明' where id = auth.uid()$$) = 1, '本人可改暱稱');
select test.ok(test.affects($$update public.profiles set display_name = '駭客' where id = '00000000-0000-0000-0000-00000000000b'$$) = 0, '不能改別人的暱稱');
select test.throws($$update public.profiles set role = 'admin' where id = auth.uid()$$, '不能把自己升成管理員');
select test.throws($$select public.set_user_role(auth.uid(), 'admin')$$, '一般使用者不能呼叫 set_user_role');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select public.set_user_role('00000000-0000-0000-0000-00000000000e', 'user');
select test.ok(true, '管理員可以呼叫 set_user_role');

-- =============================================================
-- 2. feeding_spots / spot_caretakers
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('spot', public.create_feeding_spot('信義路巷口', :LAT, :LNG, '全家後門左側'));
insert into test.ids values ('spot2', public.create_feeding_spot('公園涼亭', test.north(:LAT, 500), :LNG));
select test.ok(exists (select 1 from public.spot_caretakers where spot_id = test.id('spot') and user_id = auth.uid() and role = 'owner'),
               '建點者自動成為 owner');
select test.throws(format($$insert into public.feeding_spots (name, location, created_by) values ('冒名', 'SRID=4326;POINT(121 25)', %L)$$,
                          '00000000-0000-0000-0000-00000000000d'), '不能冒用別人名義建點');

set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws('select * from public.feeding_spots', '訪客不能直接讀 feeding_spots（看不到精確位置）');
select test.throws($$select public.create_feeding_spot('x', 25, 121)$$, '訪客不能建點');
select test.ok((select count(*) from public.get_map_spots(121.5, 25.0, 121.6, 25.1)) = 2, '訪客用 get_map_spots 看得到地圖上的點');
select test.ok((select bool_and(is_fuzzed) from public.get_map_spots(121.5, 25.0, 121.6, 25.1)), '訪客拿到的位置標記為模糊');
select test.ok((
  select st_distance(st_setsrid(st_makepoint(lng, lat), 4326)::geography,
                     st_setsrid(st_makepoint(:LNG, :LAT), 4326)::geography) between 0.5 and 71
  from public.get_map_spots(121.5, 25.0, 121.6, 25.1) where id = test.id('spot')
), '訪客位置落在 100m 網格中心（偏移 0～71m，不等於原位置）');
select test.ok((
  select count(*) from public.get_map_spots(:LNG - 0.00003, :LAT - 0.00003, :LNG + 0.00003, :LAT + 0.00003)
) = 0, '訪客用極小範圍框住真實位置也查不到（範圍篩選用模糊位置）');
select test.ok((select description is null and is_fuzzed from public.get_spot_summary(test.id('spot'))), '訪客的點摘要不含描述');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((
  select abs(lat - :LAT) < 1e-9 and abs(lng - :LNG) < 1e-9 and not is_fuzzed
  from public.get_map_spots(121.5, 25.0, 121.6, 25.1) where id = test.id('spot')
), '登入者拿到精確位置');
select test.ok((select description = '全家後門左側' from public.get_spot_summary(test.id('spot'))), '登入者看得到描述');

-- 30 公尺重複點（邊界值）
select test.ok((select count(*) from public.find_nearby_spots(test.north(:LAT, 29), :LNG)) = 1, '29m 內有舊點會提示');
select test.ok((select count(*) from public.find_nearby_spots(test.north(:LAT, 31), :LNG)) = 0, '31m 外不提示');

select test.ok(test.affects($$update public.feeding_spots set name = '改名' where id = test.id('spot')$$) = 0, '非照顧者改不了別人的點');
select test.ok(test.affects($$delete from public.feeding_spots where id = test.id('spot')$$) = 0, '一般使用者刪不了點');
select test.throws(format($$insert into public.spot_caretakers (spot_id, user_id) values (%L, %L)$$, test.id('spot'), '00000000-0000-0000-0000-00000000000e'),
                   '不能把別人加成照顧者');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.throws(format($$insert into public.spot_caretakers (spot_id, user_id, role) values (%L, auth.uid(), 'owner')$$, test.id('spot')),
                   '不能自己加入成 owner');
insert into public.spot_caretakers (spot_id, user_id) values (test.id('spot'), auth.uid());
select test.ok(true, '可以自己加入成為照顧者');
select test.ok(test.affects($$update public.feeding_spots set description = '照顧者更新' where id = test.id('spot')$$) = 1, '照顧者可改自己照顧的點');
select test.ok(test.affects($$update public.feeding_spots set description = 'x' where id = test.id('spot2')$$) = 0, '照顧者改不了沒照顧的點');
select test.throws($$update public.feeding_spots set created_by = auth.uid() where id = test.id('spot')$$, '照顧者不能改建立者欄位');
select test.ok(test.affects(format($$update public.spot_caretakers set role = 'owner' where spot_id = %L and user_id = auth.uid()$$, test.id('spot'))) = 0,
               '照顧者不能自己升成 owner');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok(test.affects($$update public.feeding_spots set status = 'active' where id = test.id('spot2')$$) = 1, '管理員可改任何點');

-- =============================================================
-- 3. feeding_logs：記錄餵食、重複投餵、腳印、清理
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select count(*) from public.check_recent_feeding(test.id('spot'))) = 0, '沒人餵過時不提醒');
insert into test.ids values ('client1', gen_random_uuid());
select public.record_feeding(test.id('spot'), 'dry', '一碗乾糧', null, test.id('client1'));
select public.record_feeding(test.id('spot'), 'dry', '一碗乾糧', null, test.id('client1'));
select test.ok((select count(*) from public.feeding_logs where id = test.id('client1')) = 1, '離線補傳重送同一個 client_id 只會有一筆');
select test.ok((select fed_by_name = '小明' and minutes_ago = 0 from public.check_recent_feeding(test.id('spot'))), '2 小時內有人餵過會提醒並顯示是誰');
select test.ok((select footprint = 'fresh' from public.get_map_spots(121.5, 25.0, 121.6, 25.1) where id = test.id('spot')), '剛餵過腳印為 fresh（綠）');
select test.throws(format($$insert into public.feeding_logs (spot_id, user_id) values (%L, %L)$$, test.id('spot'), '00000000-0000-0000-0000-00000000000b'),
                   '不能冒用別人名義記錄餵食');
select test.throws($$select public.record_feeding(test.id('spot'), 'dry', null, now() + interval '1 hour')$$, '不能記錄未來時間');
select test.throws($$select public.record_feeding(test.id('spot'), 'dry', null, now() - interval '8 days')$$, '不能補傳超過 7 天前的紀錄');

-- spot2：只有 2.5 小時前的紀錄 → 不提醒；腳印門檻邊界值
insert into public.feeding_logs (spot_id, fed_at) values (test.id('spot2'), now() - interval '2 hours 30 minutes');
select test.ok((select count(*) from public.check_recent_feeding(test.id('spot2'))) = 0, '2.5 小時前餵過不提醒（超過 2 小時）');
select test.ok((select count(*) from public.check_recent_feeding(test.id('spot2'), 3)) = 1, '提醒時間窗可調整');
select test.ok(private.footprint_status(now() - interval '5 hours 59 minutes') = 'fresh', '5:59 → fresh');
select test.ok(private.footprint_status(now() - interval '6 hours 1 minute') = 'recent', '6:01 → recent');
select test.ok(private.footprint_status(now() - interval '23 hours 59 minutes') = 'recent', '23:59 → recent');
select test.ok(private.footprint_status(now() - interval '24 hours 1 minute') = 'hungry', '24:01 → hungry');
select test.ok(private.footprint_status(null) = 'hungry', '從沒餵過 → hungry');

-- 清理回報
insert into test.ids values ('log_old', (select id from public.feeding_logs where spot_id = test.id('spot2')));
select test.ok((select count(*) from public.get_my_pending_cleanups() where log_id = test.id('log_old')) = 1, '餵食 30 分鐘後出現在待清理清單');
select test.ok((select count(*) from public.get_my_pending_cleanups() where log_id = test.id('client1')) = 0, '剛餵完還不提醒清理');
select public.report_cleanup(test.id('log_old'));
select test.throws($$select public.report_cleanup(test.id('log_old'))$$, '同一筆不能重複回報清理');
select test.throws(format($$update public.feeding_logs set cleaned_at = now(), cleaned_by = %L where id = test.id('client1')$$,
                          '00000000-0000-0000-0000-00000000000b'), '不能用別人名義回報清理');
select test.ok((select clean_rate_30d = 1.000 from public.get_spot_summary(test.id('spot2'))), 'spot2 清理率 100%');
select test.ok((select clean_rate_30d = 0.000 from public.get_spot_summary(test.id('spot'))), 'spot 清理率 0%');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.throws($$select public.report_cleanup(test.id('client1'))$$, '非本人、非照顧者不能回報別人的清理');
select test.ok(test.affects($$delete from public.feeding_logs where id = test.id('client1')$$) = 0, '不能刪別人的餵食紀錄');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select public.report_cleanup(test.id('client1'));
select test.ok((select clean_rate_30d = 1.000 and cleaned_30d = 1 from public.get_spot_summary(test.id('spot'))), '照顧者可幫忙回報自己照顧點的清理，清理率更新');

set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws('select * from public.feeding_logs', '訪客讀不到餵食紀錄明細（看不到誰餵的）');
select test.ok((select feedings_30d = 1 and clean_rate_30d = 1.000 from public.get_spot_summary(test.id('spot'))), '訪客看得到清理率統計');
select test.throws($$select public.record_feeding(test.id('spot'))$$, '訪客不能記錄餵食');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
update public.feeding_spots set status = 'archived' where id = test.id('spot2');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws($$select public.record_feeding(test.id('spot2'))$$, '停用的點不能記錄餵食');
select test.ok((select count(*) from public.get_map_spots(121.5, 25.0, 121.6, 25.1)) = 1, '停用的點不出現在地圖');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
update public.feeding_spots set status = 'active' where id = test.id('spot2');

-- =============================================================
-- 4. animals / spot_animals / animal_photos / storage
-- =============================================================
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
insert into public.animals (name, species, sex) values ('小橘', 'cat', 'male') returning id as animal_id \gset
insert into test.ids values ('animal', :'animal_id');
select test.ok((select not is_sterilized and tnr_stage = 1 and tnr_updated_at is not null from public.animals where id = test.id('animal')),
               '新建動物預設未結紮');
insert into public.spot_animals (spot_id, animal_id) values (test.id('spot'), test.id('animal'));
select test.ok(true, '建檔者可把動物連到餵食點');
select test.throws(format($$insert into public.animals (name, created_by) values ('冒名', %L)$$, '00000000-0000-0000-0000-00000000000b'), '不能冒用別人名義建檔');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.ok(test.affects($$update public.animals set tnr_stage = 3 where id = test.id('animal')$$) = 1, '出沒點的照顧者可更新 TNR 階段');
select test.ok((select is_sterilized from public.animals where id = test.id('animal')), 'TNR 第 3 階段起自動標記已結紮');
select test.ok((select sterilized_count = 1 and animal_count = 1 from public.get_map_spots(121.5, 25.0, 121.6, 25.1) where id = test.id('spot')),
               '地圖上的點顯示結紮數');
select test.throws($$update public.animals set is_sterilized = false where id = test.id('animal')$$, '已結紮標記不能手動改（由階段計算）');

set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
select test.ok(test.affects($$update public.animals set name = '亂改' where id = test.id('animal')$$) = 0, '無關的使用者改不了動物');
select test.ok(test.affects($$delete from public.animals where id = test.id('animal')$$) = 0, '無關的使用者刪不了動物');
select test.throws(format($$insert into public.spot_animals (spot_id, animal_id) values (%L, %L)$$, test.id('spot2'), test.id('animal')),
                   '無關的使用者不能把動物連到點');
select test.throws(format($$insert into public.animal_photos (animal_id, storage_path) values (%L, %L)$$, test.id('animal'), test.id('animal')::text || '/a.webp'),
                   '無關的使用者不能上傳照片紀錄');
select test.throws(format($$insert into storage.objects (bucket_id, name) values ('animal-photos', %L)$$, test.id('animal')::text || '/a.webp'),
                   '無關的使用者不能上傳照片檔');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
insert into storage.objects (bucket_id, name) values ('animal-photos', test.id('animal')::text || '/a.webp');
insert into public.animal_photos (animal_id, storage_path) values (test.id('animal'), test.id('animal')::text || '/a.webp');
select test.ok(true, '建檔者可上傳照片檔與紀錄');
select test.throws($$insert into storage.objects (bucket_id, name) values ('animal-photos', 'not-a-uuid/a.webp')$$, '照片路徑第一層必須是動物 id');
select test.throws(format($$insert into public.animal_photos (animal_id, storage_path) values (%L, 'other/a.webp')$$, test.id('animal')),
                   '照片紀錄路徑必須以動物 id 開頭');
select test.ok(test.affects($$update public.animals set cover_photo_id = (select id from public.animal_photos limit 1) where id = test.id('animal')$$) = 1,
               '可設定封面照片');

set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.ok((select count(*) from public.animals) = 1, '訪客看得到動物身分檔');
select test.ok((select count(*) from public.animal_photos) = 1, '訪客看得到動物照片');
select test.ok((select count(*) from storage.objects where bucket_id = 'animal-photos') = 0, '訪客列不出照片檔（公開網址仍可直接開）');
select test.throws($$insert into public.animals (name) values ('訪客貓')$$, '訪客不能建檔');
select test.throws($$update public.animals set name = 'x'$$, '訪客不能改動物');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok(test.affects($$update public.animals set status = 'active' where id = test.id('animal')$$) = 1, '管理員可改任何動物');

reset role;
\echo '全部測試通過'
