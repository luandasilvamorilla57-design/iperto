-- iPerto marketplace schema
-- Prepared for a brand-new, isolated Supabase organization/project only.
-- Do NOT run this against any existing project.

create extension if not exists pgcrypto;

-- =========================
-- Profiles
-- =========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  whatsapp text,
  city text,
  state text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;

create policy "profiles_public_read"
on public.profiles
for select
to anon, authenticated
using (true);

create policy "profiles_owner_insert"
on public.profiles
for insert
to authenticated
with check ((select auth.uid()) = id);

create policy "profiles_owner_update"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

-- Auto-create a profile row when a user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;

create or replace trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- =========================
-- Listings
-- =========================
create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  model text not null check (model ~ '^iPhone '),
  storage_gb integer not null check (storage_gb in (64,128,256,512,1024,2048)),
  color text not null,
  battery_health integer not null check (battery_health between 50 and 100),
  device_condition text not null check (device_condition in ('Impecável','Excelente','Bom','Com marcas de uso')),
  screen_status text not null default 'Original' check (screen_status in ('Original','Trocada original','Trocada paralela','Não informado')),
  face_id_ok boolean not null default true,
  cameras_ok boolean not null default true,
  repair_history text,
  has_box boolean not null default false,
  has_invoice boolean not null default false,
  accessories text,
  description text,
  price_cents integer not null check (price_cents > 0),
  negotiable boolean not null default false,
  city text not null,
  state text not null,
  shipping_enabled boolean not null default false,
  pickup_enabled boolean not null default true,
  status text not null default 'active' check (status in ('draft','active','sold','paused','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists listings_status_created_idx on public.listings(status, created_at desc);
create index if not exists listings_seller_idx on public.listings(seller_id);
create index if not exists listings_location_idx on public.listings(state, city);
create index if not exists listings_model_idx on public.listings(model);

alter table public.listings enable row level security;

grant select on public.listings to anon, authenticated;
grant insert, update, delete on public.listings to authenticated;

create policy "listings_public_active_read"
on public.listings
for select
to anon, authenticated
using (status = 'active' or (select auth.uid()) = seller_id);

create policy "listings_owner_insert"
on public.listings
for insert
to authenticated
with check ((select auth.uid()) = seller_id);

create policy "listings_owner_update"
on public.listings
for update
to authenticated
using ((select auth.uid()) = seller_id)
with check ((select auth.uid()) = seller_id);

create policy "listings_owner_delete"
on public.listings
for delete
to authenticated
using ((select auth.uid()) = seller_id);

-- =========================
-- Listing photos metadata
-- =========================
create table if not exists public.listing_photos (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete cascade,
  storage_path text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (listing_id, storage_path)
);

create index if not exists listing_photos_listing_idx on public.listing_photos(listing_id, sort_order);

alter table public.listing_photos enable row level security;

grant select on public.listing_photos to anon, authenticated;
grant insert, update, delete on public.listing_photos to authenticated;

create policy "listing_photos_public_read"
on public.listing_photos
for select
to anon, authenticated
using (
  exists (
    select 1 from public.listings l
    where l.id = listing_id
      and (l.status = 'active' or l.seller_id = (select auth.uid()))
  )
);

create policy "listing_photos_owner_insert"
on public.listing_photos
for insert
to authenticated
with check (
  exists (
    select 1 from public.listings l
    where l.id = listing_id
      and l.seller_id = (select auth.uid())
  )
);

create policy "listing_photos_owner_update"
on public.listing_photos
for update
to authenticated
using (
  exists (
    select 1 from public.listings l
    where l.id = listing_id
      and l.seller_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.listings l
    where l.id = listing_id
      and l.seller_id = (select auth.uid())
  )
);

create policy "listing_photos_owner_delete"
on public.listing_photos
for delete
to authenticated
using (
  exists (
    select 1 from public.listings l
    where l.id = listing_id
      and l.seller_id = (select auth.uid())
  )
);

-- =========================
-- Favorites
-- =========================
create table if not exists public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

alter table public.favorites enable row level security;

grant select, insert, delete on public.favorites to authenticated;

create policy "favorites_owner_read"
on public.favorites
for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "favorites_owner_insert"
on public.favorites
for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "favorites_owner_delete"
on public.favorites
for delete
to authenticated
using ((select auth.uid()) = user_id);

-- =========================
-- Public listing photo storage
-- =========================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'listing-photos',
  'listing-photos',
  true,
  10485760,
  array['image/jpeg','image/png','image/webp','image/heic']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Files must be stored as: <user_id>/<listing_id>/<filename>
create policy "listing_photo_upload_owner_folder"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'listing-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "listing_photo_update_owner_folder"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'listing-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'listing-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "listing_photo_delete_owner_folder"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'listing-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
