-- =============================================================
-- 0003 第一版 RLS（FR-4.1、NFR-1）
-- 四角色：
--   訪客 anon         ：唯讀；餵食點只能經 get_map_spots()/get_spot_summary() 取得模糊位置
--   一般使用者        ：authenticated，可新增餵食點、餵食紀錄、動物
--   照顧者            ：authenticated 且在 spot_caretakers 內，可改自己照顧的點與其動物
--   管理員            ：profiles.role = 'admin'，全部可改
-- 作法：先收回 Supabase 預設給 anon/authenticated 的全部權限，再逐一授權
--      （GRANT 決定能碰哪些表/欄位，RLS 決定能碰哪些列）。
-- 對照表見 docs/permission-matrix.md
-- =============================================================

-- -------------------------------------------------------------
-- Helper（security definer 才能在政策中查 profiles/spot_caretakers 而不遞迴）
-- -------------------------------------------------------------
create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

create or replace function private.is_spot_caretaker(p_spot_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.spot_caretakers
    where spot_id = p_spot_id and user_id = (select auth.uid())
  );
$$;

create or replace function private.is_spot_owner(p_spot_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.spot_caretakers
    where spot_id = p_spot_id and user_id = (select auth.uid()) and role = 'owner'
  );
$$;

-- 可編輯動物：管理員、建檔者、或該動物出沒點的照顧者
create or replace function private.can_edit_animal(p_animal_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin()
      or exists (
        select 1 from public.animals
        where id = p_animal_id and created_by = (select auth.uid())
      )
      or exists (
        select 1
        from public.spot_animals sa
        join public.spot_caretakers sc on sc.spot_id = sa.spot_id
        where sa.animal_id = p_animal_id and sc.user_id = (select auth.uid())
      );
$$;

revoke all on all functions in schema private from public;
grant execute on function
  private.is_admin(),
  private.is_spot_caretaker(uuid),
  private.is_spot_owner(uuid),
  private.can_edit_animal(uuid)
to anon, authenticated;

-- -------------------------------------------------------------
-- 收回預設權限
-- -------------------------------------------------------------
revoke all on
  public.profiles, public.feeding_spots, public.spot_caretakers, public.feeding_logs,
  public.animals, public.spot_animals, public.animal_photos
from anon, authenticated;

-- =============================================================
-- profiles
-- =============================================================
grant select on public.profiles to authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;   -- role 不可自己改

create policy "profiles: 登入者可讀"
  on public.profiles for select to authenticated
  using (true);

create policy "profiles: 本人可改自己的暱稱與頭像"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- =============================================================
-- feeding_spots（訪客無直接權限）
-- =============================================================
grant select, insert, delete on public.feeding_spots to authenticated;
grant update (name, description, location, status) on public.feeding_spots to authenticated;

create policy "feeding_spots: 登入者可讀"
  on public.feeding_spots for select to authenticated
  using (true);

create policy "feeding_spots: 登入者可新增（建立者須為本人）"
  on public.feeding_spots for insert to authenticated
  with check (created_by = (select auth.uid()));

create policy "feeding_spots: 照顧者或管理員可修改"
  on public.feeding_spots for update to authenticated
  using (private.is_spot_caretaker(id) or private.is_admin())
  with check (private.is_spot_caretaker(id) or private.is_admin());

create policy "feeding_spots: 只有管理員可刪除"
  on public.feeding_spots for delete to authenticated
  using (private.is_admin());

-- =============================================================
-- spot_caretakers（訪客無權限）
-- =============================================================
grant select, insert, delete on public.spot_caretakers to authenticated;
grant update (role) on public.spot_caretakers to authenticated;

create policy "spot_caretakers: 登入者可讀"
  on public.spot_caretakers for select to authenticated
  using (true);

create policy "spot_caretakers: 自己加入或管理員代加"
  on public.spot_caretakers for insert to authenticated
  with check (
    (user_id = (select auth.uid()) and role = 'caretaker')
    or private.is_admin()
  );

create policy "spot_caretakers: 該點 owner 或管理員可調整角色"
  on public.spot_caretakers for update to authenticated
  using (private.is_spot_owner(spot_id) or private.is_admin())
  with check (private.is_spot_owner(spot_id) or private.is_admin());

create policy "spot_caretakers: 自己退出；owner 或管理員可移除"
  on public.spot_caretakers for delete to authenticated
  using (
    user_id = (select auth.uid())
    or private.is_spot_owner(spot_id)
    or private.is_admin()
  );

-- =============================================================
-- feeding_logs（訪客只能透過 RPC 看彙總，看不到誰餵的）
-- =============================================================
grant select, insert, delete on public.feeding_logs to authenticated;
grant update (note, cleaned_at, cleaned_by) on public.feeding_logs to authenticated;

create policy "feeding_logs: 登入者可讀"
  on public.feeding_logs for select to authenticated
  using (true);

create policy "feeding_logs: 登入者記錄餵食（本人）"
  on public.feeding_logs for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.feeding_spots s
      where s.id = spot_id and s.status = 'active'
    )
  );

create policy "feeding_logs: 本人/照顧者/管理員可清理"
  on public.feeding_logs for update to authenticated
  using (
    user_id = (select auth.uid())
    or private.is_spot_caretaker(spot_id)
    or private.is_admin()
  )
  with check (
    (cleaned_by is null or cleaned_by = (select auth.uid()) or private.is_admin())
  );

create policy "feeding_logs: 本人或管理員可刪除"
  on public.feeding_logs for delete to authenticated
  using (user_id = (select auth.uid()) or private.is_admin());

-- =============================================================
-- animals（訪客可讀；身分檔本身不含位置）
-- =============================================================
grant select on public.animals to anon, authenticated;
grant insert, delete on public.animals to authenticated;
grant update (name, species, sex, coat, features, ear_tipped, tnr_stage, status, cover_photo_id)
  on public.animals to authenticated;

create policy "animals: 所有人可讀"
  on public.animals for select to anon, authenticated
  using (true);

create policy "animals: 登入者可建檔（建檔者須為本人）"
  on public.animals for insert to authenticated
  with check (created_by = (select auth.uid()));

create policy "animals: 建檔者、出沒點照顧者、管理員可修改"
  on public.animals for update to authenticated
  using (private.can_edit_animal(id))
  with check (private.can_edit_animal(id));

create policy "animals: 建檔者或管理員可刪除"
  on public.animals for delete to authenticated
  using (created_by = (select auth.uid()) or private.is_admin());

-- =============================================================
-- spot_animals
-- =============================================================
grant select on public.spot_animals to anon, authenticated;
grant insert, delete on public.spot_animals to authenticated;

create policy "spot_animals: 所有人可讀"
  on public.spot_animals for select to anon, authenticated
  using (true);

create policy "spot_animals: 該點照顧者、動物可編輯者可連結"
  on public.spot_animals for insert to authenticated
  with check (
    added_by = (select auth.uid())
    and (private.is_spot_caretaker(spot_id) or private.can_edit_animal(animal_id))
  );

create policy "spot_animals: 連結者/照顧者/管理員可解除"
  on public.spot_animals for delete to authenticated
  using (
    added_by = (select auth.uid())
    or private.is_spot_caretaker(spot_id)
    or private.is_admin()
  );

-- =============================================================
-- animal_photos
-- =============================================================
grant select on public.animal_photos to anon, authenticated;
grant insert, delete on public.animal_photos to authenticated;
grant update (caption) on public.animal_photos to authenticated;

create policy "animal_photos: 所有人可讀"
  on public.animal_photos for select to anon, authenticated
  using (true);

create policy "animal_photos: 可編輯該動物者可上傳"
  on public.animal_photos for insert to authenticated
  with check (uploaded_by = (select auth.uid()) and private.can_edit_animal(animal_id));

create policy "animal_photos: 上傳者或可編輯該動物者可改說明"
  on public.animal_photos for update to authenticated
  using (uploaded_by = (select auth.uid()) or private.can_edit_animal(animal_id))
  with check (uploaded_by = (select auth.uid()) or private.can_edit_animal(animal_id));

create policy "animal_photos: 上傳者或可編輯該動物者可刪除"
  on public.animal_photos for delete to authenticated
  using (uploaded_by = (select auth.uid()) or private.can_edit_animal(animal_id));
