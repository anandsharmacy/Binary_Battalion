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
