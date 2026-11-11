-- =============================================================
-- 0006 階段 2：保育熱區與三層警示（FR-3.1、FR-3.2）、管理員後台（FR-4.1）
--   conservation_zones：管理員繪製的保育熱區（多邊形）
--   三層警示：範圍內 red、範圍外 200 公尺內 yellow、其他 none
--   管理員後台用的 RPC：使用者清單、角色設定、餵食點管理
-- 介面說明見 docs/rpc-api.md，權限見 docs/permission-matrix.md
-- =============================================================

-- -------------------------------------------------------------
-- conservation_zones：保育熱區
--   area 只收單一多邊形；ST_IsValid 不通過（例如邊線自我相交）一律拒絕
--   is_demo = true 代表「示意資料」（依公開文獻自行繪製，不是官方圖資）
-- -------------------------------------------------------------
create table public.conservation_zones (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 50),
  species     text check (species is null or char_length(species) <= 30),
  description text check (description is null or char_length(description) <= 500),
  area        extensions.geography(Polygon, 4326) not null,
  is_demo     boolean not null default true,
  status      text not null default 'active' check (status in ('active', 'archived')),
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint conservation_zones_area_valid
    check (extensions.st_isvalid(area::extensions.geometry))
);
comment on table public.conservation_zones is '保育熱區（管理員繪製）；建點與動物建檔時據此顯示三層警示';
comment on column public.conservation_zones.species is '主要保育對象，例：石虎、白鼻心';
comment on column public.conservation_zones.is_demo is 'true＝示意資料（非官方圖資），前端會標示';

create index conservation_zones_area_gix on public.conservation_zones using gist (area);
create index conservation_zones_status_idx on public.conservation_zones (status);

alter table public.conservation_zones enable row level security;

create trigger conservation_zones_set_updated_at
  before update on public.conservation_zones
  for each row execute function private.set_updated_at();

-- 權限：所有人可讀使用中的熱區（公開的大範圍資訊），管理員可讀全部；只有管理員可寫
revoke all on public.conservation_zones from anon, authenticated;
grant select on public.conservation_zones to anon, authenticated;
grant insert, delete on public.conservation_zones to authenticated;
grant update (name, species, description, area, is_demo, status)
  on public.conservation_zones to authenticated;

create policy "conservation_zones: 可讀使用中的熱區"
  on public.conservation_zones for select to anon, authenticated
  using (status = 'active' or private.is_admin());

create policy "conservation_zones: 只有管理員可新增"
  on public.conservation_zones for insert to authenticated
  with check (private.is_admin() and created_by = (select auth.uid()));

create policy "conservation_zones: 只有管理員可修改"
  on public.conservation_zones for update to authenticated
  using (private.is_admin())
  with check (private.is_admin());

create policy "conservation_zones: 只有管理員可刪除"
  on public.conservation_zones for delete to authenticated
  using (private.is_admin());

-- -------------------------------------------------------------
-- get_conservation_zones：地圖用，回傳熱區與 200 公尺緩衝帶的 GeoJSON
-- -------------------------------------------------------------
create or replace function public.get_conservation_zones()
returns table (
  id             uuid,
  name           text,
  species        text,
  description    text,
  is_demo        boolean,
  geojson        jsonb,
  buffer_geojson jsonb,
  updated_at     timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select z.id, z.name, z.species, z.description, z.is_demo,
         st_asgeojson(z.area::geometry, 6)::jsonb,
         st_asgeojson(st_buffer(z.area, 200)::geometry, 6)::jsonb,
         z.updated_at
  from conservation_zones z
  where z.status = 'active'
  order by z.name
  limit 200;
$$;

-- -------------------------------------------------------------
-- save_conservation_zone：管理員新增／修改熱區（FR-3.1）
--   p_geojson 可以是 Polygon geometry 或包著它的 Feature
--   擋下：不是單一多邊形、ST_IsValid 不通過（自我相交等）、頂點過多、面積過大
-- -------------------------------------------------------------
create or replace function public.save_conservation_zone(
  p_name text,
  p_geojson jsonb,
  p_species text default null,
  p_description text default null,
  p_is_demo boolean default true,
  p_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_geom geometry;
  v_id   uuid;
begin
  if not private.is_admin() then
    raise exception '只有管理員可以編輯保育熱區' using errcode = '42501';
  end if;

  begin
    v_geom := st_setsrid(
      st_geomfromgeojson(
        (case when p_geojson ->> 'type' = 'Feature' then p_geojson -> 'geometry' else p_geojson end)::text
      ), 4326);
  exception when others then
    raise exception '範圍格式不正確，請重新繪製' using errcode = '22023';
  end;

  if v_geom is null or geometrytype(v_geom) <> 'POLYGON' then
    raise exception '保育熱區必須是一個多邊形' using errcode = '22023';
  end if;
  if not st_isvalid(v_geom) then
    raise exception '多邊形不合法：邊線不能互相交叉，請重新繪製（%）', st_isvalidreason(v_geom)
      using errcode = '22023';
  end if;
  if st_npoints(v_geom) > 500 then
    raise exception '頂點太多（上限 500 個），請畫得簡單一點' using errcode = '22023';
  end if;
  if st_xmin(v_geom) < -180 or st_xmax(v_geom) > 180 or st_ymin(v_geom) < -90 or st_ymax(v_geom) > 90 then
    raise exception '座標不正確' using errcode = '22023';
  end if;
  if st_area(v_geom::geography) > 10000e6 then
    raise exception '範圍太大（上限 10,000 平方公里）' using errcode = '22023';
  end if;

  v_geom := st_forcepolygonccw(v_geom);

  if p_id is null then
    insert into conservation_zones (name, species, description, area, is_demo)
    values (trim(p_name), nullif(trim(p_species), ''), nullif(trim(p_description), ''),
            v_geom::geography, coalesce(p_is_demo, true))
    returning conservation_zones.id into v_id;
  else
    update conservation_zones
       set name = trim(p_name),
           species = nullif(trim(p_species), ''),
           description = nullif(trim(p_description), ''),
           area = v_geom::geography,
           is_demo = coalesce(p_is_demo, true)
     where conservation_zones.id = p_id
    returning conservation_zones.id into v_id;
    if v_id is null then
      raise exception '找不到這個保育熱區' using errcode = 'P0002';
    end if;
  end if;

  return v_id;
end;
$$;

-- -------------------------------------------------------------
-- check_conservation_alert：三層警示（FR-3.2）
--   一定回傳一列：level = red（範圍內）／yellow（範圍外 200 公尺內）／none
--   同時符合多個熱區時回傳最近的那個
-- -------------------------------------------------------------
create or replace function public.check_conservation_alert(
  p_lat double precision,
  p_lng double precision
)
returns table (
  level      text,
  zone_id    uuid,
  zone_name  text,
  species    text,
  distance_m double precision,
  is_demo    boolean
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with pt as (
    select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography as g
  ),
  nearest as (
    select z.id, z.name, z.species, z.is_demo, st_distance(z.area, pt.g) as d
    from conservation_zones z, pt
    where z.status = 'active'
      and st_dwithin(z.area, pt.g, 200)
    order by st_distance(z.area, pt.g), z.name
    limit 1
  )
  select case when n.id is null then 'none' when n.d = 0 then 'red' else 'yellow' end,
         n.id, n.name, n.species,
         round(n.d::numeric, 1)::double precision,
         n.is_demo
  from (select 1) one
  left join nearest n on true;
$$;

-- 既有餵食點的警示等級（動物建檔、餵食點面板用；需登入才讀得到精確位置）
create or replace function public.check_spot_conservation_alert(p_spot_id uuid)
returns table (
  level      text,
  zone_id    uuid,
  zone_name  text,
  species    text,
  distance_m double precision,
  is_demo    boolean
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select a.*
  from feeding_spots s,
       lateral check_conservation_alert(st_y(s.location::geometry), st_x(s.location::geometry)) a
  where s.id = p_spot_id;
$$;

-- -------------------------------------------------------------
-- 管理員後台（FR-4.1）
-- -------------------------------------------------------------

-- 使用者清單（含 Email，只有管理員拿得到）
create or replace function public.admin_list_users(
  p_search text default null,
  p_limit integer default 50
)
returns table (
  id           uuid,
  display_name text,
  email        text,
  role         text,
  created_at   timestamptz,
  spot_count   integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not private.is_admin() then
    raise exception '只有管理員可以查看使用者清單' using errcode = '42501';
  end if;

  return query
  select p.id, p.display_name, u.email::text, p.role, p.created_at,
         (select count(*)::int from public.spot_caretakers sc where sc.user_id = p.id)
  from public.profiles p
  join auth.users u on u.id = p.id
  where v_q is null
     or position(lower(v_q) in lower(p.display_name)) > 0
     or position(lower(v_q) in lower(coalesce(u.email, ''))) > 0
  order by (p.role = 'admin') desc, p.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

-- 角色設定：補上「至少保留一位管理員」與找不到使用者的檢查
create or replace function public.set_user_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current text;
begin
  if not private.is_admin() then
    raise exception '只有管理員可以設定角色' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('user', 'admin') then
    raise exception '角色不正確' using errcode = '22023';
  end if;

  -- 鎖住所有管理員列，避免兩位管理員同時互相降級後一位都不剩
  perform 1 from public.profiles where role = 'admin' for update;

  select role into v_current from public.profiles where id = p_user_id;
  if v_current is null then
    raise exception '找不到這位使用者' using errcode = 'P0002';
  end if;
  if v_current = 'admin' and p_role = 'user'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception '至少要保留一位管理員' using errcode = '22023';
  end if;

  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

-- 餵食點管理清單：含停用的點、owner、是否落在保育熱區
create or replace function public.admin_list_spots(
  p_search text default null,
  p_limit integer default 100
)
returns table (
  id              uuid,
  name            text,
  status          text,
  lat             double precision,
  lng             double precision,
  created_at      timestamptz,
  owner_names     text,
  caretaker_count integer,
  alert_level     text,
  zone_name       text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not private.is_admin() then
    raise exception '只有管理員可以使用餵食點管理' using errcode = '42501';
  end if;

  return query
  select s.id, s.name, s.status,
         st_y(s.location::geometry), st_x(s.location::geometry),
         s.created_at,
         (select string_agg(p.display_name, '、' order by sc.joined_at)
            from spot_caretakers sc join profiles p on p.id = sc.user_id
           where sc.spot_id = s.id and sc.role = 'owner'),
         (select count(*)::int from spot_caretakers sc where sc.spot_id = s.id),
         a.level, a.zone_name
  from feeding_spots s
  cross join lateral check_conservation_alert(st_y(s.location::geometry), st_x(s.location::geometry)) a
  where v_q is null or position(lower(v_q) in lower(s.name)) > 0
  order by (s.status = 'active') desc, s.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

-- 指派餵食點 owner（最後一位 owner 退出後由管理員補上）
create or replace function public.admin_set_spot_owner(p_spot_id uuid, p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not private.is_admin() then
    raise exception '只有管理員可以指派 owner' using errcode = '42501';
  end if;
  if not exists (select 1 from feeding_spots where id = p_spot_id) then
    raise exception '找不到這個餵食點' using errcode = 'P0002';
  end if;
  if not exists (select 1 from profiles where id = p_user_id) then
    raise exception '找不到這位使用者' using errcode = 'P0002';
  end if;

  insert into spot_caretakers (spot_id, user_id, role)
  values (p_spot_id, p_user_id, 'owner')
  on conflict (spot_id, user_id) do update set role = 'owner';
end;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  public.get_conservation_zones(),
  public.save_conservation_zone(text, jsonb, text, text, boolean, uuid),
  public.check_conservation_alert(double precision, double precision),
  public.check_spot_conservation_alert(uuid),
  public.admin_list_users(text, integer),
  public.admin_list_spots(text, integer),
  public.admin_set_spot_owner(uuid, uuid),
  public.set_user_role(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.get_conservation_zones(),
  public.check_conservation_alert(double precision, double precision)
to anon, authenticated;

grant execute on function
  public.save_conservation_zone(text, jsonb, text, text, boolean, uuid),
  public.check_spot_conservation_alert(uuid),
  public.admin_list_users(text, integer),
  public.admin_list_spots(text, integer),
  public.admin_set_spot_owner(uuid, uuid),
  public.set_user_role(uuid, text)
to authenticated;
