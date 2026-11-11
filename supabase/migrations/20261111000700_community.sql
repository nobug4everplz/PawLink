-- =============================================================
-- 0007 階段 3：社區溝通
--   neighbor_reports：居民匿名干擾通報（FR-2.1、NFR-6），只有該點照顧者與管理員看得到內容（FR-2.2）
--   posts / comments / content_flags：餵食民眾交流空間與檢舉（FR-2.3）
-- 介面說明見 docs/rpc-api.md，權限見 docs/permission-matrix.md
-- =============================================================

-- -------------------------------------------------------------
-- 私密設定：前端角色完全讀不到（private schema 內、沒有任何 GRANT）
--   ip_salt          ：通報者 IP 雜湊用的鹽，安裝時隨機產生
--   turnstile_secret ：Cloudflare Turnstile 的 secret key。有設定才會要求驗證；
--                      由管理者在 SQL Editor 寫入，絕不進 repo
-- -------------------------------------------------------------
create table private.app_secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table private.app_secrets enable row level security;
revoke all on private.app_secrets from public, anon, authenticated;

insert into private.app_secrets (key, value)
values ('ip_salt', md5(random()::text || clock_timestamp()::text) || md5(random()::text))
on conflict (key) do nothing;

-- Turnstile 驗證要從資料庫呼叫 Cloudflare，需要 http 擴充套件（Supabase 有內建）。
-- 本機測試環境沒有也沒關係：沒設定 turnstile_secret 時不會用到。
do $$
begin
  create extension if not exists http with schema extensions;
exception when others then
  raise notice '沒有 http 擴充套件，Turnstile 驗證無法啟用（%）', sqlerrm;
end;
$$;

-- 呼叫者的 IP（PostgREST 會把請求標頭放在 request.headers）
create or replace function private.client_ip()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_headers jsonb;
  v_ip text;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_ip := coalesce(
    nullif(trim(v_headers ->> 'cf-connecting-ip'), ''),
    nullif(trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1)), ''),
    nullif(trim(v_headers ->> 'x-real-ip'), '')
  );
  return coalesce(v_ip, 'unknown');
end;
$$;

-- 驗證 Turnstile token。回傳 true 才放行；任何錯誤（逾時、擴充套件不存在）都當成沒通過
create or replace function private.verify_turnstile(p_token text, p_ip text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
  v_status integer;
  v_content text;
begin
  select value into v_secret from private.app_secrets where key = 'turnstile_secret';
  if v_secret is null or v_secret = '' then
    return true; -- 沒設定就不啟用，只靠頻率限制
  end if;
  if p_token is null or length(p_token) < 10 or length(p_token) > 4096 then
    return false;
  end if;
  begin
    execute $q$
      select status, content
      from extensions.http_post(
        'https://challenges.cloudflare.com/turnstile/v0/siteverify',
        'secret=' || extensions.urlencode($1) || '&response=' || extensions.urlencode($2)
          || case when $3 <> 'unknown' then '&remoteip=' || extensions.urlencode($3) else '' end,
        'application/x-www-form-urlencoded')
    $q$ into v_status, v_content using v_secret, p_token, p_ip;
    return v_status = 200 and coalesce((v_content::jsonb ->> 'success')::boolean, false);
  exception when others then
    raise warning 'Turnstile 驗證失敗：%', sqlerrm;
    return false;
  end;
end;
$$;

revoke all on function private.client_ip(), private.verify_turnstile(text, text) from public, anon, authenticated;

-- =============================================================
-- neighbor_reports：匿名干擾通報
--   不存任何可辨識通報者的資料；ip_hash 只用來做頻率限制，前端讀不到
-- =============================================================
create table public.neighbor_reports (
  id          uuid primary key default gen_random_uuid(),
  spot_id     uuid not null references public.feeding_spots (id) on delete cascade,
  category    text not null check (category in ('mess', 'noise', 'gathering', 'timing', 'other')),
  description text not null check (char_length(description) between 5 and 500),
  status      text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  response    text check (response is null or char_length(response) <= 300),
  handled_by  uuid references public.profiles (id) on delete set null,
  handled_at  timestamptz,
  ip_hash     text not null,
  created_at  timestamptz not null default now()
);
comment on table public.neighbor_reports is '居民匿名通報；內容只有該點照顧者與管理員可讀，公開的只有類別、狀態與回覆';
comment on column public.neighbor_reports.category is 'mess 環境髒亂、noise 噪音、gathering 動物聚集、timing 餵食時間不當、other 其他';
comment on column public.neighbor_reports.response is '照顧者的回覆，會公開顯示在進度頁';

create index neighbor_reports_spot_idx on public.neighbor_reports (spot_id, created_at desc);
create index neighbor_reports_ip_idx on public.neighbor_reports (ip_hash, created_at desc);
create index neighbor_reports_open_idx on public.neighbor_reports (spot_id) where status <> 'resolved';

alter table public.neighbor_reports enable row level security;

revoke all on public.neighbor_reports from anon, authenticated;
-- 不含 ip_hash；寫入一律走 RPC
grant select (id, spot_id, category, description, status, response, handled_by, handled_at, created_at)
  on public.neighbor_reports to authenticated;

create policy "neighbor_reports: 該點照顧者與管理員可讀"
  on public.neighbor_reports for select to authenticated
  using (private.is_spot_caretaker(spot_id) or private.is_admin());

-- -------------------------------------------------------------
-- submit_neighbor_report：免登入送出通報（FR-2.1、NFR-6）
--   頻率限制（同一來源 IP）：60 秒內 1 則、同一餵食點 10 分鐘內 1 則、1 小時內 3 則
--   另外每個餵食點 1 小時最多 10 則（擋分散來源的灌水）
--   有設定 turnstile_secret 時必須帶有效的 Turnstile token
-- -------------------------------------------------------------
create or replace function public.submit_neighbor_report(
  p_spot_id uuid,
  p_category text,
  p_description text,
  p_turnstile_token text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip   text := private.client_ip();
  v_hash text;
  v_desc text := trim(coalesce(p_description, ''));
  v_id   uuid;
begin
  if p_category is null or p_category not in ('mess', 'noise', 'gathering', 'timing', 'other') then
    raise exception '請選擇通報類別' using errcode = '22023';
  end if;
  if char_length(v_desc) < 5 or char_length(v_desc) > 500 then
    raise exception '說明請寫 5 到 500 個字' using errcode = '22023';
  end if;
  if not exists (select 1 from public.feeding_spots where id = p_spot_id and status = 'active') then
    raise exception '找不到這個餵食點' using errcode = 'P0002';
  end if;

  select encode(sha256(convert_to(v_ip || ':' || value, 'UTF8')), 'hex') into v_hash
  from private.app_secrets where key = 'ip_salt';

  -- 同一來源的請求排隊處理，避免同時送出繞過計數
  perform pg_advisory_xact_lock(hashtext(v_hash));

  if exists (select 1 from public.neighbor_reports
             where ip_hash = v_hash and created_at > now() - interval '60 seconds') then
    raise exception '送出太頻繁，請 1 分鐘後再試' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.neighbor_reports
             where ip_hash = v_hash and spot_id = p_spot_id and created_at > now() - interval '10 minutes') then
    raise exception '你剛剛已經通報過這個餵食點，請 10 分鐘後再試' using errcode = 'P0001';
  end if;
  if (select count(*) from public.neighbor_reports
      where ip_hash = v_hash and created_at > now() - interval '1 hour') >= 3 then
    raise exception '1 小時內最多通報 3 次，請稍後再試' using errcode = 'P0001';
  end if;
  if (select count(*) from public.neighbor_reports
      where spot_id = p_spot_id and created_at > now() - interval '1 hour') >= 10 then
    raise exception '這個餵食點短時間內收到太多通報，請稍後再試' using errcode = 'P0001';
  end if;

  -- 放在頻率限制之後：被擋下的請求不會再去呼叫 Cloudflare
  if not private.verify_turnstile(p_turnstile_token, v_ip) then
    raise exception '人機驗證沒有通過，請重新驗證後再送出' using errcode = '28000';
  end if;

  insert into public.neighbor_reports (spot_id, category, description, ip_hash)
  values (p_spot_id, p_category, v_desc, v_hash)
  returning id into v_id;
  return v_id;
end;
$$;

-- 前端要不要顯示 Turnstile 元件
create or replace function public.report_captcha_required()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.app_secrets where key = 'turnstile_secret' and value <> '');
$$;

-- -------------------------------------------------------------
-- get_spot_public_reports：進度公開（FR-2.2）
--   訪客看得到類別、狀態、時間與照顧者的回覆；看不到通報內容
-- -------------------------------------------------------------
create or replace function public.get_spot_public_reports(p_spot_id uuid)
returns table (
  id         uuid,
  category   text,
  status     text,
  response   text,
  created_at timestamptz,
  handled_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.category, r.status, r.response, r.created_at, r.handled_at
  from public.neighbor_reports r
  join public.feeding_spots s on s.id = r.spot_id
  where r.spot_id = p_spot_id
    and s.status = 'active'
    and r.created_at > now() - interval '180 days'
  order by r.created_at desc
  limit 30;
$$;

-- -------------------------------------------------------------
-- get_my_report_inbox：站內通知（FR-2.2）。我照顧的點收到的通報；管理員看全部
-- -------------------------------------------------------------
create or replace function public.get_my_report_inbox()
returns table (
  id          uuid,
  spot_id     uuid,
  spot_name   text,
  category    text,
  description text,
  status      text,
  response    text,
  created_at  timestamptz,
  handled_at  timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select r.id, r.spot_id, s.name, r.category, r.description, r.status, r.response, r.created_at, r.handled_at
  from neighbor_reports r
  join feeding_spots s on s.id = r.spot_id
  order by (r.status = 'resolved'), r.created_at desc
  limit 200;
$$;

-- -------------------------------------------------------------
-- handle_neighbor_report：照顧者處理通報（改狀態、寫公開回覆）
-- -------------------------------------------------------------
create or replace function public.handle_neighbor_report(
  p_report_id uuid,
  p_status text,
  p_response text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_spot uuid;
begin
  if (select auth.uid()) is null then
    raise exception '請先登入' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('open', 'acknowledged', 'resolved') then
    raise exception '狀態不正確' using errcode = '22023';
  end if;
  if char_length(coalesce(p_response, '')) > 300 then
    raise exception '回覆最多 300 個字' using errcode = '22023';
  end if;

  select spot_id into v_spot from public.neighbor_reports where id = p_report_id;
  if v_spot is null or not (private.is_spot_caretaker(v_spot) or private.is_admin()) then
    -- 不存在與沒權限回同一個訊息，避免用來探測通報 id
    raise exception '找不到這則通報，或你不是該餵食點的照顧者' using errcode = '42501';
  end if;

  update public.neighbor_reports
     set status = p_status,
         response = nullif(trim(coalesce(p_response, '')), ''),
         handled_by = case when p_status = 'open' then null else (select auth.uid()) end,
         handled_at = case when p_status = 'open' then null else now() end
   where id = p_report_id;
end;
$$;

-- =============================================================
-- 交流空間：posts / comments / content_flags（FR-2.3）
--   只有登入者看得到；被檢舉達 3 人自動隱藏，等管理員處理
-- =============================================================
create table public.posts (
  id         uuid primary key default gen_random_uuid(),
  author_id  uuid default auth.uid() references public.profiles (id) on delete set null,
  spot_id    uuid references public.feeding_spots (id) on delete set null,
  title      text not null check (char_length(title) between 1 and 80),
  body       text not null check (char_length(body) between 1 and 2000),
  status     text not null default 'visible' check (status in ('visible', 'hidden')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index posts_created_idx on public.posts (created_at desc);
create index posts_author_idx on public.posts (author_id, created_at desc);
alter table public.posts enable row level security;
create trigger posts_set_updated_at
  before update on public.posts
  for each row execute function private.set_updated_at();

create table public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts (id) on delete cascade,
  author_id  uuid default auth.uid() references public.profiles (id) on delete set null,
  body       text not null check (char_length(body) between 1 and 500),
  status     text not null default 'visible' check (status in ('visible', 'hidden')),
  created_at timestamptz not null default now()
);
create index comments_post_idx on public.comments (post_id, created_at);
create index comments_author_idx on public.comments (author_id, created_at desc);
alter table public.comments enable row level security;

create table public.content_flags (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid references public.posts (id) on delete cascade,
  comment_id  uuid references public.comments (id) on delete cascade,
  reporter_id uuid default auth.uid() references public.profiles (id) on delete set null,
  reason      text not null check (char_length(reason) between 1 and 200),
  status      text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at  timestamptz not null default now(),
  constraint content_flags_one_target check ((post_id is null) <> (comment_id is null)),
  constraint content_flags_once_per_post unique (reporter_id, post_id),
  constraint content_flags_once_per_comment unique (reporter_id, comment_id)
);
create index content_flags_open_idx on public.content_flags (created_at desc) where status = 'open';
alter table public.content_flags enable row level security;

revoke all on public.posts, public.comments, public.content_flags from anon, authenticated;

-- posts：status 不在可寫欄位內，隱藏／恢復只能由管理員走 moderate_content()
grant select, delete on public.posts to authenticated;
grant insert (title, body, spot_id) on public.posts to authenticated;
grant update (title, body) on public.posts to authenticated;

create policy "posts: 可讀未隱藏的貼文"
  on public.posts for select to authenticated
  using (status = 'visible' or author_id = (select auth.uid()) or private.is_admin());
create policy "posts: 登入者可發文"
  on public.posts for insert to authenticated
  with check (author_id = (select auth.uid()));
create policy "posts: 作者可修改自己的貼文"
  on public.posts for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));
create policy "posts: 作者或管理員可刪除"
  on public.posts for delete to authenticated
  using (author_id = (select auth.uid()) or private.is_admin());

grant select, delete on public.comments to authenticated;
grant insert (post_id, body) on public.comments to authenticated;

create policy "comments: 登入者可讀未隱藏的留言"
  on public.comments for select to authenticated
  using (status = 'visible' or author_id = (select auth.uid()) or private.is_admin());
create policy "comments: 登入者可在未隱藏的貼文留言"
  on public.comments for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (select 1 from public.posts p where p.id = post_id and p.status = 'visible')
  );
create policy "comments: 作者或管理員可刪除"
  on public.comments for delete to authenticated
  using (author_id = (select auth.uid()) or private.is_admin());

grant select on public.content_flags to authenticated;
grant insert (post_id, comment_id, reason) on public.content_flags to authenticated;

create policy "content_flags: 本人與管理員可讀"
  on public.content_flags for select to authenticated
  using (reporter_id = (select auth.uid()) or private.is_admin());
create policy "content_flags: 登入者可檢舉"
  on public.content_flags for insert to authenticated
  with check (reporter_id = (select auth.uid()));

-- 發文頻率限制：每人 1 小時 5 篇貼文、30 則留言
create or replace function private.limit_posting()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if tg_table_name = 'posts' then
    select count(*) into v_count from public.posts
     where author_id = new.author_id and created_at > now() - interval '1 hour';
    if v_count >= 5 then
      raise exception '1 小時內最多發 5 篇貼文，請稍後再試' using errcode = 'P0001';
    end if;
  else
    select count(*) into v_count from public.comments
     where author_id = new.author_id and created_at > now() - interval '1 hour';
    if v_count >= 30 then
      raise exception '1 小時內最多留言 30 則，請稍後再試' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
create trigger posts_limit before insert on public.posts
  for each row execute function private.limit_posting();
create trigger comments_limit before insert on public.comments
  for each row execute function private.limit_posting();

-- 同一則內容被 3 個不同的人檢舉就先自動隱藏
create or replace function private.auto_hide_flagged()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.post_id is not null then
    if (select count(*) from public.content_flags where post_id = new.post_id and status = 'open') >= 3 then
      update public.posts set status = 'hidden' where id = new.post_id and status = 'visible';
    end if;
  else
    if (select count(*) from public.content_flags where comment_id = new.comment_id and status = 'open') >= 3 then
      update public.comments set status = 'hidden' where id = new.comment_id and status = 'visible';
    end if;
  end if;
  return new;
end;
$$;
create trigger content_flags_auto_hide after insert on public.content_flags
  for each row execute function private.auto_hide_flagged();

revoke all on function private.limit_posting(), private.auto_hide_flagged() from public, anon, authenticated;

-- -------------------------------------------------------------
-- 管理員：檢舉清單與處理
-- -------------------------------------------------------------
create or replace function public.admin_list_flags()
returns table (
  target_type    text,
  target_id      uuid,
  post_id        uuid,
  title          text,
  excerpt        text,
  author_name    text,
  content_status text,
  flag_count     integer,
  reasons        text,
  last_flagged   timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception '只有管理員可以查看檢舉' using errcode = '42501';
  end if;

  return query
  select 'post'::text, p.id, p.id, p.title, left(p.body, 200), pr.display_name, p.status,
         count(*)::int, string_agg(f.reason, '；' order by f.created_at), max(f.created_at)
  from public.content_flags f
  join public.posts p on p.id = f.post_id
  left join public.profiles pr on pr.id = p.author_id
  where f.status = 'open'
  group by p.id, pr.display_name
  union all
  select 'comment'::text, c.id, c.post_id, p.title, left(c.body, 200), pr.display_name, c.status,
         count(*)::int, string_agg(f.reason, '；' order by f.created_at), max(f.created_at)
  from public.content_flags f
  join public.comments c on c.id = f.comment_id
  join public.posts p on p.id = c.post_id
  left join public.profiles pr on pr.id = c.author_id
  where f.status = 'open'
  group by c.id, p.title, pr.display_name
  order by 10 desc
  limit 200;
end;
$$;

-- p_hide = true：隱藏內容並把檢舉標為已處理；false：恢復顯示並駁回檢舉
create or replace function public.moderate_content(p_target_type text, p_target_id uuid, p_hide boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text := case when p_hide then 'hidden' else 'visible' end;
  v_flag   text := case when p_hide then 'actioned' else 'dismissed' end;
  v_found  integer;
begin
  if not private.is_admin() then
    raise exception '只有管理員可以處理檢舉' using errcode = '42501';
  end if;
  if p_hide is null then
    raise exception '請指定要隱藏還是恢復' using errcode = '22023';
  end if;

  if p_target_type = 'post' then
    update public.posts set status = v_status where id = p_target_id;
    get diagnostics v_found = row_count;
    update public.content_flags set status = v_flag where post_id = p_target_id and status = 'open';
  elsif p_target_type = 'comment' then
    update public.comments set status = v_status where id = p_target_id;
    get diagnostics v_found = row_count;
    update public.content_flags set status = v_flag where comment_id = p_target_id and status = 'open';
  else
    raise exception '類型不正確' using errcode = '22023';
  end if;
  if v_found = 0 then
    raise exception '找不到這則內容' using errcode = 'P0002';
  end if;
end;
$$;

-- -------------------------------------------------------------
-- 權限
-- -------------------------------------------------------------
revoke all on function
  public.submit_neighbor_report(uuid, text, text, text),
  public.report_captcha_required(),
  public.get_spot_public_reports(uuid),
  public.get_my_report_inbox(),
  public.handle_neighbor_report(uuid, text, text),
  public.admin_list_flags(),
  public.moderate_content(text, uuid, boolean)
from public, anon, authenticated;

grant execute on function
  public.submit_neighbor_report(uuid, text, text, text),
  public.report_captcha_required(),
  public.get_spot_public_reports(uuid)
to anon, authenticated;

grant execute on function
  public.get_my_report_inbox(),
  public.handle_neighbor_report(uuid, text, text),
  public.admin_list_flags(),
  public.moderate_content(text, uuid, boolean)
to authenticated;
