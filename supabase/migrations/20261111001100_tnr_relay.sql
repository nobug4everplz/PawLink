-- =============================================================
-- 階段 5 延伸三：TNR 接力（FR-5.2，M1 處理 3.3）
--   tnr_cases：一隻動物一個進行中的案件
--   tnr_tasks：誘捕、送醫、術後照顧、放回四步，可以由不同人認領
--   四步要依序完成；每完成一步，動物的結紮階段自動往前
--     trap 誘捕 → 2 誘捕中　vet 送醫 → 3 已手術　recovery 術後照顧 → 4 術後照護　release 放回 → 5 已原地回置
-- =============================================================

create table public.tnr_cases (
  id         uuid primary key default gen_random_uuid(),
  animal_id  uuid not null references public.animals (id) on delete cascade,
  status     text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  note       text check (note is null or char_length(note) <= 200),
  opened_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at  timestamptz
);
comment on table public.tnr_cases is 'TNR 接力案件；只能透過 RPC 寫入';
create unique index tnr_cases_one_open_idx on public.tnr_cases (animal_id) where status = 'open';
create index tnr_cases_animal_idx on public.tnr_cases (animal_id, created_at desc);

create table public.tnr_tasks (
  id         uuid primary key default gen_random_uuid(),
  case_id    uuid not null references public.tnr_cases (id) on delete cascade,
  step_no    smallint not null check (step_no between 1 and 4),
  step       text generated always as (
               case step_no when 1 then 'trap' when 2 then 'vet' when 3 then 'recovery' else 'release' end
             ) stored,
  status     text not null default 'open' check (status in ('open', 'claimed', 'done')),
  claimed_by uuid references public.profiles (id) on delete set null,
  claimed_at timestamptz,
  done_at    timestamptz,
  note       text check (note is null or char_length(note) <= 200),
  updated_at timestamptz not null default now(),
  unique (case_id, step_no)
);
comment on table public.tnr_tasks is 'TNR 任務；step：trap 誘捕、vet 送醫、recovery 術後照顧、release 放回';
create index tnr_tasks_claimed_idx on public.tnr_tasks (claimed_by) where status = 'claimed';
create index tnr_tasks_open_idx on public.tnr_tasks (case_id) where status <> 'done';

alter table public.tnr_cases enable row level security;
alter table public.tnr_tasks enable row level security;
revoke all on public.tnr_cases, public.tnr_tasks from anon, authenticated;
grant select on public.tnr_cases, public.tnr_tasks to authenticated;

create policy "tnr_cases: 登入者可讀"
  on public.tnr_cases for select to authenticated using (true);
create policy "tnr_tasks: 登入者可讀"
  on public.tnr_tasks for select to authenticated using (true);

create trigger tnr_cases_set_updated_at before update on public.tnr_cases
  for each row execute function private.set_updated_at();
create trigger tnr_tasks_set_updated_at before update on public.tnr_tasks
  for each row execute function private.set_updated_at();

-- -------------------------------------------------------------
-- open_tnr_case：建立案件。動物已經走到的階段，對應的步驟直接算完成
-- -------------------------------------------------------------
create or replace function public.open_tnr_case(p_animal_id uuid, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stage smallint;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
  v_case  uuid;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select tnr_stage into v_stage from public.animals where id = p_animal_id for update;
  if not found then
    raise exception '找不到這隻動物' using errcode = 'P0002';
  end if;
  if not private.can_edit_animal(p_animal_id) then
    raise exception '只有建檔者或該餵食點的照顧者可以發起 TNR 接力' using errcode = '42501';
  end if;
  if v_stage >= 5 then
    raise exception '這隻動物已經完成結紮並回置' using errcode = 'P0001';
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    raise exception '備註最多 200 字' using errcode = '22023';
  end if;

  begin
    insert into public.tnr_cases (animal_id, note, opened_by)
    values (p_animal_id, v_note, (select auth.uid()))
    returning id into v_case;
  exception when unique_violation then
    raise exception '這隻動物已經有進行中的 TNR 接力' using errcode = 'P0001';
  end;

  insert into public.tnr_tasks (case_id, step_no, status, done_at, note)
  select v_case, n,
         case when n + 1 <= v_stage then 'done' else 'open' end,
         case when n + 1 <= v_stage then now() end,
         case when n + 1 <= v_stage then '發起接力時已經完成' end
  from generate_series(1, 4) n;
  return v_case;
end;
$$;

-- -------------------------------------------------------------
-- cancel_tnr_case：發起人、可編輯這隻動物的人可以取消。動物的結紮階段不變
-- -------------------------------------------------------------
create or replace function public.cancel_tnr_case(p_case_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_case public.tnr_cases;
begin
  select * into v_case from public.tnr_cases where id = p_case_id for update;
  if not found or (select auth.uid()) is null then
    raise exception '找不到這個案件' using errcode = 'P0002';
  end if;
  if not (v_case.opened_by = (select auth.uid()) or private.can_edit_animal(v_case.animal_id)) then
    raise exception '只有發起人或這隻動物的照顧者可以取消' using errcode = '42501';
  end if;
  if v_case.status <> 'open' then
    raise exception '這個案件已經結束' using errcode = 'P0001';
  end if;
  update public.tnr_cases set status = 'cancelled', closed_at = now() where id = p_case_id;
end;
$$;

-- -------------------------------------------------------------
-- claim_tnr_task：認領任務。鎖住這個任務，只有第一位認領者成功
-- -------------------------------------------------------------
create or replace function public.claim_tnr_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tnr_tasks;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select * into v_task from public.tnr_tasks where id = p_task_id for update;
  if not found then
    raise exception '找不到這個任務' using errcode = 'P0002';
  end if;
  if (select status from public.tnr_cases where id = v_task.case_id) <> 'open' then
    raise exception '這個案件已經結束' using errcode = 'P0001';
  end if;
  if v_task.status <> 'open' then
    raise exception '已有人認領' using errcode = 'P0001';
  end if;
  update public.tnr_tasks
     set status = 'claimed', claimed_by = (select auth.uid()), claimed_at = now()
   where id = p_task_id;
end;
$$;

-- unclaim_tnr_task：認領者放棄，任務回到待認領
create or replace function public.unclaim_tnr_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tnr_tasks;
begin
  select * into v_task from public.tnr_tasks where id = p_task_id for update;
  if not found or (select auth.uid()) is null
     or v_task.status <> 'claimed' or v_task.claimed_by is distinct from (select auth.uid()) then
    raise exception '這不是你認領中的任務' using errcode = 'P0001';
  end if;
  update public.tnr_tasks set status = 'open', claimed_by = null, claimed_at = null where id = p_task_id;
end;
$$;

-- -------------------------------------------------------------
-- complete_tnr_task：認領者完成任務。要等前面的步驟都完成；
--   完成後動物的結紮階段自動往前（不會往回），四步都完成時案件結案
-- -------------------------------------------------------------
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

-- -------------------------------------------------------------
-- get_tnr_tasks：任務清單
--   p_animal_id 有值：這隻動物最近一個案件的四個任務
--   沒有值：所有進行中案件的任務（接力看板）
-- -------------------------------------------------------------
create or replace function public.get_tnr_tasks(p_animal_id uuid default null)
returns table (
  task_id      uuid,
  case_id      uuid,
  case_status  text,
  case_note    text,
  opener_name  text,
  animal_id    uuid,
  animal_name  text,
  spot_name    text,
  step_no      smallint,
  step         text,
  status       text,
  claimed_by   uuid,
  claimer_name text,
  note         text,
  done_at      timestamptz,
  is_mine      boolean,
  is_ready     boolean,
  can_manage   boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, c.id, c.status, c.note, o.display_name, a.id, a.name,
         (select s.name from public.spot_animals sa join public.feeding_spots s on s.id = sa.spot_id
          where sa.animal_id = a.id order by sa.added_at limit 1),
         t.step_no, t.step, t.status, t.claimed_by, p.display_name, t.note, t.done_at,
         coalesce(t.claimed_by = (select auth.uid()), false),
         c.status = 'open' and t.status <> 'done' and not exists (
           select 1 from public.tnr_tasks prev
           where prev.case_id = t.case_id and prev.step_no < t.step_no and prev.status <> 'done'),
         c.opened_by = (select auth.uid()) or private.can_edit_animal(a.id)
  from public.tnr_tasks t
  join public.tnr_cases c on c.id = t.case_id
  join public.animals a on a.id = c.animal_id
  left join public.profiles o on o.id = c.opened_by
  left join public.profiles p on p.id = t.claimed_by
  where (select auth.uid()) is not null
    and case when p_animal_id is null then c.status = 'open'
             else c.id = (select id from public.tnr_cases where animal_id = p_animal_id order by created_at desc limit 1) end
  order by c.created_at desc, t.step_no
  limit 400;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  public.open_tnr_case(uuid, text),
  public.cancel_tnr_case(uuid),
  public.claim_tnr_task(uuid),
  public.unclaim_tnr_task(uuid),
  public.complete_tnr_task(uuid, text),
  public.get_tnr_tasks(uuid)
from public, anon, authenticated;

grant execute on function
  public.open_tnr_case(uuid, text),
  public.cancel_tnr_case(uuid),
  public.claim_tnr_task(uuid),
  public.unclaim_tnr_task(uuid),
  public.complete_tnr_task(uuid, text),
  public.get_tnr_tasks(uuid)
to authenticated;
