-- =============================================================
-- 階段 5 延伸四：領養陪伴（FR-5.4，M1 FR-17、處理 3.4）
--   adoptions：領養登記。領養人自己登記，由這隻動物的建檔者、照顧者或管理員確認；
--              確認的人成為陪伴者。登記的人本來就能編輯這隻動物時直接生效
--   adoption_followups：領養後第 7、30、90 天的關懷問卷
--   「發送」的做法：到期的問卷出現在領養人的通知裡，不靠排程或推播
-- =============================================================

create table public.adoptions (
  id          uuid primary key default gen_random_uuid(),
  animal_id   uuid not null references public.animals (id) on delete cascade,
  adopter_id  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  buddy_id    uuid references public.profiles (id) on delete set null,
  adopted_on  date not null,
  status      text not null default 'pending' check (status in ('pending', 'active', 'completed', 'cancelled')),
  note        text check (note is null or char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);
comment on table public.adoptions is '領養登記；pending 待確認、active 陪伴中、completed 三次問卷都填完、cancelled 取消或退養。只能透過 RPC 寫入';
create unique index adoptions_one_open_idx on public.adoptions (animal_id) where status <> 'cancelled';
create index adoptions_adopter_idx on public.adoptions (adopter_id);
create index adoptions_buddy_idx on public.adoptions (buddy_id);

create table public.adoption_followups (
  id           uuid primary key default gen_random_uuid(),
  adoption_id  uuid not null references public.adoptions (id) on delete cascade,
  day_offset   smallint not null check (day_offset in (7, 30, 90)),
  due_on       date not null,
  eating_ok    boolean,
  health_ok    boolean,
  settled_ok   boolean,
  has_issue    boolean,
  note         text check (note is null or char_length(note) <= 300),
  answered_at  timestamptz,
  unique (adoption_id, day_offset)
);
comment on table public.adoption_followups is '領養關懷問卷；第 7、30、90 天各一份，has_issue 表示有任何一題回答「否」';
create index adoption_followups_due_idx on public.adoption_followups (due_on) where answered_at is null;

-- 兩張表都不開放直接讀寫：問卷回答只有領養人、陪伴者、照顧者看得到，一律走 RPC
alter table public.adoptions enable row level security;
alter table public.adoption_followups enable row level security;
revoke all on public.adoptions, public.adoption_followups from anon, authenticated;

create trigger adoptions_set_updated_at before update on public.adoptions
  for each row execute function private.set_updated_at();

-- 讓領養正式生效：建立三份問卷，動物狀態改成已領養
create or replace function private.activate_adoption(p_adoption_id uuid, p_buddy uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ad public.adoptions;
begin
  update public.adoptions set status = 'active', buddy_id = p_buddy
   where id = p_adoption_id returning * into v_ad;
  insert into public.adoption_followups (adoption_id, day_offset, due_on)
  select v_ad.id, d, v_ad.adopted_on + d from unnest(array[7, 30, 90]) d
  on conflict do nothing;
  update public.animals set status = 'adopted' where id = v_ad.animal_id;
end;
$$;
revoke all on function private.activate_adoption(uuid, uuid) from public, anon, authenticated;

-- -------------------------------------------------------------
-- register_adoption：登記「我領養了這隻」。回傳領養編號
-- -------------------------------------------------------------
create or replace function public.register_adoption(
  p_animal_id  uuid,
  p_adopted_on date default null,
  p_note       text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_status text;
  v_date   date := coalesce(p_adopted_on, private.today_tw());
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_id     uuid;
begin
  if v_uid is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select status into v_status from public.animals where id = p_animal_id for update;
  if not found then
    raise exception '找不到這隻動物' using errcode = 'P0002';
  end if;
  if v_status = 'deceased' then
    raise exception '這隻動物已經離世，不能登記領養' using errcode = 'P0001';
  end if;
  if v_date > private.today_tw() or v_date < private.today_tw() - 365 then
    raise exception '領養日期要在今天以前、一年以內' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    raise exception '備註最多 200 字' using errcode = '22023';
  end if;

  begin
    insert into public.adoptions (animal_id, adopter_id, adopted_on, note)
    values (p_animal_id, v_uid, v_date, v_note)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這隻動物已經有人登記領養' using errcode = 'P0001';
  end;

  if private.can_edit_animal(p_animal_id) then
    perform private.activate_adoption(v_id, null);
  end if;
  return v_id;
end;
$$;

-- -------------------------------------------------------------
-- confirm_adoption：建檔者、照顧者或管理員確認，確認的人成為陪伴者
-- -------------------------------------------------------------
create or replace function public.confirm_adoption(p_adoption_id uuid)
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
  if v_ad.adopter_id = (select auth.uid()) or not private.can_edit_animal(v_ad.animal_id) then
    raise exception '要由這隻動物的建檔者、照顧者或管理員確認' using errcode = '42501';
  end if;
  if v_ad.status <> 'pending' then
    raise exception '這筆登記已經處理過了' using errcode = 'P0001';
  end if;
  perform private.activate_adoption(p_adoption_id, (select auth.uid()));
end;
$$;

-- -------------------------------------------------------------
-- cancel_adoption：領養人撤回、照顧者退回，或確認後的退養。
--   動物如果已經標成已領養，改回一般狀態
-- -------------------------------------------------------------
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
  update public.adoptions set status = 'cancelled', closed_at = now() where id = p_adoption_id;
  if v_ad.status <> 'pending' then
    update public.animals set status = 'active' where id = v_ad.animal_id and status = 'adopted';
  end if;
end;
$$;

-- -------------------------------------------------------------
-- submit_adoption_followup：領養人填關懷問卷。回傳是否有狀況
--   到期才能填；三份都填完，領養紀錄改成 completed
-- -------------------------------------------------------------
create or replace function public.submit_adoption_followup(
  p_followup_id uuid,
  p_eating_ok   boolean,
  p_health_ok   boolean,
  p_settled_ok  boolean,
  p_note        text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_f     public.adoption_followups;
  v_ad    public.adoptions;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
  v_issue boolean;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select * into v_f from public.adoption_followups where id = p_followup_id for update;
  if not found then
    raise exception '找不到這份問卷' using errcode = 'P0002';
  end if;
  select * into v_ad from public.adoptions where id = v_f.adoption_id for update;
  if v_ad.adopter_id <> (select auth.uid()) then
    raise exception '只有領養人可以填這份問卷' using errcode = '42501';
  end if;
  if v_ad.status <> 'active' then
    raise exception '這筆領養已經結束' using errcode = 'P0001';
  end if;
  if v_f.answered_at is not null then
    raise exception '這份問卷已經填過了' using errcode = 'P0001';
  end if;
  if v_f.due_on > private.today_tw() then
    raise exception '還沒到填這份問卷的時間' using errcode = 'P0001';
  end if;
  if p_eating_ok is null or p_health_ok is null or p_settled_ok is null then
    raise exception '三個問題都要回答' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 300 then
    raise exception '補充說明最多 300 字' using errcode = '22023';
  end if;

  v_issue := not (p_eating_ok and p_health_ok and p_settled_ok);
  update public.adoption_followups
     set eating_ok = p_eating_ok, health_ok = p_health_ok, settled_ok = p_settled_ok,
         has_issue = v_issue, note = v_note, answered_at = now()
   where id = p_followup_id;

  if not exists (select 1 from public.adoption_followups
                 where adoption_id = v_ad.id and answered_at is null) then
    update public.adoptions set status = 'completed', closed_at = now() where id = v_ad.id;
  end if;
  return v_issue;
end;
$$;

-- -------------------------------------------------------------
-- get_adoptions：領養紀錄
--   p_animal_id 有值：這隻動物目前的領養紀錄（登入者都看得到狀態，問卷內容只有相關的人看得到）
--   沒有值：跟我有關的（我是領養人、陪伴者，或是等我確認的）
--   my_role：adopter 領養人、buddy 陪伴者、caretaker 可以確認或取消的人、viewer 其他人
-- -------------------------------------------------------------
create or replace function public.get_adoptions(p_animal_id uuid default null)
returns table (
  adoption_id   uuid,
  animal_id     uuid,
  animal_name   text,
  status        text,
  adopted_on    date,
  note          text,
  adopter_name  text,
  buddy_name    text,
  my_role       text,
  due_count     integer,
  issue_count   integer,
  followups     jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  with mine as (
    select ad.*,
           case when ad.adopter_id = (select auth.uid()) then 'adopter'
                when ad.buddy_id = (select auth.uid()) then 'buddy'
                when private.can_edit_animal(ad.animal_id) then 'caretaker'
                else 'viewer' end as my_role
    from public.adoptions ad
    where (select auth.uid()) is not null
      and case when p_animal_id is null then ad.status <> 'cancelled'
               else ad.animal_id = p_animal_id and ad.status <> 'cancelled' end
  )
  select m.id, a.id, a.name, m.status, m.adopted_on,
         case when m.my_role <> 'viewer' then m.note end,
         ap.display_name, bp.display_name, m.my_role,
         (select count(*)::int from public.adoption_followups f
          where f.adoption_id = m.id and f.answered_at is null and f.due_on <= private.today_tw()
            and m.status = 'active'),
         case when m.my_role <> 'viewer' then
           (select count(*)::int from public.adoption_followups f where f.adoption_id = m.id and f.has_issue)
         else 0 end,
         case when m.my_role <> 'viewer' then
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', f.id, 'day_offset', f.day_offset, 'due_on', f.due_on,
                       'is_due', f.answered_at is null and f.due_on <= private.today_tw(),
                       'answered_at', f.answered_at, 'eating_ok', f.eating_ok, 'health_ok', f.health_ok,
                       'settled_ok', f.settled_ok, 'has_issue', f.has_issue, 'note', f.note)
                     order by f.day_offset)
                     from public.adoption_followups f where f.adoption_id = m.id), '[]'::jsonb)
         else '[]'::jsonb end
  from mine m
  join public.animals a on a.id = m.animal_id
  left join public.profiles ap on ap.id = m.adopter_id
  left join public.profiles bp on bp.id = m.buddy_id
  where p_animal_id is not null
     or m.my_role in ('adopter', 'buddy')
     or (m.my_role = 'caretaker' and m.status = 'pending')
  order by (m.status = 'completed'), m.created_at desc
  limit 200;
$$;

-- -------------------------------------------------------------
-- 修正 0011 的 cancel_tnr_case：發起人帳號被刪除後 opened_by 是空值，
--   原本的判斷會變成空值而略過權限檢查，任何登入者都能取消。改用 is not distinct from
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
  if not (v_case.opened_by is not distinct from (select auth.uid())
          or private.can_edit_animal(v_case.animal_id)) then
    raise exception '只有發起人或這隻動物的照顧者可以取消' using errcode = '42501';
  end if;
  if v_case.status <> 'open' then
    raise exception '這個案件已經結束' using errcode = 'P0001';
  end if;
  update public.tnr_cases set status = 'cancelled', closed_at = now() where id = p_case_id;
end;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  public.register_adoption(uuid, date, text),
  public.confirm_adoption(uuid),
  public.cancel_adoption(uuid),
  public.submit_adoption_followup(uuid, boolean, boolean, boolean, text),
  public.get_adoptions(uuid)
from public, anon, authenticated;

grant execute on function
  public.register_adoption(uuid, date, text),
  public.confirm_adoption(uuid),
  public.cancel_adoption(uuid),
  public.submit_adoption_followup(uuid, boolean, boolean, boolean, text),
  public.get_adoptions(uuid)
to authenticated;
