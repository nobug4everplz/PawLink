-- =============================================================
-- 審查低嚴重度修補（2026-11-14 審查報告 L1、L2、L6、L8）
--   L1 新增動物改成單一函式（同一筆交易，不再留下沒有餵食點的動物）
--   L2 每隻動物照片上限 10 張；動物照片 bucket 不再允許訪客列出檔案
--   L6 新使用者沒填暱稱時不再用 Email 前綴
--   L8 已完成的領養不能再被取消
-- 全部可重複執行。
-- =============================================================

-- L1 ------------------------------------------------------------
-- security invoker：沿用 animals / spot_animals 既有的 RLS，權限規則不變
create or replace function public.create_animal(
  p_spot_id   uuid,
  p_name      text,
  p_species   text default 'cat',
  p_sex       text default 'unknown',
  p_coat      text default null,
  p_features  text default null,
  p_ear_tipped boolean default false,
  p_tnr_stage smallint default 1
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.animals (name, species, sex, coat, features, ear_tipped, tnr_stage)
  values (p_name, p_species, p_sex, p_coat, p_features, coalesce(p_ear_tipped, false), coalesce(p_tnr_stage, 1))
  returning id into v_id;
  insert into public.spot_animals (spot_id, animal_id) values (p_spot_id, v_id);
  return v_id;
end;
$$;
revoke all on function public.create_animal(uuid, text, text, text, text, text, boolean, smallint) from public, anon;
grant execute on function public.create_animal(uuid, text, text, text, text, text, boolean, smallint) to authenticated;

-- L2 ------------------------------------------------------------
create or replace function private.limit_animal_photos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.animals where id = new.animal_id for update;
  if (select count(*) from public.animal_photos where animal_id = new.animal_id) >= 10 then
    raise exception '每隻動物最多 10 張照片' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function private.limit_animal_photos() from public, anon, authenticated;
drop trigger if exists animal_photos_limit on public.animal_photos;
create trigger animal_photos_limit
  before insert on public.animal_photos
  for each row execute function private.limit_animal_photos();

-- 公開 bucket 的檔案網址不需要 SELECT 政策；拿掉訪客的列表權限，只留登入者
drop policy if exists "animal-photos: 所有人可讀" on storage.objects;
create policy "animal-photos: 登入者可讀"
  on storage.objects for select to authenticated
  using (bucket_id = 'animal-photos');

-- L6 ------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(
      coalesce(
        nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
        '使用者' || substr(replace(new.id::text, '-', ''), 1, 4)
      ),
      30
    )
  );
  return new;
end;
$$;

-- L8 ------------------------------------------------------------
create or replace function public.cancel_adoption(p_adoption_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ad public.adoptions;
begin
  select * into v_ad from public.adoptions where id = p_adoption_id for update;
  if not found or (select auth.uid()) is null then
    raise exception '找不到這筆領養登記' using errcode = 'P0002';
  end if;
  if not (v_ad.adopter_id = (select auth.uid())
          or v_ad.buddy_id is not distinct from (select auth.uid())
          or private.can_edit_animal(v_ad.animal_id)) then
    raise exception '只有領養人、陪伴者或這隻動物的照顧者可以取消' using errcode = '42501';
  end if;
  if v_ad.status = 'cancelled' then
    raise exception '這筆登記已經取消了' using errcode = 'P0001';
  end if;
  if v_ad.status = 'completed' then
    raise exception '已完成的領養不能取消' using errcode = 'P0001';
  end if;
  update public.adoptions set status = 'cancelled', closed_at = now() where id = p_adoption_id;
  if v_ad.status <> 'pending' then
    update public.animals set status = 'active' where id = v_ad.animal_id and status = 'adopted';
  end if;
end;
$$;
