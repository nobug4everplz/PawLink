-- =============================================================
-- 0013 全面審查（2026-11-14）後的修補
--   1. 結紮階段一天只能改一次（每隻動物，臺灣時間；管理員不受限）
--   2. TNR 接力：同一個人一天只能回報同一個案件的一個步驟；
--      發起人與這隻動物的照顧者可以解除別人的認領
--   3. 新增資料時不能自帶建立時間等系統欄位（INSERT 改成欄位層級授權）
--   4. 餵食紀錄不開放直接修改，清理回報一律走 report_cleanup()
-- 照顧者維持自由加入（使用者 2026-11-14 決定）
-- =============================================================

-- -------------------------------------------------------------
-- 1. 結紮階段一天只能改一次
--   只限制前端直接修改（角色 authenticated）。TNR 接力的 RPC 以函式擁有者身分執行，
--   不受這條限制，改由下面第 2 點的「一人一天一步」把關。
-- -------------------------------------------------------------
alter table public.animals add column if not exists tnr_stage_changed_at timestamptz;
comment on column public.animals.tnr_stage_changed_at is '最近一次「修改」結紮階段的時間（建檔不算），用來限制一天只能改一次；前端沒有這一欄的寫入權';

create or replace function private.limit_tnr_stage_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tnr_stage is distinct from old.tnr_stage then
    if current_user = 'authenticated'
       and old.tnr_stage_changed_at is not null
       and (old.tnr_stage_changed_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date
       and not private.is_admin() then
      raise exception '這隻動物的結紮進度今天已經改過了，一天只能改一次，請明天再更新' using errcode = 'P0001';
    end if;
    new.tnr_stage_changed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists animals_limit_tnr_change on public.animals;
create trigger animals_limit_tnr_change
  before update on public.animals
  for each row execute function private.limit_tnr_stage_change();

-- -------------------------------------------------------------
-- 2. TNR 接力
-- -------------------------------------------------------------
-- complete_tnr_task：多一條「同一個人一天只能回報同一個案件的一個步驟」（管理員不受限）
create or replace function public.complete_tnr_task(p_task_id uuid, p_note text default null)
returns smallint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task  public.tnr_tasks;
  v_case  public.tnr_cases;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
  v_stage smallint;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select * into v_task from public.tnr_tasks where id = p_task_id for update;
  if not found then
    raise exception '找不到這個任務' using errcode = 'P0002';
  end if;
  select * into v_case from public.tnr_cases where id = v_task.case_id for update;
  if v_case.status <> 'open' then
    raise exception '這個案件已經結束' using errcode = 'P0001';
  end if;
  if v_task.status <> 'claimed' or v_task.claimed_by is distinct from (select auth.uid()) then
    raise exception '要先認領這個任務才能回報完成' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.tnr_tasks
             where case_id = v_task.case_id and step_no < v_task.step_no and status <> 'done') then
    raise exception '要等前一步完成才能回報這一步' using errcode = 'P0001';
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    raise exception '備註最多 200 字' using errcode = '22023';
  end if;
  if not private.is_admin() and exists (
       select 1 from public.tnr_tasks
       where case_id = v_task.case_id and status = 'done' and claimed_by = (select auth.uid())
         and (done_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date) then
    raise exception '你今天已經回報過這個案件的一個步驟。同一個人一天只能回報一步，請其他人接手或明天再回報' using errcode = 'P0001';
  end if;

  update public.tnr_tasks set status = 'done', done_at = now(), note = coalesce(v_note, note) where id = p_task_id;

  update public.animals
     set tnr_stage = greatest(tnr_stage, v_task.step_no + 1)
   where id = v_case.animal_id
  returning tnr_stage into v_stage;

  if not exists (select 1 from public.tnr_tasks where case_id = v_task.case_id and status <> 'done') then
    update public.tnr_cases set status = 'done', closed_at = now() where id = v_task.case_id;
  end if;
  return v_stage;
end;
$$;

-- unclaim_tnr_task：認領者放棄；發起人、這隻動物的照顧者也可以解除別人的認領（認領後沒有動靜時用）
create or replace function public.unclaim_tnr_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tnr_tasks;
  v_case public.tnr_cases;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select * into v_task from public.tnr_tasks where id = p_task_id for update;
  if not found or v_task.status <> 'claimed' then
    raise exception '這個任務現在沒有人認領中' using errcode = 'P0001';
  end if;
  select * into v_case from public.tnr_cases where id = v_task.case_id;
  if not (v_task.claimed_by is not distinct from (select auth.uid())
          or v_case.opened_by is not distinct from (select auth.uid())
          or private.can_edit_animal(v_case.animal_id)) then
    raise exception '只有認領者、發起人或這隻動物的照顧者可以解除認領' using errcode = '42501';
  end if;
  update public.tnr_tasks set status = 'open', claimed_by = null, claimed_at = null where id = p_task_id;
end;
$$;

revoke all on function public.complete_tnr_task(uuid, text), public.unclaim_tnr_task(uuid) from public, anon, authenticated;
grant execute on function public.complete_tnr_task(uuid, text), public.unclaim_tnr_task(uuid) to authenticated;

-- -------------------------------------------------------------
-- 3. INSERT 改成欄位層級授權：created_at、joined_at、cleaned_at 等系統欄位只能用預設值
--   （原本是整張表授權，直接寫表可以自帶未來的 created_at 與 fed_at，讓餵食點一直顯示「剛餵過」）
-- -------------------------------------------------------------
revoke insert on
  public.feeding_logs, public.feeding_spots, public.animals,
  public.spot_caretakers, public.spot_animals, public.animal_photos
from authenticated;

grant insert (id, spot_id, user_id, fed_at, food_type, note) on public.feeding_logs to authenticated;
grant insert (name, description, location, created_by) on public.feeding_spots to authenticated;
grant insert (name, species, sex, coat, features, ear_tipped, tnr_stage, status, created_by) on public.animals to authenticated;
grant insert (spot_id, user_id, role) on public.spot_caretakers to authenticated;
grant insert (spot_id, animal_id, added_by) on public.spot_animals to authenticated;
grant insert (animal_id, storage_path, caption, uploaded_by) on public.animal_photos to authenticated;

-- -------------------------------------------------------------
-- 4. 餵食紀錄不開放直接修改
--   原本照顧者可以改別人紀錄的備註、把清理時間改成任意值或清掉別人的清理回報
-- -------------------------------------------------------------
revoke update on public.feeding_logs from authenticated;
drop policy if exists "feeding_logs: 本人/照顧者/管理員可清理" on public.feeding_logs;

create or replace function public.report_cleanup(p_log_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  update public.feeding_logs
     set cleaned_at = greatest(now(), fed_at), cleaned_by = (select auth.uid())
   where id = p_log_id and cleaned_at is null
     and (user_id = (select auth.uid()) or private.is_spot_caretaker(spot_id) or private.is_admin())
  returning cleaned_at into v_at;

  if v_at is null then
    raise exception '找不到可回報清理的紀錄（可能已清理或沒有權限）' using errcode = 'P0002';
  end if;
  return v_at;
end;
$$;

revoke all on function public.report_cleanup(uuid) from public, anon, authenticated;
grant execute on function public.report_cleanup(uuid) to authenticated;
