-- =============================================================
-- 審查低嚴重度修補測試（L1 單一交易建動物、L2 照片上限、L6 預設暱稱、L8 完成的領養不可取消）
-- 接在 10～70 之後執行（沿用 test schema、測試帳號）
-- =============================================================
\set QUIET on
set client_min_messages = notice;

\set OWNER    '''00000000-0000-0000-0000-00000000000b'''
\set STRANGER '''00000000-0000-0000-0000-00000000000e'''

-- L1 ------------------------------------------------------------
set role anon; select set_config('request.jwt.claim.sub', '', false);
select test.throws($$select public.create_animal('00000000-0000-0000-0000-0000000000ff', 'x')$$, '訪客不能建立動物');

set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
insert into test.ids values ('lfSpot', public.create_feeding_spot('低嚴重度測試點', 25.0330, 121.5654, null));
insert into test.ids values ('lfAnimal', public.create_animal(test.id('lfSpot'), '單一交易貓', 'cat', 'female', null, null, true, 3::smallint));
select test.ok((select tnr_stage = 3 and ear_tipped and created_by = :OWNER::uuid from public.animals where id = test.id('lfAnimal')), 'create_animal 建出動物並帶入欄位');
select test.ok((select count(*) = 1 from public.spot_animals where animal_id = test.id('lfAnimal') and spot_id = test.id('lfSpot')), 'create_animal 同時建立餵食點關聯');

select test.throws($$select public.create_animal('00000000-0000-0000-0000-0000000000ff', '孤兒貓')$$, '餵食點不存在時整筆失敗');
select test.ok((select count(*) = 0 from public.animals where name = '孤兒貓'), '失敗時沒有留下沒有餵食點的動物');

-- L2 ------------------------------------------------------------
do $$
declare i int; a uuid := test.id('lfAnimal');
begin
  for i in 1..10 loop
    insert into public.animal_photos (animal_id, storage_path) values (a, a::text || '/p' || i || '.jpg');
  end loop;
end $$;
select test.throws(format($$insert into public.animal_photos (animal_id, storage_path) values (%L, %L)$$, test.id('lfAnimal'), test.id('lfAnimal')::text || '/p11.jpg'), '第 11 張照片被擋下');

-- L6 ------------------------------------------------------------
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f6', 'secret.name@example.com');
select test.ok((select display_name !~ 'secret' and display_name like '使用者%' from public.profiles where id = '00000000-0000-0000-0000-0000000000f6'), '沒填暱稱時不使用 Email 前綴');

-- L8 ------------------------------------------------------------
set role authenticated; select set_config('request.jwt.claim.sub', :STRANGER, false);
insert into test.ids values ('lfAd', public.register_adoption(test.id('lfAnimal')));
reset role;
update public.adoptions set status = 'completed' where id = test.id('lfAd');
set role authenticated; select set_config('request.jwt.claim.sub', :OWNER, false);
select test.throws(format($$select public.cancel_adoption(%L)$$, test.id('lfAd')), '已完成的領養不能取消');
reset role;

\echo '低嚴重度修補測試通過'
