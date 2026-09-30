
-- ===== 20260924000001_core_schema.sql =====
-- NER Logistics core schema, rebuilt from SRS.md, ML_INTEGRATION_PLAN.md and the queries in the
-- website (web/NER-Website) and Flutter app (ner_logistics). The original base migrations were lost.

create extension if not exists postgis  with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create type public.user_role_enum as enum ('field_officer', 'district_officer', 'control_room', 'rider');

-- Districts / states. Coordinates are optional; ML "near place" lookups use them when present.
create table public.locations (
  id       uuid primary key default gen_random_uuid(),
  name     text not null,
  district text,
  state    text,
  kind     text not null default 'district' check (kind in ('state', 'district', 'town')),
  geom     extensions.geography(Point, 4326),
  unique nulls not distinct (state, district)
);
create index locations_geom_idx on public.locations using gist (geom);

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  full_name    text,
  officer_id   text unique,
  phone        text,
  department   text,
  organization text,
  region       text,
  avatar_url   text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.user_roles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null unique references auth.users (id) on delete cascade,
  role        public.user_role_enum not null,
  district_id uuid references public.locations (id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.routes (
  id           uuid primary key default gen_random_uuid(),
  route_number text not null unique,
  name         text not null,
  origin       text,
  destination  text,
  geom         extensions.geography(LineString, 4326),
  created_at   timestamptz not null default now()
);
create index routes_geom_idx on public.routes using gist (geom);

create table public.shipments (
  id                    uuid primary key default gen_random_uuid(),
  shipment_number       text not null unique,
  status                text not null default 'scheduled'
    check (status in ('scheduled', 'in_transit', 'on_schedule', 'delayed', 'at_risk', 'arrived', 'completed', 'cancelled')),
  risk_level            text check (risk_level in ('low', 'medium', 'high', 'critical')),
  cargo_description     text,
  cargo_weight_kg       numeric,
  origin                text,
  destination           text,
  destination_lat       double precision,
  destination_lng       double precision,
  route_id              uuid references public.routes (id),
  rider_id              uuid references auth.users (id),
  district_id           uuid references public.locations (id),
  estimated_arrival     timestamptz,
  delay_description     text,
  current_location      extensions.geography(Point, 4326),
  current_location_text text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index shipments_rider_idx on public.shipments (rider_id) where rider_id is not null;
create index shipments_route_idx on public.shipments (route_id);

create table public.road_incidents (
  id            uuid primary key default gen_random_uuid(),
  client_id     text unique,                       -- idempotent offline sync (INC-007)
  incident_type text not null
    check (incident_type in ('flood', 'landslide', 'road_blockage', 'accident', 'infrastructure_damage', 'weather', 'vehicle', 'safety', 'other')),
  severity      text not null default 'moderate' check (severity in ('critical', 'high', 'moderate', 'info')),
  description   text,
  location      extensions.geography(Point, 4326),
  route_id      uuid references public.routes (id),
  district_id   uuid references public.locations (id),
  reporter_id   uuid references auth.users (id),
  status        text not null default 'reported'
    check (status in ('reported', 'verified', 'assigned', 'escalated', 'resolved', 'rejected')),
  verified_by   uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index road_incidents_location_idx on public.road_incidents using gist (location);

create table public.alerts (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  description     text,
  severity        text not null default 'moderate' check (severity in ('critical', 'high', 'moderate', 'info')),
  status          text not null default 'active' check (status in ('active', 'acknowledged', 'resolved')),
  source          text not null default 'human' check (source in ('human', 'rule', 'feed', 'ml')),
  district_id     uuid references public.locations (id),
  route_id        uuid references public.routes (id),
  incident_id     uuid references public.road_incidents (id),
  ml_segment_id   text,
  ml_run_id       bigint,
  promoted_by     uuid references auth.users (id),
  acknowledged_by uuid references auth.users (id),
  acknowledged_at timestamptz,
  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now()
);
create unique index alerts_ml_once_idx on public.alerts (ml_segment_id, ml_run_id) where source = 'ml';

create table public.audit_log (
  id        bigint generated always as identity primary key,
  actor_id  uuid,
  action    text not null,
  entity    text,
  entity_id text,
  detail    jsonb,
  at        timestamptz not null default now()
);

-- Riders ---------------------------------------------------------------------------------------
create table public.rider_profiles (
  user_id             uuid primary key references auth.users (id) on delete cascade,
  phone               text,
  vehicle_registration text,
  vehicle_type        text,
  capacity_kg         numeric,
  emergency_contact   text,
  is_on_duty          boolean not null default false,
  active_shipment_id  uuid references public.shipments (id) on delete set null,
  updated_at          timestamptz not null default now()
);

-- Latest fix per rider (Realtime-published).
create table public.rider_locations (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  latitude        double precision not null check (latitude between -90 and 90),
  longitude       double precision not null check (longitude between -180 and 180),
  geom            extensions.geography(Point, 4326) not null,
  accuracy_m      real,
  speed_kmph      real,
  heading_deg     real,
  altitude_m      real,
  battery_percent smallint,
  is_moving       boolean not null default false,
  shipment_id     uuid references public.shipments (id) on delete set null,
  source          text,
  recorded_at     timestamptz not null,           -- device time
  received_at     timestamptz not null default now()
);

-- Append-only trail; client_id makes retried uploads idempotent (LOC-006).
create table public.rider_location_history (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  client_id   text not null,
  latitude    double precision not null,
  longitude   double precision not null,
  accuracy_m  real,
  speed_kmph  real,
  heading_deg real,
  shipment_id uuid references public.shipments (id) on delete set null,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique (user_id, client_id)
);
create index rider_history_trail_idx on public.rider_location_history (user_id, recorded_at desc);
create index rider_history_prune_idx on public.rider_location_history (recorded_at);

-- ===== 20260924000002_auth_rls.sql =====
-- Role helpers, sign-up trigger, RLS and Realtime.

-- Helpers are SECURITY DEFINER so policies can call them without recursing into RLS.
create function public.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select ur.role::text from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  where ur.user_id = auth.uid() and ur.is_active and p.is_active
$$;

create function public.has_role(p_role text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.my_role() = p_role
$$;

create function public.is_officer() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.my_role() in ('field_officer', 'district_officer', 'control_room'), false)
$$;

create function public.is_active_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.my_role() is not null
$$;

create function public.my_district_name() returns text
language sql stable security definer set search_path = '' as $$
  select l.name from public.user_roles ur
  join public.locations l on l.id = ur.district_id
  where ur.user_id = auth.uid() and ur.is_active
$$;

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger profiles_touch      before update on public.profiles       for each row execute function public.touch_updated_at();
create trigger shipments_touch     before update on public.shipments      for each row execute function public.touch_updated_at();
create trigger rider_profiles_touch before update on public.rider_profiles for each row execute function public.touch_updated_at();
create trigger road_incidents_touch before update on public.road_incidents for each row execute function public.touch_updated_at();

-- Sign-up: the clients send full_name, district, state, requested_role, phone, vehicle_registration
-- as auth metadata. Riders and field officers are active straight away. District officers and
-- the control room start INACTIVE until a control-room user activates them (user_roles update
-- policy below), so nobody can self-register into a privileged role.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_role   public.user_role_enum;
  v_loc    uuid;
begin
  v_role := case m->>'requested_role'
    when 'rider'            then 'rider'
    when 'district_officer' then 'district_officer'
    when 'control_room'     then 'control_room'
    else 'field_officer'
  end::public.user_role_enum;

  select l.id into v_loc from public.locations l
  where nullif(trim(m->>'district'), '') is not null
    and lower(l.name) = lower(trim(m->>'district'))
    and (nullif(trim(m->>'state'), '') is null or lower(l.state) = lower(trim(m->>'state')))
  order by l.kind = 'district' desc limit 1;

  insert into public.profiles (id, full_name, officer_id, phone, region)
  values (new.id, nullif(trim(m->>'full_name'), ''), nullif(trim(m->>'officer_id'), ''),
          nullif(trim(m->>'phone'), ''), nullif(trim(coalesce(m->>'district', m->>'state', '')), ''));

  insert into public.user_roles (user_id, role, district_id, is_active)
  values (new.id, v_role, v_loc, v_role in ('rider', 'field_officer'));

  if v_role = 'rider' then
    insert into public.rider_profiles (user_id, phone, vehicle_registration)
    values (new.id, nullif(trim(m->>'phone'), ''), nullif(upper(trim(m->>'vehicle_registration')), ''));
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS ------------------------------------------------------------------------------------------
alter table public.locations               enable row level security;
alter table public.profiles                enable row level security;
alter table public.user_roles              enable row level security;
alter table public.routes                  enable row level security;
alter table public.shipments               enable row level security;
alter table public.road_incidents          enable row level security;
alter table public.alerts                  enable row level security;
alter table public.audit_log               enable row level security;
alter table public.rider_profiles          enable row level security;
alter table public.rider_locations         enable row level security;
alter table public.rider_location_history  enable row level security;

create policy locations_read on public.locations for select to authenticated using (true);

create policy profiles_read_own     on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_read_officer on public.profiles for select to authenticated using (public.is_officer());
create policy profiles_update_own   on public.profiles for update to authenticated
  using (id = auth.uid() and is_active) with check (id = auth.uid() and is_active);
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.has_role('control_room')) with check (public.has_role('control_room'));

create policy user_roles_read_own     on public.user_roles for select to authenticated using (user_id = auth.uid());
create policy user_roles_read_officer on public.user_roles for select to authenticated using (public.is_officer());
create policy user_roles_admin_update on public.user_roles for update to authenticated
  using (public.has_role('control_room')) with check (public.has_role('control_room'));

create policy routes_read  on public.routes for select to authenticated using (public.is_active_user());
create policy routes_write on public.routes for all to authenticated
  using (public.my_role() in ('control_room', 'district_officer'))
  with check (public.my_role() in ('control_room', 'district_officer'));

create policy shipments_officer on public.shipments for select to authenticated using (public.is_officer());
create policy shipments_rider   on public.shipments for select to authenticated
  using (rider_id = auth.uid() and public.has_role('rider'));
create policy shipments_write   on public.shipments for all to authenticated
  using (public.my_role() in ('control_room', 'district_officer'))
  with check (public.my_role() in ('control_room', 'district_officer'));
create policy shipments_rider_update on public.shipments for update to authenticated
  using (rider_id = auth.uid() and public.has_role('rider'))
  with check (rider_id = auth.uid() and public.has_role('rider'));

create policy incidents_read_officer on public.road_incidents for select to authenticated using (public.is_officer());
create policy incidents_read_own     on public.road_incidents for select to authenticated using (reporter_id = auth.uid());
create policy incidents_insert       on public.road_incidents for insert to authenticated
  with check (reporter_id = auth.uid() and public.is_active_user());
create policy incidents_officer_update on public.road_incidents for update to authenticated
  using (public.is_officer()) with check (public.is_officer());

create policy alerts_read   on public.alerts for select to authenticated using (public.is_officer());
create policy alerts_insert on public.alerts for insert to authenticated
  with check (public.is_officer() and created_by = auth.uid() and source = 'human');
create policy alerts_update on public.alerts for update to authenticated
  using (public.is_officer()) with check (public.is_officer());

create policy audit_read on public.audit_log for select to authenticated using (public.has_role('control_room'));

-- Riders: own rows only; officers read all rider rows. Writes go through the RPCs (no write policies).
create policy rider_profiles_own     on public.rider_profiles for select to authenticated using (user_id = auth.uid());
create policy rider_profiles_officer on public.rider_profiles for select to authenticated using (public.is_officer());
create policy rider_locations_own     on public.rider_locations for select to authenticated using (user_id = auth.uid());
create policy rider_locations_officer on public.rider_locations for select to authenticated using (public.is_officer());
create policy rider_history_own     on public.rider_location_history for select to authenticated using (user_id = auth.uid());
create policy rider_history_officer on public.rider_location_history for select to authenticated using (public.is_officer());

-- Realtime -------------------------------------------------------------------------------------
alter table public.rider_locations replica identity full;
alter table public.rider_profiles  replica identity full;
alter publication supabase_realtime add table
  public.rider_locations, public.rider_profiles, public.shipments, public.alerts, public.road_incidents;

-- ===== 20260924000003_rider_rpcs.sql =====
-- Rider tracking RPCs (all SECURITY DEFINER, role-checked; execute is granted in the grants migration).

-- Batch upload from the device queue (single object or array, <= 500 points). Idempotent on
-- (user, client_id); stale fixes never overwrite a newer latest position. Returns points accepted.
create function public.sync_rider_locations(p_points jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_n   integer;
begin
  if v_uid is null or public.my_role() is distinct from 'rider' then
    raise exception 'only riders can upload locations' using errcode = '42501';
  end if;
  if jsonb_typeof(p_points) = 'object' then p_points := jsonb_build_array(p_points); end if;
  if jsonb_typeof(p_points) is distinct from 'array' or jsonb_array_length(p_points) > 500 then
    raise exception 'p_points must be an array of at most 500 points' using errcode = '22023';
  end if;

  with pts as (
    select e->>'client_id' as client_id,
           (e->>'lat')::double precision as lat, (e->>'lng')::double precision as lng,
           (e->>'accuracy_m')::real as acc, (e->>'speed_kmph')::real as spd, (e->>'heading_deg')::real as hdg,
           (e->>'altitude_m')::real as alt, (e->>'battery_percent')::smallint as bat,
           (select s.id from public.shipments s
              where s.id = nullif(e->>'shipment_id', '')::uuid and s.rider_id = v_uid) as ship,
           e->>'source' as src,
           least((e->>'recorded_at')::timestamptz, now() + interval '2 minutes') as rec  -- clamp clock skew
    from jsonb_array_elements(p_points) e
    where nullif(e->>'client_id', '') is not null
      and (e->>'lat')::double precision between -90 and 90
      and (e->>'lng')::double precision between -180 and 180
      and (e->>'recorded_at')::timestamptz > now() - interval '7 days'
  ),
  hist as (
    insert into public.rider_location_history
      (user_id, client_id, latitude, longitude, accuracy_m, speed_kmph, heading_deg, shipment_id, recorded_at)
    select v_uid, client_id, lat, lng, acc, spd, hdg, ship, rec from pts
    on conflict (user_id, client_id) do nothing
  ),
  latest as (
    insert into public.rider_locations
      (user_id, latitude, longitude, geom, accuracy_m, speed_kmph, heading_deg, altitude_m,
       battery_percent, is_moving, shipment_id, source, recorded_at)
    select v_uid, lat, lng, extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography,
           acc, spd, hdg, alt, bat, coalesce(spd, 0) > 3, ship, src, rec
    from pts order by rec desc limit 1
    on conflict (user_id) do update set
      latitude = excluded.latitude, longitude = excluded.longitude, geom = excluded.geom,
      accuracy_m = excluded.accuracy_m, speed_kmph = excluded.speed_kmph, heading_deg = excluded.heading_deg,
      altitude_m = excluded.altitude_m, battery_percent = excluded.battery_percent,
      is_moving = excluded.is_moving, shipment_id = excluded.shipment_id, source = excluded.source,
      recorded_at = excluded.recorded_at, received_at = now()
    where public.rider_locations.recorded_at <= excluded.recorded_at
  )
  select count(*) into v_n from pts;

  update public.shipments s
     set current_location = l.geom
    from public.rider_locations l
   where l.user_id = v_uid and s.id = l.shipment_id and s.rider_id = v_uid;

  return v_n;
end $$;

create function public.set_rider_duty(
  p_on_duty boolean, p_vehicle_registration text default null, p_vehicle_type text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.my_role() is distinct from 'rider' then
    raise exception 'only riders can set duty state' using errcode = '42501';
  end if;
  insert into public.rider_profiles (user_id, is_on_duty, vehicle_registration, vehicle_type)
  values (auth.uid(), p_on_duty, nullif(upper(trim(p_vehicle_registration)), ''), nullif(trim(p_vehicle_type), ''))
  on conflict (user_id) do update set
    is_on_duty = excluded.is_on_duty,
    vehicle_registration = coalesce(excluded.vehicle_registration, public.rider_profiles.vehicle_registration),
    vehicle_type = coalesce(excluded.vehicle_type, public.rider_profiles.vehicle_type);
end $$;

-- Profile + vehicle + open shipments in one call. Null for non-riders.
create function public.get_my_rider_context() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when public.my_role() = 'rider' then jsonb_build_object(
    'profile', (select jsonb_build_object('full_name', p.full_name, 'officer_id', p.officer_id, 'phone', p.phone)
                from public.profiles p where p.id = auth.uid()),
    'rider',   (select to_jsonb(r) - 'updated_at' from public.rider_profiles r where r.user_id = auth.uid()),
    'district', public.my_district_name(),
    'shipments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'shipment_number', s.shipment_number, 'status', s.status, 'risk_level', s.risk_level,
        'cargo_description', s.cargo_description, 'cargo_weight_kg', s.cargo_weight_kg,
        'origin', s.origin, 'destination', s.destination,
        'destination_lat', s.destination_lat, 'destination_lng', s.destination_lng,
        'route_number', r.route_number, 'estimated_arrival', s.estimated_arrival,
        'delay_description', s.delay_description, 'current_location_text', s.current_location_text)
        order by s.estimated_arrival nulls last, s.created_at)
      from public.shipments s left join public.routes r on r.id = s.route_id
      where s.rider_id = auth.uid() and s.status not in ('arrived', 'completed', 'cancelled')), '[]'::jsonb)
  ) end
$$;

-- Officer feed: every rider with a recent fix, joined with identity, vehicle and shipment.
create function public.get_active_riders(p_stale_minutes integer default 30)
returns table (
  user_id uuid, full_name text, officer_id text, phone text, district text,
  vehicle_registration text, vehicle_type text, is_on_duty boolean,
  latitude double precision, longitude double precision, accuracy_m real, speed_kmph real,
  heading_deg real, battery_percent smallint, is_moving boolean,
  recorded_at timestamptz, received_at timestamptz, is_stale boolean,
  shipment_id uuid, shipment_number text, shipment_status text, cargo_description text,
  risk_level text, origin_name text, destination_name text, route_number text,
  estimated_arrival timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_officer() then
    raise exception 'officers only' using errcode = '42501';
  end if;
  return query
  select l.user_id, p.full_name, p.officer_id, coalesce(rp.phone, p.phone), loc.name,
         rp.vehicle_registration, rp.vehicle_type, coalesce(rp.is_on_duty, false),
         l.latitude, l.longitude, l.accuracy_m, l.speed_kmph, l.heading_deg, l.battery_percent, l.is_moving,
         l.recorded_at, l.received_at, l.recorded_at < now() - make_interval(mins => p_stale_minutes),
         s.id, s.shipment_number, s.status, s.cargo_description, s.risk_level,
         s.origin, s.destination, r.route_number, s.estimated_arrival
  from public.rider_locations l
  join public.profiles p on p.id = l.user_id
  left join public.rider_profiles rp on rp.user_id = l.user_id
  left join public.user_roles ur on ur.user_id = l.user_id
  left join public.locations loc on loc.id = ur.district_id
  left join public.shipments s on s.id = l.shipment_id
  left join public.routes r on r.id = s.route_id
  where coalesce(rp.is_on_duty, false) or l.recorded_at > now() - interval '24 hours'
  order by l.recorded_at desc;
end $$;

-- Newest first; the client reverses it into a trail.
create function public.get_rider_trail(p_user_id uuid, p_since timestamptz, p_limit integer default 500)
returns table (latitude double precision, longitude double precision, speed_kmph real, recorded_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_officer() then
    raise exception 'officers only' using errcode = '42501';
  end if;
  return query
  select h.latitude, h.longitude, h.speed_kmph, h.recorded_at
  from public.rider_location_history h
  where h.user_id = p_user_id and h.recorded_at >= p_since
  order by h.recorded_at desc
  limit least(greatest(p_limit, 1), 2000);
end $$;

-- 7-day retention (LOC-007). Not callable through the API (execute is never granted).
create function public.prune_rider_location_history() returns void
language sql security definer set search_path = '' as $$
  delete from public.rider_location_history where recorded_at < now() - interval '7 days'
$$;

do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('prune-rider-location-history', '17 3 * * *',
                        'select public.prune_rider_location_history()');
exception when others then
  raise notice 'pg_cron not scheduled (%). Enable it in Dashboard > Database > Extensions and schedule prune_rider_location_history().', sqlerrm;
end $$;

-- ===== 20260924000004_ml_schema.sql =====
-- ML road-disruption risk storage + the publisher contract used by sih-ml/src/sih_ml/serve/publish.py
-- (design: ML_INTEGRATION_PLAN.md section 5). Scores live in ml_private (never exposed through the API);
-- clients read them only through the SECURITY DEFINER RPCs in the next migration.

create schema if not exists ml_private;

-- The publish job connects as a LOGIN user that is a member of this role (never the service-role key).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'ml_publisher') then
    create role ml_publisher nologin;
  end if;
end $$;

create table public.ml_model_versions (
  id              bigint generated always as identity primary key,
  version         text not null,
  bundle_hash     text not null unique,
  uri             text,
  manifest        jsonb not null,
  policy          jsonb not null,
  registry_status text not null default 'candidate' check (registry_status in ('candidate', 'approved', 'retired')),
  approved_by     uuid references auth.users (id),
  approved_at     timestamptz,
  created_at      timestamptz not null default now()
);

create table public.ml_batch_runs (
  id                         bigint generated always as identity primary key,
  score_date                 date not null,
  mode                       text not null check (mode in ('live', 'replay')),
  model_version_id           bigint references public.ml_model_versions (id),
  bundle_version             text,
  bundle_hash                text not null,
  featurestore_schema_sha256 text,
  n_segments                 integer,
  tier_counts                jsonb not null default '{}',
  drift                      jsonb,
  data_quality               jsonb,
  run                        jsonb not null,                -- the batch's run.json, verbatim
  status                     text not null default 'staging' check (status in ('staging', 'published')),
  is_current                 boolean not null default false,
  published_at               timestamptz,
  expires_at                 timestamptz,                   -- live batches go stale after this; replay never does
  scores_pruned_at           timestamptz,
  unique (score_date, bundle_hash)
);
create unique index ml_batch_runs_one_current on public.ml_batch_runs ((true)) where is_current;

create table public.ml_coverage (
  id         smallint primary key check (id = 1),
  geom       extensions.geography(MultiPolygon, 4326) not null,
  n_cells    integer not null,
  updated_at timestamptz not null default now()
);

create table public.ml_segments (
  segment_id text primary key,
  geom       extensions.geography(Point, 4326) not null,
  slope_deg  real,
  steep      boolean not null default false,
  cell_index integer not null
);
create index ml_segments_geom_idx on public.ml_segments using gist (geom);

-- One partition per published run (created by ml_begin_run, attached by ml_finish_run).
create table ml_private.segment_scores (
  run_id          bigint  not null,
  segment_id      text    not null,
  raw_score       real    not null,
  p_calibrated    real    not null,
  risk_percentile real    not null,
  steep           boolean not null,
  tier            text    not null check (tier in ('none', 'alert', 'human_review')),
  tier_rank       integer not null,
  primary key (run_id, segment_id)
) partition by list (run_id);
create index segment_scores_tier_idx on ml_private.segment_scores (run_id, tier, tier_rank);

-- Audit record of what a user was shown (ML-006 / ML-007).
create table public.ml_route_risk_snapshots (
  id          bigint generated always as identity primary key,
  client_id   text not null unique,
  user_id     uuid not null references auth.users (id),
  context     text not null,
  run_id      bigint,
  route_id    text,
  shipment_id text,
  route_hash  text,
  summary     jsonb not null,
  created_at  timestamptz not null default now()
);

alter table public.ml_model_versions       enable row level security;
alter table public.ml_batch_runs           enable row level security;
alter table public.ml_coverage             enable row level security;
alter table public.ml_segments             enable row level security;
alter table public.ml_route_risk_snapshots enable row level security;

-- Run metadata is harmless and lets every client refresh over Realtime when a new day lands.
create policy ml_runs_read     on public.ml_batch_runs     for select to authenticated using (public.is_active_user());
create policy ml_versions_read on public.ml_model_versions for select to authenticated using (public.is_officer());
create policy ml_coverage_read on public.ml_coverage       for select to authenticated using (public.is_officer());
create policy ml_segments_read on public.ml_segments       for select to authenticated using (public.is_officer());
create policy ml_snapshots_own on public.ml_route_risk_snapshots for select to authenticated
  using (user_id = auth.uid() or public.is_officer());

alter publication supabase_realtime add table public.ml_batch_runs;

-- Publisher functions ---------------------------------------------------------------------------

-- Registers a run and creates its staging table. Returns NULL when (date, bundle) is already published.
create function public.ml_begin_run(p_run jsonb, p_mode text, p_model jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_date  date := (p_run->>'date')::date;
  v_hash  text := p_run->>'bundle_hash';
  v_model bigint;
  v_id    bigint;
begin
  if p_mode not in ('live', 'replay') then
    raise exception 'mode must be live or replay' using errcode = '22023';
  end if;
  if v_date is null or v_hash is null then
    raise exception 'run.json needs date and bundle_hash' using errcode = '22023';
  end if;
  if exists (select 1 from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'published') then
    return null;
  end if;

  insert into public.ml_model_versions (version, bundle_hash, uri, manifest, policy)
  values (coalesce(p_run->>'bundle_version', p_model->'manifest'->>'version', v_hash), v_hash,
          p_model->>'uri', p_model->'manifest', p_model->'policy')
  on conflict (bundle_hash) do update set manifest = excluded.manifest, policy = excluded.policy, uri = excluded.uri
  returning id into v_model;

  delete from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'staging';
  insert into public.ml_batch_runs
    (score_date, mode, model_version_id, bundle_version, bundle_hash, featurestore_schema_sha256, n_segments,
     tier_counts, drift, data_quality, run, expires_at)
  values (v_date, p_mode, v_model, p_run->>'bundle_version', v_hash, p_run->>'featurestore_schema_sha256',
          (p_run->>'n_segments')::int, coalesce(p_run->'tiers', '{}'), p_run->'drift', p_run->'data_quality', p_run,
          case when p_mode = 'live' then ((v_date + 2)::timestamp at time zone 'Asia/Kolkata') end)
  returning id into v_id;

  execute format('drop table if exists ml_private.scores_r%s', v_id);
  execute format('create table ml_private.scores_r%s (like ml_private.segment_scores including constraints)', v_id);
  execute format('grant insert on ml_private.scores_r%s to ml_publisher', v_id);
  return v_id;
end $$;

-- Validates the loaded rows against run.json, attaches the partition and (optionally) makes it current.
create function public.ml_finish_run(p_run_id bigint, p_set_current boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r      public.ml_batch_runs;
  v_rows bigint;
  v_tiers jsonb;
  old    record;
begin
  select * into r from public.ml_batch_runs where id = p_run_id and status = 'staging';
  if not found then
    raise exception 'run % is not staging', p_run_id using errcode = 'P0002';
  end if;

  execute format('select count(*) from ml_private.scores_r%s', p_run_id) into v_rows;
  execute format('select coalesce(jsonb_object_agg(tier, n), ''{}''::jsonb) '
                 'from (select tier, count(*) n from ml_private.scores_r%s group by tier) t', p_run_id) into v_tiers;

  if r.n_segments is not null and v_rows <> r.n_segments then
    raise exception 'run %: % rows loaded but run.json says %', p_run_id, v_rows, r.n_segments using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each_text(r.tier_counts) k where (v_tiers->>k.key)::bigint is distinct from k.value::bigint) then
    raise exception 'run %: tier counts % differ from run.json %', p_run_id, v_tiers, r.tier_counts using errcode = '22023';
  end if;

  execute format('alter table ml_private.segment_scores attach partition ml_private.scores_r%s for values in (%s)',
                 p_run_id, p_run_id);
  update public.ml_batch_runs set status = 'published', published_at = now(), tier_counts = v_tiers where id = p_run_id;
  if p_set_current then perform public.ml_set_current(p_run_id); end if;

  -- 30-day retention for live days; replay days are kept until replaced.
  for old in select id from public.ml_batch_runs
             where mode = 'live' and status = 'published' and not is_current and scores_pruned_at is null
               and score_date < current_date - 30 loop
    execute format('drop table if exists ml_private.scores_r%s', old.id);
    update public.ml_batch_runs set scores_pruned_at = now() where id = old.id;
  end loop;

  return jsonb_build_object('run_id', p_run_id, 'rows', v_rows, 'tiers', v_tiers, 'current', p_set_current);
end $$;

create function public.ml_set_current(p_run_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ml_batch_runs where id = p_run_id and status = 'published' and scores_pruned_at is null) then
    raise exception 'run % is not a published run with scores', p_run_id using errcode = 'P0002';
  end if;
  update public.ml_batch_runs set is_current = false where is_current and id <> p_run_id;
  update public.ml_batch_runs set is_current = true where id = p_run_id;
end $$;

-- What the publisher itself needs beyond the functions above.
grant usage on schema public, extensions, ml_private to ml_publisher;
grant select on public.ml_batch_runs to ml_publisher;
grant select, insert, update, truncate on public.ml_segments to ml_publisher;
grant select, insert, update on public.ml_coverage to ml_publisher;
grant execute on function public.ml_begin_run(jsonb, text, jsonb), public.ml_finish_run(bigint, boolean),
                          public.ml_set_current(bigint) to ml_publisher;

-- ===== 20260924000005_ml_rpcs.sql =====
-- ML read RPCs shared by the website (src/lib/ml.ts) and the Flutter app (ml_repository.dart).
-- All SECURITY DEFINER: the database decides what each role sees. Riders never read ml_* tables;
-- they get only their assigned routes or a line they planned themselves.

create function public.ml_pick_run(p_date date default null) returns public.ml_batch_runs
language sql stable security definer set search_path = '' as $$
  select r.* from public.ml_batch_runs r
  where r.status = 'published' and r.scores_pruned_at is null
    and case when p_date is null then r.is_current else r.score_date = p_date end
  order by r.published_at desc limit 1
$$;

-- Every ML answer carries this, so clients can label live / replay / stale / unavailable (ML-008).
create function public.ml_meta(r public.ml_batch_runs) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when r.id is null then jsonb_build_object('state', 'unavailable') else jsonb_build_object(
    'state', case when r.mode = 'replay' then 'replay'
                  when r.expires_at is not null and r.expires_at < now() then 'stale' else 'live' end,
    'run_id', r.id, 'score_date', r.score_date, 'mode', r.mode,
    'model_version', r.bundle_version, 'bundle_hash', r.bundle_hash,
    'published_at', r.published_at, 'expires_at', r.expires_at,
    'caveat', (select mv.policy->>'probability_caveat' from public.ml_model_versions mv where mv.id = r.model_version_id)
  ) end
$$;

-- Risk along one line: matches segments within p_buffer metres, summarises them and lists the
-- alert / review segments in order along the line. Internal; called by the RPCs below.
create function public.ml_route_risk(p_line extensions.geography, p_run public.ml_batch_runs, p_buffer integer)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_geom  extensions.geometry := p_line::extensions.geometry;
  v_len   double precision := extensions.st_length(p_line);
  v_cov   double precision;
  v_n     integer; v_alert integer; v_review integer; v_max real;
  v_worst jsonb; v_segs jsonb; v_band text;
begin
  select extensions.st_length(extensions.st_intersection(v_geom, c.geom::extensions.geometry)::extensions.geography)
         / nullif(v_len, 0)
    into v_cov from public.ml_coverage c where c.id = 1;
  v_cov := coalesce(v_cov, 0);

  with m as (
    select s.segment_id, sc.risk_percentile, sc.tier, sc.tier_rank, s.steep,
           extensions.st_y(s.geom::extensions.geometry) as lat,
           extensions.st_x(s.geom::extensions.geometry) as lon,
           round((extensions.st_linelocatepoint(v_geom, s.geom::extensions.geometry) * v_len)::numeric) as along_m
    from public.ml_segments s
    join ml_private.segment_scores sc on sc.run_id = p_run.id and sc.segment_id = s.segment_id
    where extensions.st_dwithin(s.geom, p_line, p_buffer)
  )
  select count(*), count(*) filter (where tier = 'alert'), count(*) filter (where tier = 'human_review'),
         max(risk_percentile),
         (select to_jsonb(w) from (select segment_id, along_m, lat, lon, risk_percentile, tier, steep
                                   from m order by risk_percentile desc limit 1) w),
         coalesce((select jsonb_agg(to_jsonb(x) order by x.along_m)
                   from (select segment_id, along_m, lat, lon, risk_percentile, tier, steep
                         from m where tier <> 'none' order by tier_rank limit 500) x), '[]'::jsonb)
    into v_n, v_alert, v_review, v_max, v_worst, v_segs
    from m;

  v_band := case when v_cov = 0 then 'no_coverage' when v_alert > 0 then 'high'
                 when v_review > 0 then 'review' else 'low' end;
  return jsonb_build_object(
    'route_length_m', round(v_len::numeric), 'buffer_m', p_buffer,
    'coverage_fraction', round(v_cov::numeric, 3),
    'summary', jsonb_build_object('n_matched', v_n, 'n_alert', v_alert, 'n_human_review', v_review,
                                  'max_percentile', v_max, 'band', v_band, 'worst', v_worst),
    'segments', v_segs);
end $$;

create function public.ml_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  if v_run.id is null then return public.ml_meta(v_run); end if;
  return public.ml_meta(v_run) || jsonb_build_object(
    'tier_counts', v_run.tier_counts,
    'alert_capacity', 20,   -- N shown per day is a policy decision with MDoNER (plan B5)
    'coverage_bbox', (select jsonb_build_array(extensions.st_xmin(g::extensions.box3d), extensions.st_ymin(g::extensions.box3d),
                                               extensions.st_xmax(g::extensions.box3d), extensions.st_ymax(g::extensions.box3d))
                      from (select c.geom::extensions.geometry as g from public.ml_coverage c where c.id = 1) q));
end $$;

-- Route by id / route_number (riders: only their own open shipment's route) or a GeoJSON LineString
-- the app planned (any signed-in role).
create function public.get_route_ml_risk(
  p_route_id text default null, p_geojson jsonb default null, p_date date default null, p_buffer_m integer default 100
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_run   public.ml_batch_runs;
  v_route public.routes;
  v_line  extensions.geography;
  v_g     extensions.geometry;
  v_buf   integer := least(greatest(coalesce(p_buffer_m, 100), 10), 1000);
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;

  if p_route_id is not null then
    select * into v_route from public.routes r where r.id::text = p_route_id or r.route_number = p_route_id limit 1;
    if v_route.id is null or v_route.geom is null then
      raise exception 'unknown route or route has no geometry' using errcode = 'P0002';
    end if;
    if public.my_role() = 'rider' and not exists (
         select 1 from public.shipments s where s.rider_id = auth.uid() and s.route_id = v_route.id
           and s.status not in ('arrived', 'completed', 'cancelled')) then
      raise exception 'route is not assigned to you' using errcode = '42501';
    end if;
    v_line := v_route.geom;
  elsif p_geojson is not null then
    v_g := extensions.st_setsrid(extensions.st_geomfromgeojson(p_geojson::text), 4326);
    if extensions.geometrytype(v_g) <> 'LINESTRING' or extensions.st_npoints(v_g) > 5000 then
      raise exception 'p_geojson must be a LineString with at most 5000 points' using errcode = '22023';
    end if;
    v_line := v_g::extensions.geography;
  else
    raise exception 'give p_route_id or p_geojson' using errcode = '22023';
  end if;

  v_run := public.ml_pick_run(p_date);
  if v_run.id is null then
    return public.ml_meta(v_run) || jsonb_build_object('route_id', v_route.id::text);
  end if;
  return public.ml_meta(v_run) || jsonb_build_object('route_id', v_route.id::text)
         || public.ml_route_risk(v_line, v_run, v_buf);
end $$;

-- Officers: every stored route with geometry.
create function public.get_routes_ml_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  return public.ml_meta(v_run) || jsonb_build_object('routes', case when v_run.id is null then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('route_id', r.id, 'route_number', r.route_number, 'name', r.name)
                     || public.ml_route_risk(r.geom, v_run, 100) order by r.route_number)
    from public.routes r where r.geom is not null), '[]'::jsonb) end);
end $$;

-- Riders: the route of each open shipment assigned to them.
create function public.get_my_routes_ml_risk() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  return public.ml_meta(v_run) || jsonb_build_object('routes', case when v_run.id is null then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('shipment_id', s.id, 'shipment_number', s.shipment_number,
                                        'shipment_status', s.status, 'route_id', r.id,
                                        'route_number', r.route_number, 'name', r.name)
                     || public.ml_route_risk(r.geom, v_run, 100) order by s.created_at)
    from public.shipments s join public.routes r on r.id = s.route_id
    where s.rider_id = auth.uid() and r.geom is not null
      and s.status not in ('arrived', 'completed', 'cancelled')), '[]'::jsonb) end);
end $$;

-- Officers: top-N segments of a tier by tier_rank, with the nearest place (needs locations.geom).
create function public.get_ml_top_alerts(
  p_date date default null, p_tier text default 'alert', p_limit integer default 20, p_district text default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs; v_n bigint; v_rows jsonb;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  if p_tier not in ('alert', 'human_review') then raise exception 'tier must be alert or human_review' using errcode = '22023'; end if;
  v_run := public.ml_pick_run(p_date);
  if v_run.id is null then
    return public.ml_meta(v_run) || jsonb_build_object('tier', p_tier, 'scope', 'region', 'capacity', 0, 'n_in_tier', 0, 'rows', '[]'::jsonb);
  end if;

  select count(*) into v_n from ml_private.segment_scores where run_id = v_run.id and tier = p_tier;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.tier_rank), '[]'::jsonb) into v_rows from (
    select sc.tier_rank, s.segment_id,
           extensions.st_y(s.geom::extensions.geometry) as lat, extensions.st_x(s.geom::extensions.geometry) as lon,
           sc.risk_percentile, sc.tier, sc.steep,
           near.name as near_place, near.district as near_district, near.state as near_state,
           round(near.km::numeric, 1) as near_km, a.id::text as promoted_alert_id
    from ml_private.segment_scores sc
    join public.ml_segments s on s.segment_id = sc.segment_id
    left join lateral (
      select l.name, l.district, l.state, extensions.st_distance(l.geom, s.geom) / 1000 as km
      from public.locations l where l.geom is not null
      order by l.geom operator(extensions.<->) s.geom limit 1) near on true
    left join public.alerts a on a.source = 'ml' and a.ml_segment_id = sc.segment_id and a.ml_run_id = v_run.id
    where sc.run_id = v_run.id and sc.tier = p_tier and (p_district is null or near.district = p_district)
    order by sc.tier_rank
    limit least(greatest(p_limit, 1), 200)) t;

  return public.ml_meta(v_run) || jsonb_build_object(
    'tier', p_tier, 'scope', coalesce('district:' || p_district, 'region'),
    'capacity', least(greatest(p_limit, 1), 200), 'n_in_tier', v_n, 'rows', v_rows);
end $$;

-- Officers: map points for the ML layer inside a bounding box.
create function public.get_ml_segments_in_bbox(
  p_west double precision, p_south double precision, p_east double precision, p_north double precision,
  p_min_tier text default 'human_review', p_limit integer default 1000
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  if v_run.id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'segment_id', s.segment_id, 'lat', extensions.st_y(s.geom::extensions.geometry),
             'lon', extensions.st_x(s.geom::extensions.geometry),
             'risk_percentile', sc.risk_percentile, 'tier', sc.tier, 'steep', sc.steep) order by sc.tier_rank)
    from (select * from ml_private.segment_scores x
          where x.run_id = v_run.id and (x.tier = 'alert' or (p_min_tier = 'human_review' and x.tier = 'human_review'))
          order by x.tier_rank limit 50000) sc
    join public.ml_segments s on s.segment_id = sc.segment_id
    where s.geom operator(extensions.&&) extensions.st_makeenvelope(p_west, p_south, p_east, p_north, 4326)::extensions.geography
    limit least(greatest(p_limit, 1), 5000)), '[]'::jsonb);
end $$;

-- Control room / district officers turn one segment into an operational alert (never automatic, B5).
create function public.promote_ml_alert(p_segment_id text, p_run_id bigint default null, p_note text default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_run public.ml_batch_runs;
  v_tier text; v_pct real; v_id uuid;
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'only the control room or district officers can promote ML alerts' using errcode = '42501';
  end if;
  if p_run_id is null then v_run := public.ml_pick_run(null);
  else select * into v_run from public.ml_batch_runs r where r.id = p_run_id and r.status = 'published' and r.scores_pruned_at is null;
  end if;
  if v_run.id is null then raise exception 'no published ML run' using errcode = 'P0002'; end if;

  select sc.tier, sc.risk_percentile into v_tier, v_pct
  from ml_private.segment_scores sc where sc.run_id = v_run.id and sc.segment_id = p_segment_id;
  if v_tier is null or v_tier = 'none' then
    raise exception 'segment % is not in an alert tier for run %', p_segment_id, v_run.id using errcode = '22023';
  end if;

  insert into public.alerts (title, description, severity, source, ml_segment_id, ml_run_id, promoted_by, created_by)
  values ('ML road-disruption risk: segment ' || p_segment_id,
          format('Model %s, scores of %s (%s). Risk percentile %s.%s', v_run.bundle_version, v_run.score_date, v_run.mode,
                 round(v_pct::numeric, 2), coalesce(' Note: ' || p_note, '')),
          case v_tier when 'alert' then 'high' else 'moderate' end, 'ml', p_segment_id, v_run.id, auth.uid(), auth.uid())
  on conflict (ml_segment_id, ml_run_id) where source = 'ml' do nothing
  returning id into v_id;

  if v_id is null then
    select a.id into v_id from public.alerts a where a.source = 'ml' and a.ml_segment_id = p_segment_id and a.ml_run_id = v_run.id;
  else
    insert into public.audit_log (actor_id, action, entity, entity_id, detail)
    values (auth.uid(), 'ml_alert_promoted', 'alerts', v_id::text,
            jsonb_build_object('segment_id', p_segment_id, 'run_id', v_run.id, 'tier', v_tier, 'note', p_note));
  end if;
  return v_id::text;
end $$;

-- Audit record of what a rider or officer was shown (ML-006 / ML-007). Idempotent on p_client_id.
create function public.record_route_risk_snapshot(
  p_client_id text, p_context text, p_summary jsonb,
  p_run_id bigint default null, p_route_id text default null, p_shipment_id text default null,
  p_route_hash text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  insert into public.ml_route_risk_snapshots (client_id, user_id, context, run_id, route_id, shipment_id, route_hash, summary)
  values (p_client_id, auth.uid(), p_context, p_run_id, p_route_id, p_shipment_id, p_route_hash, p_summary)
  on conflict (client_id) do nothing;
end $$;

-- ===== 20260924000006_grants.sql =====
-- Data API grants. New Supabase projects do not auto-grant table or function access, so nothing
-- works until this runs. RLS (enabled on every table) stays the real boundary.

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Tables written only by RPCs / triggers / the publisher: clients get read access at most.
revoke insert, update, delete on
  public.ml_model_versions, public.ml_batch_runs, public.ml_coverage, public.ml_segments,
  public.ml_route_risk_snapshots, public.rider_locations, public.rider_location_history,
  public.rider_profiles, public.audit_log, public.locations
from authenticated;
revoke insert, delete on public.user_roles, public.profiles from authenticated;

-- Functions: closed by default, then open the client-facing ones to signed-in users only.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

grant execute on function
  public.my_role(), public.has_role(text), public.is_officer(), public.is_active_user(), public.my_district_name(),
  public.sync_rider_locations(jsonb), public.set_rider_duty(boolean, text, text), public.get_my_rider_context(),
  public.get_active_riders(integer), public.get_rider_trail(uuid, timestamptz, integer),
  public.ml_status(), public.get_route_ml_risk(text, jsonb, date, integer), public.get_routes_ml_summary(),
  public.get_my_routes_ml_risk(), public.get_ml_top_alerts(date, text, integer, text),
  public.get_ml_segments_in_bbox(double precision, double precision, double precision, double precision, text, integer),
  public.promote_ml_alert(text, bigint, text),
  public.record_route_risk_snapshot(text, text, jsonb, bigint, text, text, text)
to authenticated;

-- Guard: fail the migration if any public table was left without RLS.
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity loop
    raise exception 'RLS is not enabled on public.%', t;
  end loop;
end $$;

-- ===== 20260924000007_seed_locations.sql =====
-- NE India states and districts (from northeast_india_districts.csv). Coordinates are not included;
-- add locations.geom to enable the ML "near place" lookup.
insert into public.locations (name, district, state, kind) values
  ('Arunachal Pradesh', null, 'Arunachal Pradesh', 'state'),
  ('Assam', null, 'Assam', 'state'),
  ('Manipur', null, 'Manipur', 'state'),
  ('Meghalaya', null, 'Meghalaya', 'state'),
  ('Mizoram', null, 'Mizoram', 'state'),
  ('Nagaland', null, 'Nagaland', 'state'),
  ('Tripura', null, 'Tripura', 'state'),
  ('Sikkim', null, 'Sikkim', 'state'),
  ('Anjaw', 'Anjaw', 'Arunachal Pradesh', 'district'),
  ('Bichom', 'Bichom', 'Arunachal Pradesh', 'district'),
  ('Changlang', 'Changlang', 'Arunachal Pradesh', 'district'),
  ('Dibang Valley', 'Dibang Valley', 'Arunachal Pradesh', 'district'),
  ('East Kameng', 'East Kameng', 'Arunachal Pradesh', 'district'),
  ('East Siang', 'East Siang', 'Arunachal Pradesh', 'district'),
  ('Kamle', 'Kamle', 'Arunachal Pradesh', 'district'),
  ('Keyi Panyor', 'Keyi Panyor', 'Arunachal Pradesh', 'district'),
  ('Kra Daadi', 'Kra Daadi', 'Arunachal Pradesh', 'district'),
  ('Kurung Kumey', 'Kurung Kumey', 'Arunachal Pradesh', 'district'),
  ('Lepa Rada', 'Lepa Rada', 'Arunachal Pradesh', 'district'),
  ('Lohit', 'Lohit', 'Arunachal Pradesh', 'district'),
  ('Longding', 'Longding', 'Arunachal Pradesh', 'district'),
  ('Lower Dibang Valley', 'Lower Dibang Valley', 'Arunachal Pradesh', 'district'),
  ('Lower Siang', 'Lower Siang', 'Arunachal Pradesh', 'district'),
  ('Lower Subansiri', 'Lower Subansiri', 'Arunachal Pradesh', 'district'),
  ('Namsai', 'Namsai', 'Arunachal Pradesh', 'district'),
  ('Pakke-Kessang', 'Pakke-Kessang', 'Arunachal Pradesh', 'district'),
  ('Papum Pare', 'Papum Pare', 'Arunachal Pradesh', 'district'),
  ('Shi Yomi', 'Shi Yomi', 'Arunachal Pradesh', 'district'),
  ('Siang', 'Siang', 'Arunachal Pradesh', 'district'),
  ('Tawang', 'Tawang', 'Arunachal Pradesh', 'district'),
  ('Tirap', 'Tirap', 'Arunachal Pradesh', 'district'),
  ('Upper Siang', 'Upper Siang', 'Arunachal Pradesh', 'district'),
  ('Upper Subansiri', 'Upper Subansiri', 'Arunachal Pradesh', 'district'),
  ('West Kameng', 'West Kameng', 'Arunachal Pradesh', 'district'),
  ('West Siang', 'West Siang', 'Arunachal Pradesh', 'district'),
  ('Itanagar Capital Complex', 'Itanagar Capital Complex', 'Arunachal Pradesh', 'district'),
  ('Baksa', 'Baksa', 'Assam', 'district'),
  ('Bajali', 'Bajali', 'Assam', 'district'),
  ('Barpeta', 'Barpeta', 'Assam', 'district'),
  ('Biswanath', 'Biswanath', 'Assam', 'district'),
  ('Bongaigaon', 'Bongaigaon', 'Assam', 'district'),
  ('Cachar', 'Cachar', 'Assam', 'district'),
  ('Charaideo', 'Charaideo', 'Assam', 'district'),
  ('Chirang', 'Chirang', 'Assam', 'district'),
  ('Darrang', 'Darrang', 'Assam', 'district'),
  ('Dhemaji', 'Dhemaji', 'Assam', 'district'),
  ('Dhubri', 'Dhubri', 'Assam', 'district'),
  ('Dibrugarh', 'Dibrugarh', 'Assam', 'district'),
  ('Dima Hasao', 'Dima Hasao', 'Assam', 'district'),
  ('Goalpara', 'Goalpara', 'Assam', 'district'),
  ('Golaghat', 'Golaghat', 'Assam', 'district'),
  ('Hailakandi', 'Hailakandi', 'Assam', 'district'),
  ('Hojai', 'Hojai', 'Assam', 'district'),
  ('Jorhat', 'Jorhat', 'Assam', 'district'),
  ('Kamrup', 'Kamrup', 'Assam', 'district'),
  ('Kamrup Metropolitan', 'Kamrup Metropolitan', 'Assam', 'district'),
  ('Karbi Anglong', 'Karbi Anglong', 'Assam', 'district'),
  ('Kokrajhar', 'Kokrajhar', 'Assam', 'district'),
  ('Lakhimpur', 'Lakhimpur', 'Assam', 'district'),
  ('Majuli', 'Majuli', 'Assam', 'district'),
  ('Morigaon', 'Morigaon', 'Assam', 'district'),
  ('Nagaon', 'Nagaon', 'Assam', 'district'),
  ('Nalbari', 'Nalbari', 'Assam', 'district'),
  ('Sivasagar', 'Sivasagar', 'Assam', 'district'),
  ('Sonitpur', 'Sonitpur', 'Assam', 'district'),
  ('South Salmara-Mankachar', 'South Salmara-Mankachar', 'Assam', 'district'),
  ('Sribhumi', 'Sribhumi', 'Assam', 'district'),
  ('Tamulpur', 'Tamulpur', 'Assam', 'district'),
  ('Tinsukia', 'Tinsukia', 'Assam', 'district'),
  ('Udalguri', 'Udalguri', 'Assam', 'district'),
  ('West Karbi Anglong', 'West Karbi Anglong', 'Assam', 'district'),
  ('Bishnupur', 'Bishnupur', 'Manipur', 'district'),
  ('Chandel', 'Chandel', 'Manipur', 'district'),
  ('Churachandpur', 'Churachandpur', 'Manipur', 'district'),
  ('Imphal East', 'Imphal East', 'Manipur', 'district'),
  ('Imphal West', 'Imphal West', 'Manipur', 'district'),
  ('Jiribam', 'Jiribam', 'Manipur', 'district'),
  ('Kakching', 'Kakching', 'Manipur', 'district'),
  ('Kamjong', 'Kamjong', 'Manipur', 'district'),
  ('Kangpokpi', 'Kangpokpi', 'Manipur', 'district'),
  ('Noney', 'Noney', 'Manipur', 'district'),
  ('Pherzawl', 'Pherzawl', 'Manipur', 'district'),
  ('Senapati', 'Senapati', 'Manipur', 'district'),
  ('Tamenglong', 'Tamenglong', 'Manipur', 'district'),
  ('Tengnoupal', 'Tengnoupal', 'Manipur', 'district'),
  ('Thoubal', 'Thoubal', 'Manipur', 'district'),
  ('Ukhrul', 'Ukhrul', 'Manipur', 'district'),
  ('East Garo Hills', 'East Garo Hills', 'Meghalaya', 'district'),
  ('East Jaintia Hills', 'East Jaintia Hills', 'Meghalaya', 'district'),
  ('East Khasi Hills', 'East Khasi Hills', 'Meghalaya', 'district'),
  ('Eastern West Khasi Hills', 'Eastern West Khasi Hills', 'Meghalaya', 'district'),
  ('North Garo Hills', 'North Garo Hills', 'Meghalaya', 'district'),
  ('Ri Bhoi', 'Ri Bhoi', 'Meghalaya', 'district'),
  ('South Garo Hills', 'South Garo Hills', 'Meghalaya', 'district'),
  ('South West Garo Hills', 'South West Garo Hills', 'Meghalaya', 'district'),
  ('South West Khasi Hills', 'South West Khasi Hills', 'Meghalaya', 'district'),
  ('West Garo Hills', 'West Garo Hills', 'Meghalaya', 'district'),
  ('West Jaintia Hills', 'West Jaintia Hills', 'Meghalaya', 'district'),
  ('West Khasi Hills', 'West Khasi Hills', 'Meghalaya', 'district'),
  ('Aizawl', 'Aizawl', 'Mizoram', 'district'),
  ('Champhai', 'Champhai', 'Mizoram', 'district'),
  ('Hnahthial', 'Hnahthial', 'Mizoram', 'district'),
  ('Khawzawl', 'Khawzawl', 'Mizoram', 'district'),
  ('Kolasib', 'Kolasib', 'Mizoram', 'district'),
  ('Lawngtlai', 'Lawngtlai', 'Mizoram', 'district'),
  ('Lunglei', 'Lunglei', 'Mizoram', 'district'),
  ('Mamit', 'Mamit', 'Mizoram', 'district'),
  ('Saitual', 'Saitual', 'Mizoram', 'district'),
  ('Serchhip', 'Serchhip', 'Mizoram', 'district'),
  ('Siaha', 'Siaha', 'Mizoram', 'district'),
  ('Chumoukedima', 'Chumoukedima', 'Nagaland', 'district'),
  ('Dimapur', 'Dimapur', 'Nagaland', 'district'),
  ('Kiphire', 'Kiphire', 'Nagaland', 'district'),
  ('Kohima', 'Kohima', 'Nagaland', 'district'),
  ('Longleng', 'Longleng', 'Nagaland', 'district'),
  ('Meluri', 'Meluri', 'Nagaland', 'district'),
  ('Mokokchung', 'Mokokchung', 'Nagaland', 'district'),
  ('Mon', 'Mon', 'Nagaland', 'district'),
  ('Niuland', 'Niuland', 'Nagaland', 'district'),
  ('Noklak', 'Noklak', 'Nagaland', 'district'),
  ('Peren', 'Peren', 'Nagaland', 'district'),
  ('Phek', 'Phek', 'Nagaland', 'district'),
  ('Shamator', 'Shamator', 'Nagaland', 'district'),
  ('Tseminyu', 'Tseminyu', 'Nagaland', 'district'),
  ('Tuensang', 'Tuensang', 'Nagaland', 'district'),
  ('Wokha', 'Wokha', 'Nagaland', 'district'),
  ('Zunheboto', 'Zunheboto', 'Nagaland', 'district'),
  ('Dhalai', 'Dhalai', 'Tripura', 'district'),
  ('Gomati', 'Gomati', 'Tripura', 'district'),
  ('Khowai', 'Khowai', 'Tripura', 'district'),
  ('North Tripura', 'North Tripura', 'Tripura', 'district'),
  ('Sepahijala', 'Sepahijala', 'Tripura', 'district'),
  ('South Tripura', 'South Tripura', 'Tripura', 'district'),
  ('Unakoti', 'Unakoti', 'Tripura', 'district'),
  ('West Tripura', 'West Tripura', 'Tripura', 'district')
on conflict do nothing;

-- ===== 20260924000008_chat_logs.sql =====
-- Assistant audit log (supabase/functions/chat). Also the rate-limit counter: chat_quota_ok()
-- counts the caller's rows in the last hour. Written by the function as the caller, so RLS
-- pins every row to auth.uid(). No update/delete for clients, or a user could reset their quota.

create table public.chat_logs (
  id         bigint generated by default as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  role       text,
  prompt     text,
  response   text,
  tools      text[],
  tokens_in  integer,
  tokens_out integer,
  created_at timestamptz not null default now()
);
create index chat_logs_user_created_idx on public.chat_logs (user_id, created_at desc);

alter table public.chat_logs enable row level security;

create policy chat_logs_insert_own on public.chat_logs for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy chat_logs_select on public.chat_logs for select to authenticated
  using (user_id = (select auth.uid()) or public.has_role('control_room'));

grant select, insert on public.chat_logs to authenticated;
revoke update, delete on public.chat_logs from authenticated;

-- ponytail: rows are written when a stream finishes, so parallel in-flight requests can overshoot
-- the limit by a few. Fine for a per-user fuse; count at request start if abuse appears.
create function public.chat_quota_ok(p_limit integer default 30) returns boolean
language sql stable security definer set search_path = '' as $$
  select count(*) < least(greatest(coalesce(p_limit, 30), 1), 200)
  from public.chat_logs
  where user_id = auth.uid() and created_at > now() - interval '1 hour'
$$;
revoke execute on function public.chat_quota_ok(integer) from public, anon;
grant execute on function public.chat_quota_ok(integer) to authenticated;

-- ===== 20260924000009_fix_scores_partition.sql =====
-- Fix: partitions need the parent's CHECK constraints to attach ("child table is missing constraint
-- segment_scores_tier_check"). LIKE copies NOT NULL but not CHECK unless asked.

create or replace function public.ml_begin_run(p_run jsonb, p_mode text, p_model jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_date  date := (p_run->>'date')::date;
  v_hash  text := p_run->>'bundle_hash';
  v_model bigint;
  v_id    bigint;
begin
  if p_mode not in ('live', 'replay') then
    raise exception 'mode must be live or replay' using errcode = '22023';
  end if;
  if v_date is null or v_hash is null then
    raise exception 'run.json needs date and bundle_hash' using errcode = '22023';
  end if;
  if exists (select 1 from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'published') then
    return null;
  end if;

  insert into public.ml_model_versions (version, bundle_hash, uri, manifest, policy)
  values (coalesce(p_run->>'bundle_version', p_model->'manifest'->>'version', v_hash), v_hash,
          p_model->>'uri', p_model->'manifest', p_model->'policy')
  on conflict (bundle_hash) do update set manifest = excluded.manifest, policy = excluded.policy, uri = excluded.uri
  returning id into v_model;

  delete from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'staging';
  insert into public.ml_batch_runs
    (score_date, mode, model_version_id, bundle_version, bundle_hash, featurestore_schema_sha256, n_segments,
     tier_counts, drift, data_quality, run, expires_at)
  values (v_date, p_mode, v_model, p_run->>'bundle_version', v_hash, p_run->>'featurestore_schema_sha256',
          (p_run->>'n_segments')::int, coalesce(p_run->'tiers', '{}'), p_run->'drift', p_run->'data_quality', p_run,
          case when p_mode = 'live' then ((v_date + 2)::timestamp at time zone 'Asia/Kolkata') end)
  returning id into v_id;

  execute format('drop table if exists ml_private.scores_r%s', v_id);
  execute format('create table ml_private.scores_r%s (like ml_private.segment_scores including constraints)', v_id);
  execute format('grant insert on ml_private.scores_r%s to ml_publisher', v_id);
  return v_id;
end $$;

-- ===== 20260924174727_account_approvals.sql =====
-- Account approvals.
--   field officer    -> starts inactive; approved by a district officer of the same district, or the control room
--   district officer -> starts inactive; approved by the control room
--   control room     -> active immediately (sign-up left open for now; close it by removing
--                       'control_room' from the is_active list in handle_new_user)
--   rider            -> active immediately (unchanged)
-- Rejecting an account deactivates its profile, so my_role() stays null and it can't sign in.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_role   public.user_role_enum;
  v_loc    uuid;
begin
  v_role := case m->>'requested_role'
    when 'rider'            then 'rider'
    when 'district_officer' then 'district_officer'
    when 'control_room'     then 'control_room'
    else 'field_officer'
  end::public.user_role_enum;

  select l.id into v_loc from public.locations l
  where nullif(trim(m->>'district'), '') is not null
    and lower(l.name) = lower(trim(m->>'district'))
    and (nullif(trim(m->>'state'), '') is null or lower(l.state) = lower(trim(m->>'state')))
  order by l.kind = 'district' desc limit 1;

  insert into public.profiles (id, full_name, officer_id, phone, region)
  values (new.id, nullif(trim(m->>'full_name'), ''), nullif(trim(m->>'officer_id'), ''),
          nullif(trim(m->>'phone'), ''), nullif(trim(coalesce(m->>'district', m->>'state', '')), ''));

  insert into public.user_roles (user_id, role, district_id, is_active)
  values (new.id, v_role, v_loc, v_role in ('rider', 'control_room'));

  if v_role = 'rider' then
    insert into public.rider_profiles (user_id, phone, vehicle_registration)
    values (new.id, nullif(trim(m->>'phone'), ''), nullif(upper(trim(m->>'vehicle_registration')), ''));
  end if;
  return new;
end $$;

-- Can the signed-in user review this pending account? Control room: any non-rider account.
-- District officer: field officers of their own district.
create or replace function public.can_review_account(p_role public.user_role_enum, p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (public.has_role('control_room') and p_role <> 'rider')
    or (public.has_role('district_officer') and p_role = 'field_officer'
        and p_district = (select ur.district_id from public.user_roles ur where ur.user_id = auth.uid())),
    false)
$$;

-- Pending sign-ups the caller may review, oldest first.
create or replace function public.pending_accounts()
returns table (user_id uuid, full_name text, email text, role text, district text, state text, requested_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select ur.user_id, p.full_name, u.email::text, ur.role::text, l.name, l.state, ur.created_at
  from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  join auth.users u on u.id = ur.user_id
  left join public.locations l on l.id = ur.district_id
  where not ur.is_active and p.is_active
    and public.can_review_account(ur.role, ur.district_id)
  order by ur.created_at
$$;

-- Approve (activate the role) or reject (deactivate the profile) one pending sign-up.
create or replace function public.review_account(p_user_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.user_roles%rowtype;
begin
  select ur.* into r from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  where ur.user_id = p_user_id and not ur.is_active and p.is_active;
  if not found then
    raise exception 'This account has no pending request.' using errcode = 'P0002';
  end if;
  if not public.can_review_account(r.role, r.district_id) then
    raise exception 'You are not allowed to review this account.' using errcode = '42501';
  end if;

  if p_approve then
    update public.user_roles set is_active = true where user_id = p_user_id;
  else
    update public.profiles set is_active = false where id = p_user_id;
  end if;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), case when p_approve then 'account_approved' else 'account_rejected' end,
          'user_roles', p_user_id::text, jsonb_build_object('role', r.role));
end $$;

-- Signed-in users only (every new function is executable by PUBLIC by default).
revoke execute on function public.can_review_account(public.user_role_enum, uuid), public.pending_accounts(),
  public.review_account(uuid, boolean) from public, anon;
grant execute on function public.pending_accounts(), public.review_account(uuid, boolean) to authenticated;

-- ===== 20260924175704_drop_profiles_department.sql =====
-- Department is no longer collected at sign-up. The column was empty for every profile when dropped
-- (checked 2026-09-24); no view, function or policy references it. The website and the Flutter app
-- both read profiles without naming this column, so they keep working.
alter table public.profiles drop column if exists department;
