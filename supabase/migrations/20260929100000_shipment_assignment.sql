-- Shipment creation and assignment.
--   district_officer (own district) and control_room create shipments and assign them to riders;
--   the rider accepts or declines, then moves the shipment Start -> Arrived -> Completed.
-- Every write goes through the SECURITY DEFINER RPCs below: direct table writes are revoked.

-- Schema ---------------------------------------------------------------------------------------------
alter table public.shipments
  add column created_by     uuid references auth.users (id) on delete set null default auth.uid(),
  add column assigned_by    uuid references auth.users (id) on delete set null,
  add column declined_by    uuid references auth.users (id) on delete set null,
  add column assigned_at    timestamptz,
  add column accepted_at    timestamptz,
  add column started_at     timestamptz,
  add column arrived_at     timestamptz,
  add column completed_at   timestamptz,
  add column declined_at    timestamptz,
  add column cancelled_at   timestamptz,
  add column decline_reason text,
  add column cancel_reason  text;

-- scheduled = unassigned, assigned = waiting for the rider, accepted = rider said yes.
alter table public.shipments drop constraint shipments_status_check;
alter table public.shipments add constraint shipments_status_check check (status in
  ('scheduled', 'assigned', 'accepted', 'in_transit', 'on_schedule', 'delayed', 'at_risk',
   'arrived', 'completed', 'cancelled'));

create index shipments_district_status_idx on public.shipments (district_id, status);

alter table public.shipments replica identity full;  -- Realtime delivers whole rows

create sequence public.shipment_number_seq;
create function public.shipments_fill_number() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.shipment_number is null or btrim(new.shipment_number) = '' then
    new.shipment_number := 'SHP-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('public.shipment_number_seq')::text, 4, '0');
  end if;
  return new;
end $$;
create trigger shipments_number before insert on public.shipments
  for each row execute function public.shipments_fill_number();

-- Who can assign whom ---------------------------------------------------------------------------------
-- Control room: any active rider. District officer: riders registered to their district, or currently
-- inside it by GPS (a rider who has never shared location can still be picked by home district).
create function public.can_assign_rider(p_rider uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles r where r.user_id = p_rider and r.role = 'rider' and r.is_active)
     and case
           when public.my_role() = 'control_room' then true
           when public.my_role() = 'district_officer' then
                coalesce((select r.district_id = public.my_district_id() from public.user_roles r where r.user_id = p_rider), false)
                or exists (select 1 from public.rider_locations l
                           where l.user_id = p_rider and l.current_district_id = public.my_district_id())
           else false
         end
$$;

-- Officer RPCs ----------------------------------------------------------------------------------------
create function public.list_assignable_riders()
returns table (user_id uuid, full_name text, officer_id text, phone text, home_district text, current_district text,
               is_on_duty boolean, vehicle_type text, vehicle_registration text, open_shipments integer,
               last_fix_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'Only district officers and the control room can assign shipments.' using errcode = '42501';
  end if;
  return query
  select ur.user_id, p.full_name, p.officer_id, coalesce(rp.phone, p.phone), hl.name, cl.name,
         coalesce(rp.is_on_duty, false), rp.vehicle_type, rp.vehicle_registration,
         (select count(*)::integer from public.shipments s
           where s.rider_id = ur.user_id and s.status not in ('arrived', 'completed', 'cancelled')),
         l.recorded_at
  from public.user_roles ur
  join public.profiles p on p.id = ur.user_id and p.is_active
  left join public.rider_profiles rp on rp.user_id = ur.user_id
  left join public.locations hl on hl.id = ur.district_id
  left join public.rider_locations l on l.user_id = ur.user_id
  left join public.locations cl on cl.id = l.current_district_id
  where ur.role = 'rider' and ur.is_active and public.can_assign_rider(ur.user_id)
  order by coalesce(rp.is_on_duty, false) desc, p.full_name;
end $$;

-- Shipments the caller may see, with names resolved (rider, decliner, creator) for the officer board.
create function public.list_shipments()
returns table (id uuid, shipment_number text, status text, risk_level text, cargo_description text,
               cargo_weight_kg numeric, origin text, destination text, route_number text,
               district_id uuid, district text, rider_id uuid, rider_name text, rider_officer_id text,
               estimated_arrival timestamptz, created_at timestamptz, updated_at timestamptz,
               assigned_at timestamptz, accepted_at timestamptz, started_at timestamptz, arrived_at timestamptz,
               completed_at timestamptz, declined_at timestamptz, decline_reason text, declined_by_name text,
               cancel_reason text, created_by_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'Only district officers and the control room can view the shipment board.' using errcode = '42501';
  end if;
  return query
  select s.id, s.shipment_number, s.status, s.risk_level, s.cargo_description, s.cargo_weight_kg, s.origin,
         s.destination, r.route_number, s.district_id, d.name, s.rider_id, rp.full_name, rp.officer_id,
         s.estimated_arrival, s.created_at, s.updated_at, s.assigned_at, s.accepted_at, s.started_at,
         s.arrived_at, s.completed_at, s.declined_at, s.decline_reason, dp.full_name, s.cancel_reason, cp.full_name
  from public.shipments s
  left join public.routes r on r.id = s.route_id
  left join public.locations d on d.id = s.district_id
  left join public.profiles rp on rp.id = s.rider_id
  left join public.profiles dp on dp.id = s.declined_by
  left join public.profiles cp on cp.id = s.created_by
  where public.in_my_scope(s.district_id)
  order by s.created_at desc
  limit 500;
end $$;

-- p keys: cargo_description, cargo_weight_kg, origin*, destination*, destination_lat/lng, route_id,
-- estimated_arrival, risk_level, district_id (control room only, required), rider_id (assigns at once).
create function public.create_shipment(p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_role     text := public.my_role()::text;
  v_district uuid;
  v_rider    uuid := nullif(p->>'rider_id', '')::uuid;
  v_id       uuid;
begin
  if v_role not in ('control_room', 'district_officer') then
    raise exception 'Only district officers and the control room can create shipments.' using errcode = '42501';
  end if;
  if v_role = 'district_officer' then
    v_district := public.my_district_id();
    if v_district is null then
      raise exception 'Your account has no district.' using errcode = '42501';
    end if;
    if nullif(p->>'district_id', '') is not null and (p->>'district_id')::uuid <> v_district then
      raise exception 'You can only create shipments in your own district.' using errcode = '42501';
    end if;
  else
    v_district := nullif(p->>'district_id', '')::uuid;
    if v_district is null then
      raise exception 'Choose a district for the shipment.' using errcode = '22023';
    end if;
    if not exists (select 1 from public.locations l where l.id = v_district and l.kind = 'district') then
      raise exception 'Unknown district.' using errcode = '22023';
    end if;
  end if;
  if btrim(coalesce(p->>'origin', '')) = '' or btrim(coalesce(p->>'destination', '')) = '' then
    raise exception 'Origin and destination are required.' using errcode = '22023';
  end if;
  if v_rider is not null and not public.can_assign_rider(v_rider) then
    raise exception 'That rider is not available to you.' using errcode = '42501';
  end if;

  insert into public.shipments
    (status, risk_level, cargo_description, cargo_weight_kg, origin, destination, destination_lat, destination_lng,
     route_id, district_id, estimated_arrival, created_by, rider_id, assigned_by, assigned_at)
  values
    (case when v_rider is null then 'scheduled' else 'assigned' end,
     coalesce(nullif(p->>'risk_level', ''), 'low'),
     nullif(btrim(p->>'cargo_description'), ''), nullif(p->>'cargo_weight_kg', '')::numeric,
     btrim(p->>'origin'), btrim(p->>'destination'),
     nullif(p->>'destination_lat', '')::double precision, nullif(p->>'destination_lng', '')::double precision,
     nullif(p->>'route_id', '')::uuid, v_district, nullif(p->>'estimated_arrival', '')::timestamptz,
     auth.uid(), v_rider, case when v_rider is null then null else auth.uid() end,
     case when v_rider is null then null else now() end)
  returning id into v_id;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'shipment_created', 'shipments', v_id::text,
          jsonb_build_object('district_id', v_district, 'rider_id', v_rider));
  return v_id;
end $$;

create function public.assign_shipment(p_id uuid, p_rider uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'Only district officers and the control room can assign shipments.' using errcode = '42501';
  end if;
  select * into s from public.shipments where id = p_id for update;
  if not found then
    raise exception 'Shipment not found.' using errcode = 'P0002';
  end if;
  if not public.in_my_scope(s.district_id) then
    raise exception 'This shipment is outside your district.' using errcode = '42501';
  end if;
  if s.status not in ('scheduled', 'assigned') then
    raise exception 'Only shipments the rider has not accepted yet can be (re)assigned.' using errcode = '22023';
  end if;
  if not public.can_assign_rider(p_rider) then
    raise exception 'That rider is not available to you.' using errcode = '42501';
  end if;

  update public.shipments
     set rider_id = p_rider, status = 'assigned', assigned_by = auth.uid(), assigned_at = now(),
         accepted_at = null, declined_at = null, declined_by = null, decline_reason = null
   where id = p_id;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'shipment_assigned', 'shipments', p_id::text,
          jsonb_build_object('rider_id', p_rider, 'previous_rider_id', s.rider_id));
end $$;

create function public.cancel_shipment(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'Only district officers and the control room can cancel shipments.' using errcode = '42501';
  end if;
  select * into s from public.shipments where id = p_id for update;
  if not found then
    raise exception 'Shipment not found.' using errcode = 'P0002';
  end if;
  if not public.in_my_scope(s.district_id) then
    raise exception 'This shipment is outside your district.' using errcode = '42501';
  end if;
  if s.status in ('arrived', 'completed', 'cancelled') then
    raise exception 'A delivered or already cancelled shipment cannot be cancelled.' using errcode = '22023';
  end if;

  update public.shipments
     set status = 'cancelled', cancelled_at = now(), cancel_reason = nullif(btrim(p_reason), '')
   where id = p_id;
  if s.rider_id is not null then
    update public.rider_profiles set active_shipment_id = null
     where user_id = s.rider_id and active_shipment_id = p_id;
  end if;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'shipment_cancelled', 'shipments', p_id::text,
          jsonb_build_object('rider_id', s.rider_id, 'reason', nullif(btrim(p_reason), '')));
end $$;

-- Rider RPCs ------------------------------------------------------------------------------------------
create function public.respond_to_shipment(p_id uuid, p_accept boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
begin
  if public.my_role() is distinct from 'rider' then
    raise exception 'Only riders can respond to a shipment.' using errcode = '42501';
  end if;
  select * into s from public.shipments where id = p_id and rider_id = auth.uid() for update;
  if not found then
    raise exception 'This shipment is no longer assigned to you.' using errcode = 'P0002';
  end if;
  if s.status <> 'assigned' then
    raise exception 'This shipment is not waiting for a response.' using errcode = '22023';
  end if;

  if p_accept then
    update public.shipments set status = 'accepted', accepted_at = now() where id = p_id;
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'Give a reason for declining.' using errcode = '22023';
    end if;
    update public.shipments
       set status = 'scheduled', rider_id = null, declined_at = now(), declined_by = auth.uid(),
           decline_reason = btrim(p_reason)
     where id = p_id;
  end if;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), case when p_accept then 'shipment_accepted' else 'shipment_declined' end,
          'shipments', p_id::text, jsonb_build_object('reason', nullif(btrim(p_reason), '')));
end $$;

-- accepted -> in_transit -> arrived -> completed. Starting a trip makes it the rider's active shipment.
create function public.advance_shipment(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.shipments%rowtype;
begin
  if public.my_role() is distinct from 'rider' then
    raise exception 'Only riders can update a shipment.' using errcode = '42501';
  end if;
  select * into s from public.shipments where id = p_id and rider_id = auth.uid() for update;
  if not found then
    raise exception 'This shipment is no longer assigned to you.' using errcode = 'P0002';
  end if;

  if p_status = 'in_transit' and s.status = 'accepted' then
    update public.shipments set status = 'in_transit', started_at = now() where id = p_id;
    update public.rider_profiles set active_shipment_id = p_id where user_id = auth.uid();
  elsif p_status = 'arrived' and s.status in ('in_transit', 'on_schedule', 'delayed', 'at_risk') then
    update public.shipments set status = 'arrived', arrived_at = now() where id = p_id;
  elsif p_status = 'completed' and s.status = 'arrived' then
    update public.shipments set status = 'completed', completed_at = now() where id = p_id;
    update public.rider_profiles set active_shipment_id = null
     where user_id = auth.uid() and active_shipment_id = p_id;
  else
    raise exception 'This shipment is % and cannot move to %.', s.status, p_status using errcode = '22023';
  end if;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'shipment_' || p_status, 'shipments', p_id::text, null);
end $$;

-- The rider's own list: adds the assignment lifecycle so the app can render each state.
create or replace function public.get_my_rider_context() returns jsonb
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
        'delay_description', s.delay_description, 'current_location_text', s.current_location_text,
        'assigned_at', s.assigned_at, 'accepted_at', s.accepted_at, 'started_at', s.started_at,
        'arrived_at', s.arrived_at)
        order by (s.status = 'assigned') desc, s.estimated_arrival nulls last, s.created_at)
      from public.shipments s left join public.routes r on r.id = s.route_id
      where s.rider_id = auth.uid() and s.status not in ('completed', 'cancelled')), '[]'::jsonb)
  ) end
$$;

-- Access ----------------------------------------------------------------------------------------------
-- Direct writes are gone (TRUNCATE ignores RLS, so it goes too); reads stay behind RLS.
drop policy shipments_write on public.shipments;
drop policy shipments_rider_update on public.shipments;
drop policy shipments_officer on public.shipments;
create policy shipments_officer on public.shipments for select to authenticated
  using (public.in_my_scope(district_id) or created_by = auth.uid());
revoke all on public.shipments from anon;
revoke insert, update, delete, truncate, references, trigger on public.shipments from authenticated;

revoke execute on function
  public.can_assign_rider(uuid), public.list_assignable_riders(), public.list_shipments(),
  public.create_shipment(jsonb), public.assign_shipment(uuid, uuid), public.cancel_shipment(uuid, text),
  public.respond_to_shipment(uuid, boolean, text), public.advance_shipment(uuid, text)
  from public, anon;
grant execute on function
  public.can_assign_rider(uuid), public.list_assignable_riders(), public.list_shipments(),
  public.create_shipment(jsonb), public.assign_shipment(uuid, uuid), public.cancel_shipment(uuid, text),
  public.respond_to_shipment(uuid, boolean, text), public.advance_shipment(uuid, text)
  to authenticated;
revoke execute on function public.shipments_fill_number() from public, anon, authenticated;

-- Push to the rider on (re)assignment: same Vault-secret webhook as alerts (functions/notify).
-- Does nothing until notify_url / notify_secret exist in Vault, so it can never block a write.
create extension if not exists pg_net with schema extensions;
create function public.notify_shipment_webhook() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_url    text := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_url');
  v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_secret');
begin
  if new.rider_id is null or new.status <> 'assigned' or v_url is null or v_secret is null then return new; end if;
  if tg_op = 'UPDATE' and old.rider_id is not distinct from new.rider_id then return new; end if;
  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    body    := jsonb_build_object('type', 'ASSIGNED', 'table', 'shipments', 'schema', 'public', 'record', to_jsonb(new))
  );
  return new;
end $$;
revoke execute on function public.notify_shipment_webhook() from public, anon, authenticated;
create trigger shipments_notify after insert or update of rider_id on public.shipments
  for each row execute function public.notify_shipment_webhook();
