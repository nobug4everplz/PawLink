-- =============================================================
-- 0001 擴充套件、共用函式、profiles
-- 流浪動物資訊共享與保育警示平台（第 9 組）
-- =============================================================

-- PostGIS 放在 Supabase 慣用的 extensions schema
create extension if not exists postgis with schema extensions;

-- 不對外公開（PostgREST 不暴露）的 schema，放 RLS 用的 helper
create schema if not exists private;
grant usage on schema private to anon, authenticated;

-- -------------------------------------------------------------
-- 共用：自動更新 updated_at
-- -------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -------------------------------------------------------------
-- profiles：每個 auth.users 對應一筆
--   role = 'user' | 'admin'
--   「照顧者」不是全域角色，而是 spot_caretakers 中的身分（以餵食點為單位）
-- -------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 30),
  avatar_url   text check (avatar_url is null or char_length(avatar_url) <= 500),
  role         text not null default 'user' check (role in ('user', 'admin')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.profiles is '使用者公開資料；role 只能由管理員透過 set_user_role() 修改';

alter table public.profiles enable row level security;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- 註冊時自動建立 profile（display_name 取註冊時 metadata，否則取 email 前綴）
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(
      coalesce(
        nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
        nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
        '新使用者'
      ),
      30
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();
