-- Rider visibility by scope (Agent 4, GPS tracking).
-- Before: every officer role read every rider's position. Now control_room sees all riders;
-- district_officer and field_officer see only riders assigned to their own district.
-- Covers table reads, Realtime postgres_changes (RLS-filtered) and the two officer RPCs.

create function public.can_see_rider(p_rider uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when public.my_role() = 'control_room' then true
    when public.my_role() in ('district_officer', 'field_officer') then exists (
      select 1 from public.user_roles me
      join public.user_roles r on r.district_id = me.district_id
      where me.user_id = auth.uid() and r.user_id = p_rider)
    else false
  end
$$;

revoke execute on function public.can_see_rider(uuid) from public, anon;  -- Agent 7: PUBLIC keeps execute by default
grant execute on function public.can_see_rider(uuid) to authenticated;

drop policy rider_profiles_officer on public.rider_profiles;
drop policy rider_locations_officer on public.rider_locations;
drop policy rider_history_officer on public.rider_location_history;
create policy rider_profiles_officer on public.rider_profiles for select to authenticated
  using (public.can_see_rider(user_id));
create policy rider_locations_officer on public.rider_locations for select to authenticated
  using (public.can_see_rider(user_id));
create policy rider_history_officer on public.rider_location_history for select to authenticated
  using (public.can_see_rider(user_id));

-- Same body as 20260924000003, plus the scope filter.
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
  left join public.user_roles ur on ur.user_id = l.user_id
  left join public.locations loc on loc.id = ur.district_id
  left join public.shipments s on s.id = l.shipment_id
  left join public.routes r on r.id = s.route_id
  where (coalesce(rp.is_on_duty, false) or l.recorded_at > now() - interval '24 hours')
    and public.can_see_rider(l.user_id)
  order by l.recorded_at desc;
end $$;

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
  order by h.recorded_at desc
  limit least(greatest(p_limit, 1), 2000);
end $$;
