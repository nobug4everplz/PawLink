-- =============================================================
-- 階段 5 延伸二：餵食輪值與代班（FR-5.1，M1 處理 2.3、2.4 與代班決策樹）
--   feeding_shifts：班表。一個餵食點同一天同一時段只有一班
--   同一人同一天同一時段不能有兩班（自己排的或代別人的都算）
--   代班認領：只有第一位認領者成功
--
-- 代班決策樹
--   班次狀態＝求代班？
--   ├─ 否 → 顯示「已有人接了」
--   └─ 是 → 認領者該時段已有其他班？
--            ├─ 是 → 拒絕，提示時段衝突
--            └─ 否 → 班次狀態改為「已代班」，記錄代班者，通知原排班者
-- =============================================================

create table public.feeding_shifts (
  id                 uuid primary key default gen_random_uuid(),
  spot_id            uuid not null references public.feeding_spots (id) on delete cascade,
  user_id            uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  cover_user_id      uuid references public.profiles (id) on delete set null,
  shift_date         date not null,
  time_slot          text not null check (time_slot in ('morning', 'evening')),
  status             text not null default 'scheduled' check (status in ('scheduled', 'need_cover', 'covered', 'done')),
  note               text check (note is null or char_length(note) <= 100),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  cover_requested_at timestamptz,
  covered_at         timestamptz,
  done_at            timestamptz,
  constraint feeding_shifts_one_per_slot unique (spot_id, shift_date, time_slot),
  constraint feeding_shifts_cover_not_self check (cover_user_id is null or cover_user_id <> user_id)
);
comment on table public.feeding_shifts is '餵食輪值；只能透過 RPC 寫入';
comment on column public.feeding_shifts.time_slot is 'morning 早上、evening 晚上';
comment on column public.feeding_shifts.status is 'scheduled 已排班、need_cover 求代班、covered 已代班、done 已完成';
comment on column public.feeding_shifts.cover_user_id is '代班者；有值時這一班由代班者負責';

create index feeding_shifts_date_idx on public.feeding_shifts (shift_date, spot_id);
create index feeding_shifts_user_idx on public.feeding_shifts (user_id, shift_date);
create index feeding_shifts_cover_idx on public.feeding_shifts (cover_user_id, shift_date) where cover_user_id is not null;

alter table public.feeding_shifts enable row level security;
revoke all on public.feeding_shifts from anon, authenticated;
grant select on public.feeding_shifts to authenticated;

create policy "feeding_shifts: 該點照顧者與管理員可讀"
  on public.feeding_shifts for select to authenticated
  using (private.is_admin() or private.is_spot_caretaker(spot_id));

create trigger feeding_shifts_set_updated_at
  before update on public.feeding_shifts
  for each row execute function private.set_updated_at();

-- 今天的日期一律用臺灣時間
create or replace function private.today_tw()
returns date
language sql
stable
set search_path = ''
as $$ select (now() at time zone 'Asia/Taipei')::date $$;

-- 這個人在這一天這個時段是不是已經有班（自己排的而且沒人代，或是代別人的）
create or replace function private.has_shift(p_user_id uuid, p_date date, p_slot text, p_except uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.feeding_shifts
    where shift_date = p_date and time_slot = p_slot
      and (p_except is null or id <> p_except)
      and ((user_id = p_user_id and cover_user_id is null) or cover_user_id = p_user_id)
  );
$$;

-- 同一個人同一天同一時段的操作排隊執行，避免同時送出兩筆都通過檢查
create or replace function private.lock_user_slot(p_user_id uuid, p_date date, p_slot text)
returns void
language sql
set search_path = ''
as $$ select pg_advisory_xact_lock(hashtextextended(p_user_id::text || p_date::text || p_slot, 0)) $$;

-- -------------------------------------------------------------
-- create_shift：登記輪值（處理 2.3）
-- -------------------------------------------------------------
create or replace function public.create_shift(
  p_spot_id uuid,
  p_date    date,
  p_slot    text,
  p_note    text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id   uuid;
begin
  if v_uid is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  if p_slot is null or p_slot not in ('morning', 'evening') then
    raise exception '時段不正確' using errcode = '22023';
  end if;
  if p_date is null or p_date < private.today_tw() or p_date > private.today_tw() + 30 then
    raise exception '只能登記今天起 30 天內的班' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 100 then
    raise exception '備註最多 100 字' using errcode = '22023';
  end if;
  if not exists (select 1 from public.feeding_spots where id = p_spot_id and status = 'active') then
    raise exception '找不到這個餵食點' using errcode = 'P0002';
  end if;
  if not private.is_spot_caretaker(p_spot_id) then
    raise exception '只有這個餵食點的照顧者可以登記輪值' using errcode = '42501';
  end if;

  perform private.lock_user_slot(v_uid, p_date, p_slot);
  if private.has_shift(v_uid, p_date, p_slot) then
    raise exception '你這個時段已經有班了' using errcode = 'P0001';
  end if;

  begin
    insert into public.feeding_shifts (spot_id, user_id, shift_date, time_slot, note)
    values (p_spot_id, v_uid, p_date, p_slot, v_note)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這個時段已經有人排班了' using errcode = 'P0001';
  end;
  return v_id;
end;
$$;

-- -------------------------------------------------------------
-- cancel_shift：排班者取消自己的班（已經有人代班或已完成就不能取消）；管理員可以刪除任何一班
-- -------------------------------------------------------------
create or replace function public.cancel_shift(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift public.feeding_shifts;
begin
  select * into v_shift from public.feeding_shifts where id = p_shift_id for update;
  if not found or (select auth.uid()) is null
     or not (v_shift.user_id = (select auth.uid()) or private.is_admin()) then
    raise exception '找不到這一班' using errcode = 'P0002';
  end if;
  if v_shift.status not in ('scheduled', 'need_cover') and not private.is_admin() then
    raise exception '已經有人代班或已完成的班不能取消' using errcode = 'P0001';
  end if;
  delete from public.feeding_shifts where id = p_shift_id;
end;
$$;

-- -------------------------------------------------------------
-- request_shift_cover：排班者求代班，或收回請求（處理 2.4）
-- -------------------------------------------------------------
create or replace function public.request_shift_cover(p_shift_id uuid, p_need boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift public.feeding_shifts;
begin
  select * into v_shift from public.feeding_shifts where id = p_shift_id for update;
  if not found or (select auth.uid()) is null or v_shift.user_id <> (select auth.uid()) then
    raise exception '找不到這一班' using errcode = 'P0002';
  end if;
  if coalesce(p_need, true) then
    if v_shift.status <> 'scheduled' then
      raise exception '這一班現在不能求代班' using errcode = 'P0001';
    end if;
    if v_shift.shift_date < private.today_tw() then
      raise exception '已經過去的班不能求代班' using errcode = 'P0001';
    end if;
    update public.feeding_shifts set status = 'need_cover', cover_requested_at = now() where id = p_shift_id;
  else
    if v_shift.status <> 'need_cover' then
      raise exception '已有人接了，不能收回' using errcode = 'P0001';
    end if;
    update public.feeding_shifts set status = 'scheduled', cover_requested_at = null where id = p_shift_id;
  end if;
end;
$$;

-- -------------------------------------------------------------
-- claim_shift：認領代班（代班決策樹）。鎖住這一班，只有第一位認領者成功
-- -------------------------------------------------------------
create or replace function public.claim_shift(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_shift public.feeding_shifts;
begin
  if v_uid is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  -- 先取得這一班的鎖；同時認領的第二個人會在這裡等第一個人做完
  select * into v_shift from public.feeding_shifts where id = p_shift_id for update;
  if not found or not private.is_spot_caretaker(v_shift.spot_id) then
    raise exception '找不到這一班' using errcode = 'P0002';
  end if;
  if v_shift.user_id = v_uid then
    raise exception '不能代自己的班' using errcode = 'P0001';
  end if;
  if v_shift.status <> 'need_cover' then
    raise exception '已有人接了' using errcode = 'P0001';
  end if;

  perform private.lock_user_slot(v_uid, v_shift.shift_date, v_shift.time_slot);
  if private.has_shift(v_uid, v_shift.shift_date, v_shift.time_slot) then
    raise exception '時段衝突：你這個時段已經有班了' using errcode = 'P0001';
  end if;

  update public.feeding_shifts
     set status = 'covered', cover_user_id = v_uid, covered_at = now()
   where id = p_shift_id;
end;
$$;

-- -------------------------------------------------------------
-- complete_shift：負責這一班的人（排班者，或代班者）標記完成
-- -------------------------------------------------------------
create or replace function public.complete_shift(p_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift public.feeding_shifts;
begin
  select * into v_shift from public.feeding_shifts where id = p_shift_id for update;
  if not found or (select auth.uid()) is null
     or coalesce(v_shift.cover_user_id, v_shift.user_id) <> (select auth.uid()) then
    raise exception '找不到這一班' using errcode = 'P0002';
  end if;
  if v_shift.status not in ('scheduled', 'covered') then
    raise exception '這一班現在不能標記完成' using errcode = 'P0001';
  end if;
  if v_shift.shift_date > private.today_tw() then
    raise exception '還沒到這一班的日期' using errcode = 'P0001';
  end if;
  update public.feeding_shifts set status = 'done', done_at = now() where id = p_shift_id;
end;
$$;

-- 記錄餵食時，自動把自己當天在這個點的班標記完成（下午 2 點前先算早班，之後先算晚班）
create or replace function private.complete_shift_on_feeding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_local timestamp := new.fed_at at time zone 'Asia/Taipei';
begin
  if new.user_id is null then
    return new;
  end if;
  update public.feeding_shifts
     set status = 'done', done_at = now()
   where id = (
     select id from public.feeding_shifts
     where spot_id = new.spot_id and shift_date = v_local::date
       and status in ('scheduled', 'covered')
       and coalesce(cover_user_id, user_id) = new.user_id
     order by (time_slot = case when extract(hour from v_local) < 14 then 'morning' else 'evening' end) desc
     limit 1
   );
  return new;
end;
$$;

create trigger feeding_logs_complete_shift
  after insert on public.feeding_logs
  for each row execute function private.complete_shift_on_feeding();

-- -------------------------------------------------------------
-- get_my_shifts：我照顧的餵食點從昨天起的班表
-- -------------------------------------------------------------
create or replace function public.get_my_shifts()
returns table (
  id            uuid,
  spot_id       uuid,
  spot_name     text,
  shift_date    date,
  time_slot     text,
  status        text,
  note          text,
  user_id       uuid,
  user_name     text,
  cover_user_id uuid,
  cover_name    text,
  is_mine       boolean,
  is_my_duty    boolean,
  can_claim     boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select f.id, f.spot_id, s.name, f.shift_date, f.time_slot, f.status, f.note,
         f.user_id, u.display_name, f.cover_user_id, c.display_name,
         f.user_id = (select auth.uid()),
         coalesce(f.cover_user_id, f.user_id) = (select auth.uid()),
         f.status = 'need_cover' and f.user_id <> (select auth.uid()) and f.shift_date >= private.today_tw()
  from public.feeding_shifts f
  join public.feeding_spots s on s.id = f.spot_id
  join public.spot_caretakers sc on sc.spot_id = f.spot_id and sc.user_id = (select auth.uid())
  left join public.profiles u on u.id = f.user_id
  left join public.profiles c on c.id = f.cover_user_id
  where f.shift_date >= private.today_tw() - 1
  order by f.shift_date, f.time_slot desc, s.name
  limit 300;
$$;

-- get_my_shift_spots：我可以登記輪值的餵食點
create or replace function public.get_my_shift_spots()
returns table (id uuid, name text)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, s.name
  from public.feeding_spots s
  join public.spot_caretakers sc on sc.spot_id = s.id and sc.user_id = (select auth.uid())
  where s.status = 'active'
  order by s.name;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  private.today_tw(),
  private.has_shift(uuid, date, text, uuid),
  private.lock_user_slot(uuid, date, text),
  public.create_shift(uuid, date, text, text),
  public.cancel_shift(uuid),
  public.request_shift_cover(uuid, boolean),
  public.claim_shift(uuid),
  public.complete_shift(uuid),
  public.get_my_shifts(),
  public.get_my_shift_spots()
from public, anon, authenticated;

grant execute on function
  public.create_shift(uuid, date, text, text),
  public.cancel_shift(uuid),
  public.request_shift_cover(uuid, boolean),
  public.claim_shift(uuid),
  public.complete_shift(uuid),
  public.get_my_shifts(),
  public.get_my_shift_spots()
to authenticated;
