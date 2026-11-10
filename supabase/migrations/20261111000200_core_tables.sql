-- =============================================================
-- 0002 第一階段資料表（profiles 之外的 6 張）
--   feeding_spots / spot_caretakers / feeding_logs
--   animals / spot_animals / animal_photos
-- 每張表建立時即啟用 RLS；政策寫在 0003。
-- =============================================================

-- -------------------------------------------------------------
-- feeding_spots：餵食點（FR-1.1、FR-1.2）
-- -------------------------------------------------------------
create table public.feeding_spots (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 50),
  description text check (description is null or char_length(description) <= 500),
  location    extensions.geography(Point, 4326) not null,
  status      text not null default 'active' check (status in ('active', 'archived')),
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.feeding_spots is '餵食點；精確位置只給登入者，訪客一律經 get_map_spots() 取得 100m 模糊位置';
comment on column public.feeding_spots.status is 'active 使用中；archived 已停用（不顯示在地圖上，以停用取代刪除）';

create index feeding_spots_location_gix on public.feeding_spots using gist (location);
create index feeding_spots_status_idx on public.feeding_spots (status);
create index feeding_spots_created_by_idx on public.feeding_spots (created_by);

alter table public.feeding_spots enable row level security;

create trigger feeding_spots_set_updated_at
  before update on public.feeding_spots
  for each row execute function private.set_updated_at();

-- -------------------------------------------------------------
-- spot_caretakers：照顧者（以餵食點為單位）
--   owner：建點者（自動加入），可管理其他照顧者
--   caretaker：自行加入的照顧者
-- -------------------------------------------------------------
create table public.spot_caretakers (
  spot_id   uuid not null references public.feeding_spots (id) on delete cascade,
  user_id   uuid not null references public.profiles (id) on delete cascade,
  role      text not null default 'caretaker' check (role in ('owner', 'caretaker')),
  joined_at timestamptz not null default now(),
  primary key (spot_id, user_id)
);
create index spot_caretakers_user_idx on public.spot_caretakers (user_id);

alter table public.spot_caretakers enable row level security;

-- 建點後自動把建立者設為 owner
create or replace function private.add_spot_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is not null then
    insert into public.spot_caretakers (spot_id, user_id, role)
    values (new.id, new.created_by, 'owner')
    on conflict (spot_id, user_id) do update set role = 'owner';
  end if;
  return new;
end;
$$;

create trigger feeding_spots_add_owner
  after insert on public.feeding_spots
  for each row execute function private.add_spot_owner();

-- -------------------------------------------------------------
-- feeding_logs：餵食紀錄＋清理回報（FR-1.3、FR-1.6、FR-1.5）
--   id 可由前端產生 UUID，離線補傳時以 id 去重
--   cleaned_at 不為 null 即代表已清理
-- -------------------------------------------------------------
create table public.feeding_logs (
  id         uuid primary key default gen_random_uuid(),
  spot_id    uuid not null references public.feeding_spots (id) on delete cascade,
  user_id    uuid default auth.uid() references public.profiles (id) on delete set null,
  fed_at     timestamptz not null default now(),
  food_type  text not null default 'dry' check (food_type in ('dry', 'wet', 'mixed', 'other')),
  note       text check (note is null or char_length(note) <= 300),
  cleaned_at timestamptz,
  cleaned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  -- 允許離線補傳最多 7 天前的紀錄；不允許未來時間（容許 10 分鐘時鐘誤差）
  constraint feeding_logs_fed_at_range check (
    fed_at <= created_at + interval '10 minutes'
    and fed_at >= created_at - interval '7 days'
  ),
  constraint feeding_logs_cleaned_after_fed check (cleaned_at is null or cleaned_at >= fed_at),
  constraint feeding_logs_cleaned_pair check ((cleaned_at is null) = (cleaned_by is null))
);
comment on table public.feeding_logs is '餵食紀錄；cleaned_at/cleaned_by 為清理回報';

create index feeding_logs_spot_fed_idx on public.feeding_logs (spot_id, fed_at desc);
create index feeding_logs_user_idx on public.feeding_logs (user_id, fed_at desc);
create index feeding_logs_uncleaned_idx on public.feeding_logs (user_id) where cleaned_at is null;

alter table public.feeding_logs enable row level security;

-- -------------------------------------------------------------
-- animals：動物身分檔（FR-1.4）
--   tnr_stage 五階段：
--     1 未結紮　2 誘捕中　3 已手術　4 術後照護　5 已原地回置
--   is_sterilized 由 tnr_stage >= 3 自動計算（「已結紮標記」）
-- -------------------------------------------------------------
create table public.animals (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(name) between 1 and 30),
  species         text not null default 'cat' check (species in ('cat', 'dog', 'other')),
  sex             text not null default 'unknown' check (sex in ('male', 'female', 'unknown')),
  coat            text check (coat is null or char_length(coat) <= 50),
  features        text check (features is null or char_length(features) <= 500),
  ear_tipped      boolean not null default false,
  tnr_stage       smallint not null default 1 check (tnr_stage between 1 and 5),
  is_sterilized   boolean generated always as (tnr_stage >= 3) stored,
  tnr_updated_at  timestamptz,
  status          text not null default 'active' check (status in ('active', 'missing', 'deceased', 'adopted')),
  cover_photo_id  uuid,
  created_by      uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on column public.animals.tnr_stage is '1 未結紮、2 誘捕中、3 已手術、4 術後照護、5 已原地回置';
comment on column public.animals.is_sterilized is '已結紮標記：tnr_stage >= 3';

create index animals_created_by_idx on public.animals (created_by);
create index animals_sterilized_idx on public.animals (is_sterilized);

alter table public.animals enable row level security;

create trigger animals_set_updated_at
  before update on public.animals
  for each row execute function private.set_updated_at();

create or replace function private.touch_tnr_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.tnr_stage is distinct from old.tnr_stage then
    new.tnr_updated_at := now();
  end if;
  return new;
end;
$$;

create trigger animals_touch_tnr
  before insert or update of tnr_stage on public.animals
  for each row execute function private.touch_tnr_updated_at();

-- -------------------------------------------------------------
-- spot_animals：動物出沒的餵食點（多對多）
-- -------------------------------------------------------------
create table public.spot_animals (
  spot_id   uuid not null references public.feeding_spots (id) on delete cascade,
  animal_id uuid not null references public.animals (id) on delete cascade,
  added_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  added_at  timestamptz not null default now(),
  primary key (spot_id, animal_id)
);
create index spot_animals_animal_idx on public.spot_animals (animal_id);

alter table public.spot_animals enable row level security;

-- -------------------------------------------------------------
-- animal_photos：動物照片（第 7 張表）
--   檔案放 Storage bucket「animal-photos」，路徑 {animal_id}/{檔名}
--   前端上傳前須壓縮並去除 EXIF/GPS（NFR-1）
-- -------------------------------------------------------------
create table public.animal_photos (
  id           uuid primary key default gen_random_uuid(),
  animal_id    uuid not null references public.animals (id) on delete cascade,
  storage_path text not null unique,
  caption      text check (caption is null or char_length(caption) <= 100),
  uploaded_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint animal_photos_path_prefix check (storage_path like animal_id::text || '/%')
);
create index animal_photos_animal_idx on public.animal_photos (animal_id, created_at desc);

alter table public.animal_photos enable row level security;

alter table public.animals
  add constraint animals_cover_photo_fk
  foreign key (cover_photo_id) references public.animal_photos (id) on delete set null;
