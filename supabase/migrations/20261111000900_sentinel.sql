-- =============================================================
-- 階段 5 延伸一：失蹤／健康哨兵（FR-4.2，M1 決策表 3）
--   sightings     ：目擊回報（登入者）
--   animal_alerts ：提醒（missing 可能失蹤、health 健康），只有該動物出沒點的照顧者、建檔者、管理員看得到
--   每日排程（pg_cron）檢查「超過門檻沒被看到，而且這段期間該點有人餵過」
--
-- 決策表 3（門檻 T＝max（3 天，平均出現間隔 × 2））
--   規則 1 目擊回報為受傷／跛腳／消瘦          → 立即發健康提醒
--   規則 2 超過 T 未被看到、期間該點有人餵過、沒有未處理提醒 → 發「可能失蹤」提醒
--   規則 3 同上但已有未處理的提醒                → 不提醒
--   規則 4 超過 T 未被看到，但期間該點沒人餵過   → 不提醒（沒有人去過，不能說牠不見了）
--   規則 5 沒有超過 T                            → 不提醒
-- =============================================================

-- 最後出現時間：建檔當下算第一次出現，之後由目擊回報更新
alter table public.animals add column last_seen_at timestamptz;
update public.animals set last_seen_at = created_at where last_seen_at is null;
alter table public.animals alter column last_seen_at set default now();
comment on column public.animals.last_seen_at is '最後出現時間（建檔或最近一次目擊），失蹤哨兵用';

-- 建檔時一律從現在起算，不接受用戶端自己帶的時間
create or replace function private.init_last_seen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.last_seen_at := now();
  return new;
end;
$$;

create trigger animals_init_last_seen
  before insert on public.animals
  for each row execute function private.init_last_seen();

-- -------------------------------------------------------------
-- sightings：目擊回報
-- -------------------------------------------------------------
create table public.sightings (
  id          uuid primary key default gen_random_uuid(),
  animal_id   uuid not null references public.animals (id) on delete cascade,
  spot_id     uuid references public.feeding_spots (id) on delete set null,
  condition   text not null default 'normal' check (condition in ('normal', 'limping', 'thin', 'injured')),
  note        text check (note is null or char_length(note) <= 200),
  seen_at     timestamptz not null default now(),
  reported_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
comment on table public.sightings is '目擊回報；只能透過 report_sighting 寫入';
comment on column public.sightings.condition is 'normal 正常、limping 跛腳、thin 消瘦、injured 受傷';

create index sightings_animal_idx on public.sightings (animal_id, seen_at desc);
create index sightings_reporter_idx on public.sightings (reported_by, created_at desc);

alter table public.sightings enable row level security;
revoke all on public.sightings from anon, authenticated;
grant select on public.sightings to authenticated;

create policy "sightings: 登入者可讀"
  on public.sightings for select to authenticated
  using (true);

-- -------------------------------------------------------------
-- animal_alerts：哨兵提醒
-- -------------------------------------------------------------
create table public.animal_alerts (
  id             uuid primary key default gen_random_uuid(),
  animal_id      uuid not null references public.animals (id) on delete cascade,
  spot_id        uuid references public.feeding_spots (id) on delete set null,
  type           text not null check (type in ('missing', 'health')),
  status         text not null default 'open' check (status in ('open', 'resolved')),
  condition      text check (condition is null or condition in ('limping', 'thin', 'injured')),
  sighting_id    uuid references public.sightings (id) on delete set null,
  last_seen_at   timestamptz,
  threshold_days numeric(6, 1),
  note           text check (note is null or char_length(note) <= 200),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  resolved_at    timestamptz,
  resolved_by    uuid references public.profiles (id) on delete set null
);
comment on table public.animal_alerts is '哨兵提醒；只有該動物出沒點的照顧者、建檔者與管理員可讀';
comment on column public.animal_alerts.last_seen_at is '發出失蹤提醒當下的最後出現時間';
comment on column public.animal_alerts.threshold_days is '發出失蹤提醒當下的門檻 T（天）';

create index animal_alerts_animal_idx on public.animal_alerts (animal_id, created_at desc);
create unique index animal_alerts_one_open_idx on public.animal_alerts (animal_id, type) where status = 'open';

alter table public.animal_alerts enable row level security;
revoke all on public.animal_alerts from anon, authenticated;
grant select on public.animal_alerts to authenticated;

create policy "animal_alerts: 照顧者、建檔者、管理員可讀"
  on public.animal_alerts for select to authenticated
  using (private.can_edit_animal(animal_id));

-- 排程執行紀錄（後台顯示上次檢查時間）
create table private.sentinel_runs (
  id      bigint generated always as identity primary key,
  ran_at  timestamptz not null default now(),
  created int not null,
  source  text not null
);

-- -------------------------------------------------------------
-- 門檻 T＝max（3 天，平均出現間隔 × 2）
--   平均出現間隔取最近 10 次目擊；不到 2 次就用 3 天
-- -------------------------------------------------------------
create or replace function private.sentinel_threshold(p_animal_id uuid)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
    interval '3 days',
    coalesce((
      select case when count(*) >= 2 then (max(seen_at) - min(seen_at)) / (count(*) - 1) * 2 end
      from (select seen_at from public.sightings where animal_id = p_animal_id order by seen_at desc limit 10) recent
    ), interval '3 days')
  );
$$;

-- -------------------------------------------------------------
-- 每日檢查（決策表 3 規則 2～5）。回傳這次新發出的提醒數
--   同一次「沒出現」只提醒一次：照顧者結案後，要等動物再被看到，下一次沒出現才會再提醒
-- -------------------------------------------------------------
create or replace function private.run_missing_sentinel(p_now timestamptz default now(), p_source text default 'cron')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created int;
begin
  with candidates as (
    select a.id as animal_id,
           coalesce(a.last_seen_at, a.created_at) as last_seen,
           private.sentinel_threshold(a.id) as threshold
    from public.animals a
    where a.status = 'active'
  ), due as (
    select c.*, fed.spot_id
    from candidates c
    cross join lateral (
      select l.spot_id
      from public.feeding_logs l
      join public.spot_animals sa on sa.spot_id = l.spot_id and sa.animal_id = c.animal_id
      join public.feeding_spots s on s.id = l.spot_id and s.status = 'active'
      where l.fed_at > c.last_seen and l.fed_at <= p_now
      order by l.fed_at desc
      limit 1
    ) fed
    where p_now - c.last_seen > c.threshold
      and not exists (
        select 1 from public.animal_alerts al
        where al.animal_id = c.animal_id and al.type = 'missing'
          and (al.status = 'open' or al.last_seen_at >= c.last_seen)
      )
  ), ins as (
    insert into public.animal_alerts (animal_id, spot_id, type, last_seen_at, threshold_days, created_at, updated_at)
    select animal_id, spot_id, 'missing', last_seen, round((extract(epoch from threshold) / 86400)::numeric, 1), p_now, p_now
    from due
    on conflict do nothing
    returning 1
  )
  select count(*) into v_created from ins;

  insert into private.sentinel_runs (ran_at, created, source) values (now(), v_created, p_source);
  return v_created;
end;
$$;

-- -------------------------------------------------------------
-- report_sighting：回報目擊（FR-13）。受傷／跛腳／消瘦立即發健康提醒（規則 1）
-- -------------------------------------------------------------
create or replace function public.report_sighting(
  p_animal_id uuid,
  p_condition text default 'normal',
  p_spot_id   uuid default null,
  p_note      text default null,
  p_seen_at   timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_seen     timestamptz := coalesce(p_seen_at, now());
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_spot     uuid := p_spot_id;
  v_sighting uuid;
  v_alert    uuid;
  v_found    int := 0;
begin
  if v_uid is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  if not exists (select 1 from public.animals where id = p_animal_id) then
    raise exception '找不到這隻動物' using errcode = 'P0002';
  end if;
  if p_condition is null or p_condition not in ('normal', 'limping', 'thin', 'injured') then
    raise exception '健康狀況不正確' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    raise exception '備註最多 200 字' using errcode = '22023';
  end if;
  if v_seen > now() + interval '5 minutes' then
    raise exception '目擊時間不能是未來' using errcode = '22023';
  end if;
  if v_seen < now() - interval '7 days' then
    raise exception '只能回報 7 天內的目擊' using errcode = '22023';
  end if;

  if v_spot is not null then
    if not exists (select 1 from public.spot_animals where animal_id = p_animal_id and spot_id = v_spot) then
      raise exception '這隻動物不在這個餵食點' using errcode = '22023';
    end if;
  elsif (select count(*) from public.spot_animals where animal_id = p_animal_id) = 1 then
    select spot_id into v_spot from public.spot_animals where animal_id = p_animal_id;
  end if;

  -- 頻率限制
  if exists (select 1 from public.sightings
             where reported_by = v_uid and animal_id = p_animal_id and created_at > now() - interval '10 minutes') then
    raise exception '你剛剛已經回報過這隻動物，10 分鐘後再試' using errcode = 'P0001';
  end if;
  if (select count(*) from public.sightings
      where reported_by = v_uid and created_at > now() - interval '1 hour') >= 30 then
    raise exception '回報太頻繁，請稍後再試' using errcode = 'P0001';
  end if;

  insert into public.sightings (animal_id, spot_id, condition, note, seen_at, reported_by)
  values (p_animal_id, v_spot, p_condition, v_note, v_seen, v_uid)
  returning id into v_sighting;

  update public.animals
     set last_seen_at = greatest(coalesce(last_seen_at, created_at), v_seen),
         status = case when status = 'missing' then 'active' else status end
   where id = p_animal_id;

  -- 又被看到了：把「可能失蹤」的提醒結案
  update public.animal_alerts
     set status = 'resolved', resolved_at = now(), updated_at = now(), resolved_by = v_uid,
         note = coalesce(note, '有人回報看到牠，自動結案')
   where animal_id = p_animal_id and type = 'missing' and status = 'open'
     and (last_seen_at is null or v_seen > last_seen_at);
  get diagnostics v_found = row_count;

  -- 規則 1：健康提醒。已有未處理的健康提醒時更新成最新一次回報，不重複開
  if p_condition <> 'normal' then
    update public.animal_alerts
       set condition = p_condition, sighting_id = v_sighting, spot_id = coalesce(v_spot, spot_id), updated_at = now()
     where animal_id = p_animal_id and type = 'health' and status = 'open'
    returning id into v_alert;
    if v_alert is null then
      insert into public.animal_alerts (animal_id, spot_id, type, condition, sighting_id)
      values (p_animal_id, v_spot, 'health', p_condition, v_sighting)
      returning id into v_alert;
    end if;
  end if;

  return jsonb_build_object('sighting_id', v_sighting, 'alert_id', v_alert, 'missing_resolved', v_found);
end;
$$;

-- -------------------------------------------------------------
-- get_animal_sightings：某隻動物最近的目擊紀錄（登入者）
-- -------------------------------------------------------------
create or replace function public.get_animal_sightings(p_animal_id uuid, p_limit int default 20)
returns table (
  id            uuid,
  seen_at       timestamptz,
  condition     text,
  note          text,
  spot_id       uuid,
  spot_name     text,
  reporter_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  return query
    select g.id, g.seen_at, g.condition, g.note, g.spot_id, s.name, p.display_name
    from public.sightings g
    left join public.feeding_spots s on s.id = g.spot_id
    left join public.profiles p on p.id = g.reported_by
    where g.animal_id = p_animal_id
    order by g.seen_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100);
end;
$$;

-- -------------------------------------------------------------
-- get_my_animal_alerts：我照顧的動物的提醒（管理員看全部）
-- -------------------------------------------------------------
create or replace function public.get_my_animal_alerts()
returns table (
  id             uuid,
  type           text,
  status         text,
  animal_id      uuid,
  animal_name    text,
  spot_id        uuid,
  spot_name      text,
  condition      text,
  last_seen_at   timestamptz,
  threshold_days numeric,
  note           text,
  created_at     timestamptz,
  updated_at     timestamptz,
  resolved_at    timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select al.id, al.type, al.status, al.animal_id, a.name, al.spot_id, s.name, al.condition,
         al.last_seen_at, al.threshold_days, al.note, al.created_at, al.updated_at, al.resolved_at
  from animal_alerts al
  join animals a on a.id = al.animal_id
  left join feeding_spots s on s.id = al.spot_id
  order by (al.status = 'resolved'), al.updated_at desc
  limit 200;
$$;

-- -------------------------------------------------------------
-- resolve_animal_alert：照顧者處理提醒；失蹤提醒可以順便把動物標記為失蹤
-- -------------------------------------------------------------
create or replace function public.resolve_animal_alert(
  p_alert_id     uuid,
  p_note         text default null,
  p_mark_missing boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alert public.animal_alerts;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  select * into v_alert from public.animal_alerts where id = p_alert_id;
  if not found or not private.can_edit_animal(v_alert.animal_id) then
    raise exception '找不到這則提醒' using errcode = 'P0002';
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    raise exception '備註最多 200 字' using errcode = '22023';
  end if;
  if coalesce(p_mark_missing, false) and v_alert.type <> 'missing' then
    raise exception '只有失蹤提醒可以標記為失蹤' using errcode = '22023';
  end if;

  update public.animal_alerts
     set status = 'resolved', resolved_at = now(), updated_at = now(), resolved_by = (select auth.uid()),
         note = coalesce(v_note, note)
   where id = p_alert_id;

  if coalesce(p_mark_missing, false) then
    update public.animals set status = 'missing' where id = v_alert.animal_id and status = 'active';
  end if;
end;
$$;

-- -------------------------------------------------------------
-- admin_run_sentinel：管理員立即執行一次檢查，並回報排程狀態
-- -------------------------------------------------------------
create or replace function public.admin_run_sentinel(p_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created   int;
  v_scheduled boolean := false;
  v_last      timestamptz;
begin
  if not private.is_admin() then
    raise exception '只有管理員可以執行' using errcode = '42501';
  end if;
  select max(ran_at) into v_last from private.sentinel_runs where source = 'cron';
  if coalesce(p_run, true) then
    v_created := private.run_missing_sentinel(now(), 'manual');
  end if;
  if to_regclass('cron.job') is not null then
    execute $q$select exists (select 1 from cron.job where jobname = 'pawlink-sentinel-daily' and active)$q$ into v_scheduled;
  end if;
  return jsonb_build_object('created', v_created, 'scheduled', v_scheduled, 'last_cron_run_at', v_last);
end;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  private.sentinel_threshold(uuid),
  private.run_missing_sentinel(timestamptz, text),
  public.report_sighting(uuid, text, uuid, text, timestamptz),
  public.get_animal_sightings(uuid, int),
  public.get_my_animal_alerts(),
  public.resolve_animal_alert(uuid, text, boolean),
  public.admin_run_sentinel(boolean)
from public, anon, authenticated;

grant execute on function
  public.report_sighting(uuid, text, uuid, text, timestamptz),
  public.get_animal_sightings(uuid, int),
  public.get_my_animal_alerts(),
  public.resolve_animal_alert(uuid, text, boolean),
  public.admin_run_sentinel(boolean)
to authenticated;

-- -------------------------------------------------------------
-- 每日排程：臺灣時間 04:00（UTC 20:00）。沒有 pg_cron 的環境（本機測試）會略過
-- -------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    execute $q$select cron.schedule('pawlink-sentinel-daily', '0 20 * * *', 'select private.run_missing_sentinel()')$q$;
    raise notice '哨兵每日排程已建立（pawlink-sentinel-daily）';
  else
    raise notice '這個環境沒有 pg_cron，略過每日排程；管理員仍可在後台手動執行檢查';
  end if;
exception when others then
  raise notice '建立每日排程失敗（%），其餘內容已套用；管理員仍可在後台手動執行檢查', sqlerrm;
end $$;
