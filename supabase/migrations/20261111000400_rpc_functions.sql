-- =============================================================
-- 0004 前端呼叫的 RPC（supabase.rpc('名稱', {...})）
--   規則常數：
--     腳印顏色：6 小時內 fresh（綠）、6～24 小時 recent（黃）、超過 24 小時或沒紀錄 hungry（紅/灰）
--     重複點提醒：30 公尺
--     重複投餵提醒：2 小時
--     清理率：近 30 天
--     訪客位置模糊化：100 公尺網格（TWD97 / EPSG:3826）
-- 介面說明見 docs/rpc-api.md
-- =============================================================

-- -------------------------------------------------------------
-- 內部：位置模糊化。把點吸附到 TWD97 的 100m 網格中心，
-- 結果固定（同一點每次都一樣），無法靠多次查詢平均回推。
-- -------------------------------------------------------------
create or replace function private.fuzz_point(p_location extensions.geography)
returns extensions.geography
language sql
immutable
set search_path = public, extensions
as $$
  select st_transform(
    st_snaptogrid(st_transform(p_location::geometry, 3826), 50, 50, 100, 100),
    4326
  )::geography;
$$;

-- 內部：腳印顏色
create or replace function private.footprint_status(p_last_fed_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_last_fed_at is null then 'hungry'
    when p_last_fed_at > now() - interval '6 hours' then 'fresh'
    when p_last_fed_at > now() - interval '24 hours' then 'recent'
    else 'hungry'
  end;
$$;

grant execute on function private.fuzz_point(extensions.geography), private.footprint_status(timestamptz)
  to anon, authenticated;

-- -------------------------------------------------------------
-- get_map_spots：地圖範圍內的餵食點（訪客與登入者共用）
--   訪客：位置為 100m 模糊位置，且「範圍篩選也用模糊位置」，避免用極小範圍反推
--   回傳上限 500 筆
-- -------------------------------------------------------------
create or replace function public.get_map_spots(
  min_lng double precision,
  min_lat double precision,
  max_lng double precision,
  max_lat double precision
)
returns table (
  id               uuid,
  name             text,
  lat              double precision,
  lng              double precision,
  is_fuzzed        boolean,
  last_fed_at      timestamptz,
  footprint        text,
  animal_count     integer,
  sterilized_count integer,
  clean_rate_30d   numeric
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with viewer as (
    select (select auth.uid()) is null as is_anon
  ),
  box as (
    select st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography as g
  ),
  candidates as (
    select s.id, s.name,
           case when v.is_anon then private.fuzz_point(s.location) else s.location end as loc,
           v.is_anon
    from feeding_spots s, viewer v, box b
    where s.status = 'active'
      -- 先用 GiST 索引粗篩（外擴約 100m 讓模糊點不漏掉），再用顯示位置精篩
      and st_dwithin(s.location, b.g, 100)
  )
  select c.id,
         c.name,
         st_y(c.loc::geometry) as lat,
         st_x(c.loc::geometry) as lng,
         c.is_anon as is_fuzzed,
         lf.last_fed_at,
         private.footprint_status(lf.last_fed_at) as footprint,
         coalesce(an.animal_count, 0) as animal_count,
         coalesce(an.sterilized_count, 0) as sterilized_count,
         cr.clean_rate_30d
  from candidates c
  cross join box b
  left join lateral (
    select max(l.fed_at) as last_fed_at from feeding_logs l where l.spot_id = c.id
  ) lf on true
  left join lateral (
    select count(*)::int as animal_count,
           count(*) filter (where a.is_sterilized)::int as sterilized_count
    from spot_animals sa join animals a on a.id = sa.animal_id
    where sa.spot_id = c.id and a.status = 'active'
  ) an on true
  left join lateral (
    select round(count(*) filter (where l.cleaned_at is not null)::numeric / nullif(count(*), 0), 3)
             as clean_rate_30d
    from feeding_logs l
    where l.spot_id = c.id and l.fed_at > now() - interval '30 days'
  ) cr on true
  where st_intersects(c.loc, b.g)
  order by lf.last_fed_at desc nulls last
  limit 500;
$$;

-- -------------------------------------------------------------
-- get_spot_summary：單一餵食點的公開摘要（面板、進度公開用）
-- -------------------------------------------------------------
create or replace function public.get_spot_summary(p_spot_id uuid)
returns table (
  id               uuid,
  name             text,
  description      text,
  lat              double precision,
  lng              double precision,
  is_fuzzed        boolean,
  status           text,
  last_fed_at      timestamptz,
  footprint        text,
  feedings_30d     integer,
  cleaned_30d      integer,
  clean_rate_30d   numeric,
  animal_count     integer,
  sterilized_count integer,
  caretaker_count  integer,
  is_caretaker     boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with viewer as (
    select (select auth.uid()) as uid, (select auth.uid()) is null as is_anon
  ),
  s as (
    select sp.*,
           case when v.is_anon then private.fuzz_point(sp.location) else sp.location end as loc,
           v.is_anon, v.uid
    from feeding_spots sp, viewer v
    where sp.id = p_spot_id
      and (sp.status = 'active' or not v.is_anon)
  )
  select s.id, s.name,
         case when s.is_anon then null else s.description end,  -- 描述可能含地址，訪客不給
         st_y(s.loc::geometry), st_x(s.loc::geometry),
         s.is_anon, s.status,
         lf.last_fed_at,
         private.footprint_status(lf.last_fed_at),
         st.feedings, st.cleaned,
         round(st.cleaned::numeric / nullif(st.feedings, 0), 3),
         coalesce(an.animal_count, 0), coalesce(an.sterilized_count, 0),
         (select count(*)::int from spot_caretakers sc where sc.spot_id = s.id),
         coalesce(exists (select 1 from spot_caretakers sc where sc.spot_id = s.id and sc.user_id = s.uid), false)
  from s
  left join lateral (
    select max(l.fed_at) as last_fed_at from feeding_logs l where l.spot_id = s.id
  ) lf on true
  left join lateral (
    select count(*)::int as feedings,
           count(*) filter (where l.cleaned_at is not null)::int as cleaned
    from feeding_logs l
    where l.spot_id = s.id and l.fed_at > now() - interval '30 days'
  ) st on true
  left join lateral (
    select count(*)::int as animal_count,
           count(*) filter (where a.is_sterilized)::int as sterilized_count
    from spot_animals sa join animals a on a.id = sa.animal_id
    where sa.spot_id = s.id and a.status = 'active'
  ) an on true;
$$;

-- -------------------------------------------------------------
-- find_nearby_spots：建點前的重複點檢查（FR-1.2，預設 30m）
-- -------------------------------------------------------------
create or replace function public.find_nearby_spots(
  p_lat double precision,
  p_lng double precision,
  p_radius_m integer default 30
)
returns table (id uuid, name text, distance_m double precision, last_fed_at timestamptz)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with pt as (
    select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography as g
  )
  select s.id, s.name,
         round(st_distance(s.location, pt.g)::numeric, 1)::double precision,
         (select max(l.fed_at) from feeding_logs l where l.spot_id = s.id)
  from feeding_spots s, pt
  where s.status = 'active'
    and st_dwithin(s.location, pt.g, least(greatest(p_radius_m, 1), 1000))
  order by st_distance(s.location, pt.g)
  limit 20;
$$;

-- -------------------------------------------------------------
-- create_feeding_spot：建點（RLS 會檢查登入）
-- -------------------------------------------------------------
create or replace function public.create_feeding_spot(
  p_name text,
  p_lat double precision,
  p_lng double precision,
  p_description text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception '座標不正確' using errcode = '22023';
  end if;

  insert into feeding_spots (name, description, location)
  values (trim(p_name), nullif(trim(p_description), ''),
          st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography)
  returning feeding_spots.id into v_id;

  return v_id;
end;
$$;

-- -------------------------------------------------------------
-- check_recent_feeding：記錄餵食前的重複投餵提醒（FR-1.3，預設 2 小時）
--   沒有紀錄時回傳 0 列
-- -------------------------------------------------------------
create or replace function public.check_recent_feeding(
  p_spot_id uuid,
  p_hours numeric default 2
)
returns table (log_id uuid, fed_at timestamptz, fed_by_name text, minutes_ago integer)
language sql
stable
security invoker
set search_path = public
as $$
  select l.id, l.fed_at, p.display_name,
         floor(extract(epoch from (now() - l.fed_at)) / 60)::int
  from feeding_logs l
  left join profiles p on p.id = l.user_id
  where l.spot_id = p_spot_id
    and l.fed_at > now() - make_interval(secs => p_hours * 3600)
  order by l.fed_at desc
  limit 1;
$$;

-- -------------------------------------------------------------
-- record_feeding：記錄餵食
--   p_client_id：前端產生的 UUID；離線補傳重送時不會重複（回傳同一個 id）
-- -------------------------------------------------------------
create or replace function public.record_feeding(
  p_spot_id uuid,
  p_food_type text default 'dry',
  p_note text default null,
  p_fed_at timestamptz default null,
  p_client_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid := coalesce(p_client_id, gen_random_uuid());
begin
  insert into feeding_logs (id, spot_id, food_type, note, fed_at)
  values (v_id, p_spot_id, coalesce(p_food_type, 'dry'), nullif(trim(p_note), ''),
          coalesce(p_fed_at, now()))
  on conflict (id) do nothing;

  return v_id;
end;
$$;

-- -------------------------------------------------------------
-- report_cleanup：清理回報（FR-1.6）
-- -------------------------------------------------------------
create or replace function public.report_cleanup(p_log_id uuid)
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_at timestamptz;
begin
  update feeding_logs
     set cleaned_at = greatest(now(), fed_at), cleaned_by = auth.uid()
   where id = p_log_id and cleaned_at is null
  returning cleaned_at into v_at;

  if v_at is null then
    raise exception '找不到可回報清理的紀錄（可能已清理或沒有權限）' using errcode = 'P0002';
  end if;
  return v_at;
end;
$$;

-- -------------------------------------------------------------
-- get_my_pending_cleanups：我的待清理紀錄（餵食後 30 分鐘起、24 小時內）
-- -------------------------------------------------------------
create or replace function public.get_my_pending_cleanups()
returns table (log_id uuid, spot_id uuid, spot_name text, fed_at timestamptz)
language sql
stable
security invoker
set search_path = public
as $$
  select l.id, l.spot_id, s.name, l.fed_at
  from feeding_logs l
  join feeding_spots s on s.id = l.spot_id
  where l.user_id = auth.uid()
    and l.cleaned_at is null
    and l.fed_at <= now() - interval '30 minutes'
    and l.fed_at > now() - interval '24 hours'
  order by l.fed_at;
$$;

-- -------------------------------------------------------------
-- set_user_role：管理員設定角色（階段 2 後台用，先備好）
-- -------------------------------------------------------------
create or replace function public.set_user_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception '只有管理員可以設定角色' using errcode = '42501';
  end if;
  if p_role not in ('user', 'admin') then
    raise exception '角色不正確' using errcode = '22023';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

-- -------------------------------------------------------------
-- 權限：公開讀取的給 anon；其餘只給登入者
-- -------------------------------------------------------------
revoke all on function
  public.get_map_spots(double precision, double precision, double precision, double precision),
  public.get_spot_summary(uuid),
  public.find_nearby_spots(double precision, double precision, integer),
  public.create_feeding_spot(text, double precision, double precision, text),
  public.check_recent_feeding(uuid, numeric),
  public.record_feeding(uuid, text, text, timestamptz, uuid),
  public.report_cleanup(uuid),
  public.get_my_pending_cleanups(),
  public.set_user_role(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.get_map_spots(double precision, double precision, double precision, double precision),
  public.get_spot_summary(uuid)
to anon, authenticated;

grant execute on function
  public.find_nearby_spots(double precision, double precision, integer),
  public.create_feeding_spot(text, double precision, double precision, text),
  public.check_recent_feeding(uuid, numeric),
  public.record_feeding(uuid, text, text, timestamptz, uuid),
  public.report_cleanup(uuid),
  public.get_my_pending_cleanups(),
  public.set_user_role(uuid, text)
to authenticated;
