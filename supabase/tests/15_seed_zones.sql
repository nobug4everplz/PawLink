-- =============================================================
-- 預設保育熱區（0008 資料）檢查
-- 接在 10_rls_and_rules.sql 之後執行；檢查完會刪掉預設熱區，
-- 讓 20_conservation.sql 從空的熱區表開始測
-- =============================================================
\set QUIET on
set client_min_messages = notice;
reset role; select set_config('request.jwt.claim.sub', '', false);

select test.ok((select count(*) from public.conservation_zones) = 5, '預設保育熱區共 5 處');
select test.ok((select bool_and(is_demo and status = 'active') from public.conservation_zones), '預設熱區全部標為示意資料且啟用');
select test.ok((select bool_and(extensions.st_isvalid(area::extensions.geometry) and extensions.st_npoints(area::extensions.geometry) <= 500
                                and extensions.st_area(area) < 10000e6) from public.conservation_zones),
               '預設熱區都是合法多邊形，頂點與面積在後台限制內');
select test.ok((select count(*) from public.conservation_zones where species = '石虎') = 3, '石虎熱區 3 處');

-- 重跑 migration 不會重複新增
\ir ../migrations/20261111000810_seed_conservation_zones.sql
select test.ok((select count(*) from public.conservation_zones) = 5, '重複執行 0008 不會重複新增');

set role anon;
select test.ok((select count(*) from public.get_conservation_zones()) = 5, '訪客看得到 5 處預設熱區');
select test.ok((select level = 'red' and species = '石虎' from public.check_conservation_alert(24.4390, 120.6525)), '苑裡市區 → red（苗栗熱區）');
select test.ok((select level = 'red' and species = '石虎' from public.check_conservation_alert(24.2580, 120.8280)), '東勢 → red（臺中熱區）');
select test.ok((select level = 'red' and species = '石虎' from public.check_conservation_alert(23.8290, 120.7850)), '集集 → red（南投熱區）');
select test.ok((select level = 'red' and species = '歐亞水獺' from public.check_conservation_alert(24.4640, 118.2980)), '金門慈湖 → red（水獺熱區）');
select test.ok((select level = 'red' and species = '臺灣穿山甲' from public.check_conservation_alert(25.0145, 121.5585)), '富陽公園 → red（穿山甲熱區）');
select test.ok((select level = 'none' from public.check_conservation_alert(25.0339, 121.5645)), '臺北 101 → none');
select test.ok((select level = 'none' from public.check_conservation_alert(25.0136, 121.5415)), '臺科大 → none');
select test.ok((select level = 'none' from public.check_conservation_alert(24.5600, 120.8200)), '苗栗市區 → none（不在熱區內）');

reset role;
delete from public.conservation_zones;
