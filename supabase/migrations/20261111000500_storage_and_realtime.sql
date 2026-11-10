-- =============================================================
-- 0005 Storage（動物照片）與 Realtime（餵食即時同步，NFR-5）
-- =============================================================

-- -------------------------------------------------------------
-- Bucket：animal-photos（公開讀取，用公開網址顯示）
--   路徑規則：{animal_id}/{任意檔名}.webp
--   單檔上限 2MB，只收 jpeg/png/webp（前端先壓縮並去除 GPS）
-- -------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('animal-photos', 'animal-photos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 路徑第一層轉成 animal_id；格式不對回傳 null（政策就不成立）
create or replace function private.photo_path_animal_id(p_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return (string_to_array(p_name, '/'))[1]::uuid;
exception when others then
  return null;
end;
$$;
grant execute on function private.photo_path_animal_id(text) to anon, authenticated;

create policy "animal-photos: 所有人可讀"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'animal-photos');

create policy "animal-photos: 可編輯該動物者可上傳"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'animal-photos'
    and private.can_edit_animal(private.photo_path_animal_id(name))
  );

create policy "animal-photos: 上傳者或可編輯該動物者可刪除"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'animal-photos'
    and (
      owner_id = (select auth.uid())::text
      or private.can_edit_animal(private.photo_path_animal_id(name))
    )
  );

-- -------------------------------------------------------------
-- Realtime：餵食紀錄新增／清理時推播給登入者（RLS 一樣適用）
--   前端訂閱 postgres_changes: table=feeding_logs
--   訪客沒有 feeding_logs 讀取權，改用定時重新呼叫 get_map_spots()
-- -------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.feeding_logs;
  end if;
end;
$$;
