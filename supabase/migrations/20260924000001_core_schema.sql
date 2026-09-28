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
