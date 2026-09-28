-- Rider visibility by CURRENT district (was: the rider's home district).
--   control_room    : every rider, always.
--   district_officer: a rider only while the rider is inside the officer's district.
--   field_officer   : no rider view.
-- The district is derived server-side from each fix (boundary polygon, else nearest HQ), by trigger,
-- so sync_rider_locations is unchanged.

alter table public.locations add column boundary extensions.geography(MultiPolygon, 4326);
create index locations_boundary_idx on public.locations using gist (boundary);

-- District containing a point: boundary polygon first, else the nearest district HQ within 100 km
-- (a point far outside the region belongs to no district, so only the control room sees it).
create function public.district_at(p extensions.geography) returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select l.id from public.locations l
      where l.kind = 'district' and l.boundary is not null and extensions.st_covers(l.boundary, p)
      limit 1),
    (select l.id from public.locations l
      where l.kind = 'district' and l.geom is not null and extensions.st_dwithin(l.geom, p, 100000)
      order by l.geom operator(extensions.<->) p limit 1))
$$;
revoke execute on function public.district_at(extensions.geography) from public, anon;
grant execute on function public.district_at(extensions.geography) to authenticated;

alter table public.rider_locations
  add column current_district_id  uuid references public.locations (id) on delete set null,
  add column previous_district_id uuid references public.locations (id) on delete set null;
alter table public.rider_location_history
  add column district_id uuid references public.locations (id) on delete set null;
create index rider_locations_district_idx on public.rider_locations (current_district_id);
create index rider_history_district_idx on public.rider_location_history (user_id, district_id, recorded_at desc);

-- previous_district_id lets the one update that carries a rider OUT of a district still pass that
-- district's RLS, so Realtime tells its officers to drop the rider.
create function public.rider_locations_set_district() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.current_district_id is null or new.geom is distinct from old.geom then
    new.current_district_id := public.district_at(new.geom);
  end if;
  if tg_op = 'UPDATE' then
    new.previous_district_id := old.current_district_id;
  end if;
  return new;
end $$;
create trigger rider_locations_district before insert or update on public.rider_locations
  for each row execute function public.rider_locations_set_district();

create function public.rider_history_set_district() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.district_id := public.district_at(
    extensions.st_setsrid(extensions.st_makepoint(new.longitude, new.latitude), 4326)::extensions.geography);
  return new;
end $$;
create trigger rider_history_district before insert on public.rider_location_history
  for each row execute function public.rider_history_set_district();

-- Backfill existing rows (locations.boundary is filled by the next migration; rerun this block after it
-- if you want polygon accuracy for old rows: the HQ fallback is used until then).
update public.rider_locations set current_district_id = public.district_at(geom);
update public.rider_location_history h
   set district_id = public.district_at(
     extensions.st_setsrid(extensions.st_makepoint(h.longitude, h.latitude), 4326)::extensions.geography);

-- Scope --------------------------------------------------------------------------------------------
create or replace function public.can_see_rider(p_rider uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when public.my_role() = 'control_room' then true
    when public.my_role() = 'district_officer' then exists (
      select 1 from public.rider_locations l
      where l.user_id = p_rider and l.current_district_id = public.my_district_id())
    else false
  end
$$;

drop policy rider_locations_officer on public.rider_locations;
drop policy rider_history_officer on public.rider_location_history;
-- The previous-district allowance lasts 30 s after the fix: long enough for Realtime to tell that
-- district's officers the rider left, not a standing view of the rider's new district.
create policy rider_locations_officer on public.rider_locations for select to authenticated
  using (public.my_role() = 'control_room'
         or (public.my_role() = 'district_officer'
             and (current_district_id = public.my_district_id()
                  or (previous_district_id = public.my_district_id()
                      and received_at > now() - interval '30 seconds'))));
create policy rider_history_officer on public.rider_location_history for select to authenticated
  using (public.my_role() = 'control_room'
         or (public.my_role() = 'district_officer' and district_id = public.my_district_id()));

-- Same body as 20260927100040, but "district" is where the rider is now.
create or replace function public.get_active_riders(p_stale_minutes integer default 30)
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
  left join public.locations loc on loc.id = l.current_district_id
  left join public.shipments s on s.id = l.shipment_id
  left join public.routes r on r.id = s.route_id
  where (coalesce(rp.is_on_duty, false) or l.recorded_at > now() - interval '24 hours')
    and public.can_see_rider(l.user_id)
  order by l.recorded_at desc;
end $$;

-- SECURITY DEFINER bypasses RLS, so the in-district filter on the trail is applied here.
create or replace function public.get_rider_trail(p_user_id uuid, p_since timestamptz, p_limit integer default 500)
returns table (latitude double precision, longitude double precision, speed_kmph real, recorded_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_officer() or not public.can_see_rider(p_user_id) then
    raise exception 'rider not in your scope' using errcode = '42501';
  end if;
  return query
  select h.latitude, h.longitude, h.speed_kmph, h.recorded_at
  from public.rider_location_history h
  where h.user_id = p_user_id and h.recorded_at >= p_since
    and (public.my_role() = 'control_room' or h.district_id = public.my_district_id())
  order by h.recorded_at desc
  limit least(greatest(p_limit, 1), 2000);
end $$;
