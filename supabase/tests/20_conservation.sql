-- =============================================================
-- 階段 2 測試：保育熱區、三層警示、管理員後台
-- 接在 10_rls_and_rules.sql 之後執行（沿用 test schema 與測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set ADMIN    '''00000000-0000-0000-0000-00000000000a'''
\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set CARE     '''00000000-0000-0000-0000-00000000000c'''
\set USER     '''00000000-0000-0000-0000-00000000000d'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

-- 測試熱區：苗栗淺山一帶的正方形（約 1km x 1.1km），北邊界緯度 24.51
\set SQUARE '''{"type":"Polygon","coordinates":[[[120.80,24.50],[120.81,24.50],[120.81,24.51],[120.80,24.51],[120.80,24.50]]]}'''
-- 蝴蝶結（邊線交叉）
\set BOWTIE '''{"type":"Polygon","coordinates":[[[120.80,24.50],[120.81,24.51],[120.81,24.50],[120.80,24.51],[120.80,24.50]]]}'''
\set ZLAT 24.51
\set ZLNG 120.805

-- =============================================================
-- 1. 熱區繪製權限（FR-3.1）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws(format($$select public.save_conservation_zone('訪客畫的', %L::jsonb)$$, :SQUARE), '訪客不能新增保育熱區');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws(format($$select public.save_conservation_zone('使用者畫的', %L::jsonb)$$, :SQUARE), '一般使用者不能新增保育熱區');
select test.throws($$insert into public.conservation_zones (name, area) values ('直接寫表', 'SRID=4326;POLYGON((120.80 24.50,120.81 24.50,120.81 24.51,120.80 24.51,120.80 24.50))')$$,
                   '一般使用者不能直接寫 conservation_zones');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.throws(format($$select public.save_conservation_zone('照顧者畫的', %L::jsonb)$$, :SQUARE), '照顧者不能新增保育熱區');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.throws(format($$select public.save_conservation_zone('蝴蝶結', %L::jsonb)$$, :BOWTIE), '自我相交的多邊形會被擋下（ST_IsValid）');
select test.throws($$insert into public.conservation_zones (name, area) values ('繞過 RPC', 'SRID=4326;POLYGON((120.80 24.50,120.81 24.51,120.81 24.50,120.80 24.51,120.80 24.50))')$$,
                   '繞過 RPC 直接寫表，自我相交一樣被 CHECK 擋下');
select test.throws($$select public.save_conservation_zone('一個點', '{"type":"Point","coordinates":[120.8,24.5]}'::jsonb)$$, '不是多邊形會被擋下');
select test.throws($$select public.save_conservation_zone('多個多邊形', '{"type":"MultiPolygon","coordinates":[[[[120.80,24.50],[120.81,24.50],[120.81,24.51],[120.80,24.50]]]]}'::jsonb)$$, 'MultiPolygon 會被擋下');
select test.throws($$select public.save_conservation_zone('亂碼', '{"type":"Polygon","coordinates":"x"}'::jsonb)$$, '格式錯誤的 GeoJSON 會被擋下');
select test.throws($$select public.save_conservation_zone('太大', '{"type":"Polygon","coordinates":[[[119,21],[123,21],[123,26],[119,26],[119,21]]]}'::jsonb)$$, '超過 10,000 平方公里會被擋下');
select test.throws(format($$select public.save_conservation_zone('', %L::jsonb)$$, :SQUARE), '名稱不可空白');

insert into test.ids values ('zone', public.save_conservation_zone('  通霄淺山示意區 ', :SQUARE::jsonb, '石虎', '示意用'));
select test.ok((select name = '通霄淺山示意區' and species = '石虎' and is_demo and status = 'active' and created_by = auth.uid()
                from public.conservation_zones where id = test.id('zone')), '管理員可新增保育熱區，預設標示為示意資料');
-- 也接受 Feature 包裝（Leaflet 的 toGeoJSON 輸出）
insert into test.ids values ('zone_far', public.save_conservation_zone('遠方示意區',
  '{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[121.00,24.00],[121.01,24.00],[121.01,24.01],[121.00,24.01],[121.00,24.00]]]}}'::jsonb, '白鼻心'));
select test.ok(test.id('zone_far') is not null, '接受 GeoJSON Feature 包裝');
select test.ok(public.save_conservation_zone('通霄淺山示意區（改）', :SQUARE::jsonb, '石虎', null, false, test.id('zone')) = test.id('zone'),
               '管理員可修改保育熱區');
select test.ok((select name = '通霄淺山示意區（改）' and not is_demo and description is null from public.conservation_zones where id = test.id('zone')),
               '修改後內容正確');
select test.throws(format($$select public.save_conservation_zone('改成蝴蝶結', %L::jsonb, null, null, true, %L)$$, :BOWTIE, test.id('zone')),
                   '修改時自我相交一樣被擋下');
select test.throws(format($$select public.save_conservation_zone('不存在', %L::jsonb, null, null, true, '00000000-0000-0000-0000-0000000000ff')$$, :SQUARE),
                   '修改不存在的熱區會報錯');

-- =============================================================
-- 2. 讀取
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.ok((select count(*) from public.get_conservation_zones()) = 2, '訪客看得到保育熱區');
select test.ok((select geojson ->> 'type' = 'Polygon' and buffer_geojson ->> 'type' = 'Polygon'
                from public.get_conservation_zones() where id = test.id('zone')), '回傳熱區與 200 公尺緩衝帶的 GeoJSON');
select test.throws($$update public.conservation_zones set name = 'x'$$, '訪客不能改保育熱區');
select test.throws($$delete from public.conservation_zones$$, '訪客不能刪保育熱區');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok(test.affects($$update public.conservation_zones set name = 'x'$$) = 0, '一般使用者改不了保育熱區');
select test.ok(test.affects($$delete from public.conservation_zones$$) = 0, '一般使用者刪不了保育熱區');

-- =============================================================
-- 3. 三層警示邊界值（FR-3.2）
-- =============================================================
select test.ok((select level = 'red' and zone_id = test.id('zone') and distance_m = 0
                from public.check_conservation_alert(24.505, :ZLNG)), '範圍內 → red');
select test.ok((select level = 'red' from public.check_conservation_alert(test.north(:ZLAT, -5), :ZLNG)), '邊界內 5 公尺 → red');
select test.ok((select level = 'yellow' and zone_id = test.id('zone') and distance_m between 3 and 7
                from public.check_conservation_alert(test.north(:ZLAT, 5), :ZLNG)), '邊界外 5 公尺 → yellow');
select test.ok((select level = 'yellow' and distance_m between 190 and 200
                from public.check_conservation_alert(test.north(:ZLAT, 195), :ZLNG)), '邊界外 195 公尺 → yellow');
select test.ok((select level = 'none' and zone_id is null and distance_m is null
                from public.check_conservation_alert(test.north(:ZLAT, 206), :ZLNG)), '邊界外 206 公尺 → none');
select test.ok((select count(*) = 1 and bool_and(level = 'none') from public.check_conservation_alert(25.0339, 121.5645)),
               '遠離熱區 → 一樣回傳一列 none');

set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.ok((select level = 'red' from public.check_conservation_alert(24.505, :ZLNG)), '訪客也查得到警示等級');
select test.throws(format($$select * from public.check_spot_conservation_alert(%L)$$, test.id('spot')), '訪客不能查既有餵食點的警示（需精確位置）');

-- 既有餵食點：一個在範圍內、一個在緩衝帶
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('spot_red', public.create_feeding_spot('熱區內的點', 24.505, :ZLNG));
insert into test.ids values ('spot_yellow', public.create_feeding_spot('熱區旁的點', test.north(:ZLAT, 100), :ZLNG));
select test.ok((select level = 'red' from public.check_spot_conservation_alert(test.id('spot_red'))), '動物建檔檢查：熱區內的點 → red');
select test.ok((select level = 'yellow' from public.check_spot_conservation_alert(test.id('spot_yellow'))), '動物建檔檢查：熱區旁的點 → yellow');
select test.ok((select level = 'none' from public.check_spot_conservation_alert(test.id('spot'))), '動物建檔檢查：一般的點 → none');
select test.ok((select count(*) from public.check_spot_conservation_alert('00000000-0000-0000-0000-0000000000ff')) = 0, '不存在的點回傳 0 列');

-- 停用的熱區不再警示，訪客也看不到
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok(test.affects($$update public.conservation_zones set status = 'archived' where id = test.id('zone')$$) = 1, '管理員可停用保育熱區');
set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.ok((select level = 'none' from public.check_conservation_alert(24.505, :ZLNG)), '停用的熱區不再警示');
select test.ok((select count(*) from public.conservation_zones) = 1, '一般使用者看不到停用的熱區');
set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select count(*) from public.conservation_zones) = 2, '管理員看得到停用的熱區');
update public.conservation_zones set status = 'active' where id = test.id('zone');

-- =============================================================
-- 4. 管理員後台（FR-4.1）
-- =============================================================
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws($$select * from public.admin_list_users()$$, '訪客不能看使用者清單');
select test.throws($$select * from public.admin_list_spots()$$, '訪客不能用餵食點管理');

set role authenticated; select set_config('request.jwt.claim.sub', :USER, false);
select test.throws($$select * from public.admin_list_users()$$, '一般使用者不能看使用者清單（含 Email）');
select test.throws($$select * from public.admin_list_spots()$$, '一般使用者不能用餵食點管理');
select test.throws(format($$select public.admin_set_spot_owner(%L, auth.uid())$$, test.id('spot')), '一般使用者不能指派 owner');

set role authenticated; select set_config('request.jwt.claim.sub', :CARE, false);
select test.throws($$select * from public.admin_list_users()$$, '照顧者不能看使用者清單');

set role authenticated; select set_config('request.jwt.claim.sub', :ADMIN, false);
select test.ok((select count(*) from public.admin_list_users()) = 5, '管理員看得到全部使用者');
select test.ok((select email = 'owner@test.tw' from public.admin_list_users('OWNER@')), '可用 Email 搜尋（不分大小寫）');
select test.ok((select count(*) from public.admin_list_users('路人')) = 1, '可用暱稱搜尋');
select test.ok((select count(*) from public.admin_list_users('%')) = 0, '搜尋字串中的 % 不會被當成萬用字元');
select test.ok((select alert_level = 'red' and zone_name is not null and owner_names is not null
                from public.admin_list_spots() where id = test.id('spot_red')), '餵食點管理清單標出落在熱區內的點');
select test.ok((select alert_level = 'none' from public.admin_list_spots('信義') limit 1) is not false, '餵食點管理可搜尋名稱');

select public.set_user_role('00000000-0000-0000-0000-00000000000e', 'admin');
select test.ok((select role = 'admin' from public.profiles where id = '00000000-0000-0000-0000-00000000000e'), '管理員可把使用者設為管理員');
select public.set_user_role('00000000-0000-0000-0000-00000000000e', 'user');
select test.ok((select role = 'user' from public.profiles where id = '00000000-0000-0000-0000-00000000000e'), '管理員可取消別人的管理員');
select test.throws($$select public.set_user_role(auth.uid(), 'user')$$, '最後一位管理員不能被降級');
select test.throws($$select public.set_user_role('00000000-0000-0000-0000-0000000000ff', 'admin')$$, '設定不存在的使用者會報錯');
select test.throws($$select public.set_user_role(auth.uid(), 'superuser')$$, '不接受未定義的角色');

-- 指派 owner：路人原本與該點無關
select public.admin_set_spot_owner(test.id('spot2'), '00000000-0000-0000-0000-00000000000e');
select test.ok(exists (select 1 from public.spot_caretakers where spot_id = test.id('spot2')
                       and user_id = '00000000-0000-0000-0000-00000000000e' and role = 'owner'), '管理員可指派 owner');
select public.admin_set_spot_owner(test.id('spot'), :CARE);
select test.ok((select role = 'owner' from public.spot_caretakers where spot_id = test.id('spot') and user_id = :CARE), '既有照顧者可被升為 owner');
select test.throws($$select public.admin_set_spot_owner('00000000-0000-0000-0000-0000000000ff', auth.uid())$$, '指派到不存在的點會報錯');

-- 刪除
select test.ok(test.affects($$delete from public.conservation_zones where id = test.id('zone_far')$$) = 1, '管理員可刪除保育熱區');

reset role;
\echo '階段 2 測試通過'
