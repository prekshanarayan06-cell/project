-- ==============================================================================
-- AI-POWERED AGRICULTURE CROP ADVISORY ASSISTANT (KRISHISAHAYAK AI)
-- COMPLETE PRODUCTION DATABASE MIGRATION SCRIPT FOR SUPABASE POSTGRESQL
-- ==============================================================================

-- 1. Enable UUID Extension
create extension if not exists "uuid-ossp";

-- 2. Custom Enumerated Types
do $$ begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('farmer', 'admin', 'extension_worker');
  end if;
  if not exists (select 1 from pg_type where typname = 'advisory_type') then
    create type advisory_type as enum ('crop', 'soil', 'irrigation', 'pest');
  end if;
end $$;

-- 3. Secure, Non-Recursive Helper Function for Role Retrieval
create or replace function public.get_user_role(user_id uuid)
returns user_role as $$
  select role from public.profiles where id = user_id;
$$ language sql security definer set search_path = public, pg_temp;

-- Revoke execute from public/anon for least-privilege security
revoke execute on function public.get_user_role(uuid) from public;
revoke execute on function public.get_user_role(uuid) from anon;
grant execute on function public.get_user_role(uuid) to authenticated;
grant execute on function public.get_user_role(uuid) to service_role;

-- 4. Profiles Table (Linked to Supabase Auth Users)
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  full_name text not null,
  phone_number text unique,
  role user_role default 'farmer'::user_role not null,
  state text,
  district text,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Protect Role Column from Self-Modification (Fail-Closed)
create or replace function public.prevent_profile_role_self_update()
returns trigger as $$
begin
  if new.role is distinct from old.role then
    if auth.uid() is null or public.get_user_role(auth.uid()) <> 'admin' then
      raise exception 'Unauthorized: Only platform administrators can modify user roles.';
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public, pg_temp;

drop trigger if exists tr_prevent_profile_role_self_update on public.profiles;
create trigger tr_prevent_profile_role_self_update
  before update on public.profiles
  for each row execute function public.prevent_profile_role_self_update();

-- 5. Automatic Profile Provisioning Trigger for New Auth Users
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name, phone_number, state, district, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', 'Farmer'),
    new.raw_user_meta_data->>'phone_number',
    new.raw_user_meta_data->>'state',
    new.raw_user_meta_data->>'district',
    'farmer'::user_role
  )
  on conflict (id) do nothing;
  return new;
end;
$$ language plpgsql security definer set search_path = public, pg_temp;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 6. Farms Table with Composite Unique Constraint for Ownership Verification
create table if not exists public.farms (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  farm_name text not null,
  state text not null,
  district text not null,
  village text,
  farm_size_acres numeric(10,2) not null check (farm_size_acres > 0),
  soil_type text not null,
  irrigation_facility text not null,
  primary_crops text[],
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
  constraint unique_user_farm unique (id, user_id)
);

-- 7. Extension Worker Farm Assignments Table
create table if not exists public.extension_assignments (
  id uuid default uuid_generate_v4() primary key,
  extension_worker_id uuid references public.profiles(id) on delete cascade not null,
  farm_id uuid references public.farms(id) on delete cascade not null,
  assigned_at timestamp with time zone default timezone('utc'::text, now()) not null,
  constraint unique_worker_farm_assignment unique (extension_worker_id, farm_id)
);

-- 8. Advisories History Table with Composite Foreign Key Consistency Check
create table if not exists public.advisories (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  farm_id uuid not null,
  advisory_type advisory_type not null,
  input_payload jsonb not null,
  ai_response jsonb not null,
  image_url text,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  constraint fk_advisories_farm_user foreign key (farm_id, user_id) 
    references public.farms(id, user_id) on delete cascade
);

-- 9. Query Optimization Indexes
create index if not exists idx_farms_user_id on public.farms(user_id);
create index if not exists idx_advisories_user_id on public.advisories(user_id);
create index if not exists idx_advisories_farm_id on public.advisories(farm_id);
create index if not exists idx_advisories_type on public.advisories(advisory_type);
create index if not exists idx_advisories_created_at on public.advisories(created_at desc);
create index if not exists idx_extension_assignments_worker on public.extension_assignments(extension_worker_id);
create index if not exists idx_extension_assignments_farm on public.extension_assignments(farm_id);

-- 10. Automatic Timestamp Trigger
create or replace function public.handle_updated_at()
returns trigger as $$
begin
  new.updated_at = timezone('utc'::text, now());
  return new;
end;
$$ language plpgsql;

drop trigger if exists tr_profiles_updated_at on public.profiles;
create trigger tr_profiles_updated_at
  before update on public.profiles
  for each row execute function public.handle_updated_at();

drop trigger if exists tr_farms_updated_at on public.farms;
create trigger tr_farms_updated_at
  before update on public.farms
  for each row execute function public.handle_updated_at();

-- ==============================================================================
-- 11. ROW LEVEL SECURITY (RLS) POLICIES
-- ==============================================================================

alter table public.profiles enable row level security;
alter table public.farms enable row level security;
alter table public.advisories enable row level security;
alter table public.extension_assignments enable row level security;

-- Profiles Policies
drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "Users can update own profile fields except role" on public.profiles;
create policy "Users can update own profile fields except role" on public.profiles
  for update using (auth.uid() = id);

drop policy if exists "Admins have full access to profiles" on public.profiles;
create policy "Admins have full access to profiles" on public.profiles
  for all using (public.get_user_role(auth.uid()) = 'admin');

drop policy if exists "Extension workers can view profiles of assigned farmers" on public.profiles;
create policy "Extension workers can view profiles of assigned farmers" on public.profiles
  for select using (
    public.get_user_role(auth.uid()) = 'extension_worker' and
    exists (
      select 1 from public.extension_assignments ea
      join public.farms f on f.id = ea.farm_id
      where ea.extension_worker_id = auth.uid() and f.user_id = public.profiles.id
    )
  );

-- Farms Policies
drop policy if exists "Farmers can CRUD own farms" on public.farms;
create policy "Farmers can CRUD own farms" on public.farms
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Authorized Extension Workers can view assigned farms" on public.farms;
create policy "Authorized Extension Workers can view assigned farms" on public.farms
  for select using (
    public.get_user_role(auth.uid()) = 'extension_worker' and
    exists (
      select 1 from public.extension_assignments
      where extension_worker_id = auth.uid() and farm_id = public.farms.id
    )
  );

drop policy if exists "Admins can view all farms" on public.farms;
create policy "Admins can view all farms" on public.farms
  for select using (public.get_user_role(auth.uid()) = 'admin');

-- Extension Assignments Policies
drop policy if exists "Admins can manage extension assignments" on public.extension_assignments;
create policy "Admins can manage extension assignments" on public.extension_assignments
  for all using (public.get_user_role(auth.uid()) = 'admin');

drop policy if exists "Extension workers can view own assignments" on public.extension_assignments;
create policy "Extension workers can view own assignments" on public.extension_assignments
  for select using (auth.uid() = extension_worker_id);

-- Advisories Policies
drop policy if exists "Users can CRUD own advisories" on public.advisories;
create policy "Users can CRUD own advisories" on public.advisories
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Authorized Extension Workers can view assigned farm advisories" on public.advisories;
create policy "Authorized Extension Workers can view assigned farm advisories" on public.advisories
  for select using (
    public.get_user_role(auth.uid()) = 'extension_worker' and
    exists (
      select 1 from public.extension_assignments
      where extension_worker_id = auth.uid() and farm_id = public.advisories.farm_id
    )
  );

drop policy if exists "Admins can view all advisories" on public.advisories;
create policy "Admins can view all advisories" on public.advisories
  for select using (public.get_user_role(auth.uid()) = 'admin');

-- ==============================================================================
-- 12. SECURE PRIVATE STORAGE BUCKET & RLS POLICIES
-- ==============================================================================

insert into storage.buckets (id, name, public) 
values ('pest-images', 'pest-images', false)
on conflict (id) do update set public = false;

drop policy if exists "Farmers can upload pest images to own folder" on storage.objects;
create policy "Farmers can upload pest images to own folder" on storage.objects
  for insert with check (
    bucket_id = 'pest-images' and
    auth.role() = 'authenticated' and
    (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Farmers can view own pest images" on storage.objects;
create policy "Farmers can view own pest images" on storage.objects
  for select using (
    bucket_id = 'pest-images' and
    (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Authorized extension workers can view assigned farm pest images" on storage.objects;
create policy "Authorized extension workers can view assigned farm pest images" on storage.objects
  for select using (
    bucket_id = 'pest-images' and
    public.get_user_role(auth.uid()) = 'extension_worker' and
    exists (
      select 1 from public.extension_assignments ea
      join public.farms f on f.id = ea.farm_id
      where ea.extension_worker_id = auth.uid() 
      and (storage.foldername(name))[1] = f.user_id::text
    )
  );

drop policy if exists "Admins have full access to pest images" on storage.objects;
create policy "Admins have full access to pest images" on storage.objects
  for all using (
    bucket_id = 'pest-images' and
    public.get_user_role(auth.uid()) = 'admin'
  );
